import AppKit
import Combine
import Foundation
import OSLog
import UpdraftCore

/// Drop-in "is there a newer release on GitHub?" checker.
///
/// Configure it with a repository and call `start()` once at launch: it checks on
/// startup and then daily — throttled by a stored last-check date so relaunches
/// don't spam — and shows an AppKit alert offering **Download**, **Remind Me
/// Later**, or **Skip This Version** when a newer release exists. `checkNow()`
/// is the user-initiated path (ignores the throttle and also reports "you're up
/// to date" and errors).
///
/// Self-contained and reusable across apps: it owns its small state (enabled
/// flag, skipped version, last-check date) in `UserDefaults` under namespaced
/// keys. Depends on AppKit + Foundation plus `UpdraftCore`.
///
/// Main-confined by contract: every caller is main-affine (menu actions, the
/// main-run-loop `Timer`, SwiftUI, `.main` notification delivery), and the
/// `Task` hops only ever carry the reference *to* the main actor — that
/// confinement is what `@unchecked Sendable` asserts.
public final class UpdateChecker: ObservableObject, @unchecked Sendable {

    /// Everything an app can tune, with the defaults the copies agree on.
    public struct Configuration {
        public var owner: String
        public var repo: String
        public var appName: String
        public var currentVersion: String
        public var allowPrereleases: Bool
        /// When true (default), the alert's **Download** action saves the release's
        /// disk image/zip to `~/Downloads` and reveals it in Finder; when false it
        /// just opens the release page in the browser.
        public var autoDownloadAssets: Bool
        public var minimumCheckInterval: TimeInterval
        /// The throttle compares against `minimumCheckInterval * throttleFraction`.
        /// A punctual daily timer fires just before the stored "completed" date +
        /// interval, so the full interval would skip a day; the fraction absorbs
        /// the timer tolerance and completion-time skew.
        public var throttleFraction: Double
        /// Namespacing prefix for this checker's `UserDefaults` keys. Each app
        /// passes the prefix it already used so existing settings survive.
        public var defaultsKeyPrefix: String
        public var userAgent: String?
        /// Which asset of a release to offer.
        public var assetSelection: AssetSelection
        /// Name used when an asset's own name is unusable as a filename.
        public var downloadFallbackFileName: String
        /// Window level for the alerts. Jetty's menu panel needs
        /// `NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)`.
        public var alertWindowLevel: NSWindow.Level
        /// Brings the app forward before an alert runs modally. `nil` uses
        /// `NSApp.activate()`. Zap and Invoque pass their own activator.
        public var activateForAlert: (() -> Void)?
        /// When true, an update found by a background check while the app is
        /// inactive is queued and shown on the next activation instead of
        /// stealing focus. Menu-bar agents need this; frontmost apps don't.
        public var deferWhileInactive: Bool

        public init(owner: String,
                    repo: String,
                    appName: String = Bundle.main.appDisplayName,
                    currentVersion: String = Bundle.main.shortVersionString,
                    allowPrereleases: Bool = false,
                    autoDownloadAssets: Bool = true,
                    minimumCheckInterval: TimeInterval = 24 * 60 * 60,
                    throttleFraction: Double = 0.9,
                    defaultsKeyPrefix: String? = nil,
                    userAgent: String? = nil,
                    assetSelection: AssetSelection = .default,
                    downloadFallbackFileName: String? = nil,
                    alertWindowLevel: NSWindow.Level = .floating,
                    activateForAlert: (() -> Void)? = nil,
                    deferWhileInactive: Bool = false) {
            self.owner = owner
            self.repo = repo
            self.appName = appName
            self.currentVersion = currentVersion
            self.allowPrereleases = allowPrereleases
            self.autoDownloadAssets = autoDownloadAssets
            self.minimumCheckInterval = minimumCheckInterval
            self.throttleFraction = throttleFraction
            self.defaultsKeyPrefix = defaultsKeyPrefix ?? "UpdateChecker.\(owner).\(repo)"
            self.userAgent = userAgent
            self.assetSelection = assetSelection
            self.downloadFallbackFileName = downloadFallbackFileName ?? "\(appName)-update"
            self.alertWindowLevel = alertWindowLevel
            self.activateForAlert = activateForAlert
            self.deferWhileInactive = deferWhileInactive
        }
    }

    let configuration: Configuration
    private let client: any ReleaseFetching
    private let downloader: UpdateDownloader
    private let defaults: UserDefaults
    private let logger: Logger
    private var timer: Timer?

    /// A newer release found by a background check while the app was inactive —
    /// queued, surfaced through `pendingUpdateTag`/`onPendingUpdateChanged`, and
    /// presented the next time the app legitimately owns focus.
    private var pendingUpdate: GitHubRelease?
    private var activationObserver: NSObjectProtocol?

    /// A `checkNow()` that arrives while a check is already in flight reports
    /// that run's outcome as user-initiated rather than being dropped.
    private var pendingUserInitiatedCheck = false

    /// Test seam: when set, alerts are handed here instead of running modally,
    /// so tests can inspect the copy and choose a button.
    var alertSink: ((NSAlert) -> NSApplication.ModalResponse)?

    /// Called when `pendingUpdateTag` changes (tag name, or nil once presented).
    /// `AppDelegate` mirrors it onto a status-menu item so a queued update is
    /// still discoverable while the app is inactive.
    public var onPendingUpdateChanged: ((String?) -> Void)?

    /// Whether to check automatically (on launch and daily). User-facing toggle.
    @Published public var automaticChecksEnabled: Bool {
        didSet {
            defaults.set(automaticChecksEnabled, forKey: key("enabled"))
            if automaticChecksEnabled, !oldValue { checkInBackground() }
        }
    }

    /// When the last successful check completed (for a Settings "last checked" line).
    @Published public private(set) var lastCheckDate: Date?

    /// True while a check is in flight (to disable a "Check Now" button, say).
    @Published public private(set) var isChecking = false

    /// True while an update asset is downloading to `~/Downloads`.
    @Published public private(set) var isDownloading = false

    /// The tag of a background-found update waiting for the app to become
    /// active, or nil.
    @Published public private(set) var pendingUpdateTag: String?

    public init(configuration: Configuration, defaults: UserDefaults = .standard,
                client: (any ReleaseFetching)? = nil) {
        self.configuration = configuration
        self.defaults = defaults
        self.client = client ?? GitHubReleaseClient(owner: configuration.owner,
                                                    repo: configuration.repo,
                                                    userAgent: configuration.userAgent)
        self.downloader = UpdateDownloader(fallbackFileName: configuration.downloadFallbackFileName)
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Updraft", category: "updates")
        let prefix = configuration.defaultsKeyPrefix
        // Default ON unless the user has explicitly turned it off.
        self.automaticChecksEnabled = defaults.object(forKey: "\(prefix).enabled") as? Bool ?? true
        self.lastCheckDate = defaults.object(forKey: "\(prefix).lastCheck") as? Date
    }

    deinit {
        timer?.invalidate()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    // MARK: Public API

    /// Begins automatic checking: an immediate (throttled) check plus a daily timer.
    /// Call once at launch. No-op under XCTest.
    public func start() {
        guard !TestEnvironment.isRunningTests else { return }
        // A second start() must not leave the old timer scheduled forever.
        timer?.invalidate()
        checkInBackground()
        let interval = configuration.minimumCheckInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkInBackground()
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Runs a check only if automatic checks are on and the throttle interval has
    /// elapsed. Silent unless a newer, non-skipped version is found.
    public func checkInBackground() {
        guard automaticChecksEnabled else { return }
        // An unbundled `swift run` has no Info.plist, so the version falls back to a
        // placeholder that any real release would outrank — which would pop a spurious
        // update alert on every launch. Skip automatic checks there; the menu's
        // Check for Updates… still works on demand.
        guard Bundle.main.bundleIdentifier != nil else { return }
        // Throttle against a fraction of the interval: `lastCheckDate` is stamped
        // when the previous request *completed*, a beat after the timer's
        // reference point, so the full interval would skip a slightly-early fire.
        if let last = lastCheckDate,
           Date().timeIntervalSince(last) < configuration.minimumCheckInterval * configuration.throttleFraction {
            return
        }
        performCheck(userInitiated: false)
    }

    /// User-initiated check (menu / Settings): ignores the throttle and always
    /// reports the outcome, including "you're up to date" and errors.
    public func checkNow() {
        performCheck(userInitiated: true)
    }

    /// Presents the queued background update immediately — a status-menu
    /// "Update Available" item calls this; an explicit click is a user
    /// initiation, so the alert is appropriate even though the app was inactive.
    public func presentPendingUpdateNow() {
        Task { @MainActor in self.presentPendingUpdateIfAny() }
    }

    // MARK: Check

    private var skippedVersion: String? {
        get { defaults.string(forKey: key("skippedVersion")) }
        set { defaults.set(newValue, forKey: key("skippedVersion")) }
    }

    private func performCheck(userInitiated: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Guard and flag flip together on the main actor: testing `isChecking`
            // on the caller's thread raced the main-actor reset and published a
            // change off the main thread.
            guard !self.isChecking else {
                // A checkNow() during an in-flight run must still report — mark
                // this run's outcome as user-requested rather than dropping it.
                if userInitiated { self.pendingUserInitiatedCheck = true }
                return
            }
            self.isChecking = true
            defer {
                // A checkNow() landing while a result alert is on screen
                // (runModal spins a nested run loop) arrives after this run
                // consumed its flag. It must neither leak into a future
                // automatic check (a stale flag would make it report and
                // steal focus) nor be dropped — run it as its own
                // user-initiated check once this one finishes.
                let queued = self.pendingUserInitiatedCheck
                self.pendingUserInitiatedCheck = false
                self.isChecking = false
                if queued { self.performCheck(userInitiated: true) }
            }
            do {
                let release = try await self.client.latestRelease(
                    includePrereleases: self.configuration.allowPrereleases)
                // Consume after the await: a checkNow() that arrived while this
                // request was in flight must have THIS run's outcome reported —
                // reading the flag earlier would drop the click and leak the
                // flag into a future automatic check.
                let report = userInitiated || self.pendingUserInitiatedCheck
                self.pendingUserInitiatedCheck = false
                self.lastCheckDate = Date()
                self.defaults.set(self.lastCheckDate, forKey: self.key("lastCheck"))

                switch UpdateVersionComparison.evaluate(
                    remote: release.tagName, current: self.configuration.currentVersion
                ) {
                case let .updateAvailable(remote, current):
                    if report {
                        self.presentUpdateAvailable(release: release, remote: remote, current: current)
                    } else if !self.isSkippedVersion(remote) {
                        if self.configuration.deferWhileInactive && !(NSApp?.isActive ?? false) {
                            self.queuePendingUpdate(release)
                        } else {
                            self.presentUpdateAvailable(release: release, remote: remote, current: current)
                        }
                    }
                case .upToDate:
                    if report { self.presentUpToDate() }
                case let .invalidCurrent(value):
                    if report {
                        self.presentInvalidVersion(label: "installed version", value: value)
                    } else {
                        self.logger.log("UpdateChecker: couldn't compare versions: the installed version '\(value)' is not a valid semantic version.")
                    }
                case let .invalidRemote(value):
                    if report {
                        self.presentInvalidVersion(label: "release tag", value: value)
                    } else {
                        self.logger.log("UpdateChecker: couldn't compare versions: the release tag '\(value)' is not a valid semantic version.")
                    }
                }
            } catch {
                // Same consumption on the failure path — a mid-flight click
                // must surface this error, not seed a later automatic check.
                let report = userInitiated || self.pendingUserInitiatedCheck
                self.pendingUserInitiatedCheck = false
                if report { self.presentError(error) }
                else { self.logger.log("UpdateChecker: background check failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Skip comparison is by parsed version: a retag ("v1.3.0" → "1.3.0") must
    /// not re-prompt a version the user already skipped. The raw tag is stored
    /// for display.
    private func isSkippedVersion(_ remote: SemanticVersion) -> Bool {
        guard let raw = skippedVersion, let skipped = SemanticVersion(raw) else { return false }
        return skipped == remote
    }

    /// Queues an update found in the background while the app is inactive: the
    /// status menu gets an "Update Available" item now, and the alert itself is
    /// presented the next time the app legitimately owns focus — never as a
    /// focus-stealing modal on a timer.
    @MainActor
    private func queuePendingUpdate(_ release: GitHubRelease) {
        pendingUpdate = release
        pendingUpdateTag = release.tagName
        onPendingUpdateChanged?(release.tagName)
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.presentPendingUpdateIfAny() }
        }
    }

    @MainActor
    private func presentPendingUpdateIfAny() {
        guard let release = pendingUpdate else { return }
        clearPendingUpdate()
        // Validate before presenting — queueing already required a successful
        // parse, but if that ever changes the update must surface as
        // unparseable rather than vanish.
        guard let remote = SemanticVersion(release.tagName),
              let current = SemanticVersion(configuration.currentVersion) else {
            presentInvalidVersion(label: "release tag", value: release.tagName)
            return
        }
        presentUpdateAvailable(release: release, remote: remote, current: current)
    }

    private func clearPendingUpdate() {
        pendingUpdate = nil
        pendingUpdateTag = nil
        onPendingUpdateChanged?(nil)
    }

    // MARK: Presentation

    @MainActor
    private func presentUpdateAvailable(release: GitHubRelease, remote: SemanticVersion, current: SemanticVersion) {
        // Presenting a release (e.g. a user-initiated check) retires a queued
        // update that is the same or older — otherwise a stale "Update
        // Available" would resurface on the next activation after the user
        // already saw the newer alert.
        if let pending = pendingUpdate,
           let pendingRemote = SemanticVersion(pending.tagName),
           pendingRemote <= remote {
            clearPendingUpdate()
        }
        let alert = NSAlert()
        alert.messageText = "A new version of \(configuration.appName) is available"
        var info = "\(configuration.appName) \(Self.displayed(remote.description)) is available — you have \(current)."
        if let notes = release.releaseNotes() { info += "\n\n\(notes)" }
        alert.informativeText = info
        alert.addButton(withTitle: "Download")           // .alertFirstButtonReturn
        alert.addButton(withTitle: "Remind Me Later")    // .alertSecondButtonReturn
        alert.addButton(withTitle: "Skip This Version")  // .alertThirdButtonReturn

        switch runModal(alert) {
        case .alertFirstButtonReturn:
            if configuration.autoDownloadAssets {
                downloadAndReveal(release)
            } else {
                openReleasePage(release)
            }
        case .alertThirdButtonReturn:
            skippedVersion = release.tagName
        default:
            break   // Remind Me Later — re-offered on the next check.
        }
    }

    /// Downloads the release's preferred asset to `~/Downloads` and reveals it in
    /// Finder. Falls back to opening the release page if there's no downloadable
    /// asset or a download is already running.
    @MainActor
    private func downloadAndReveal(_ release: GitHubRelease) {
        guard let asset = release.preferredAsset(using: configuration.assetSelection) else {
            openReleasePage(release)
            return
        }
        // A second Download click while a download runs gets the same
        // fallback as every other failure here — never a silent no-op.
        guard !isDownloading else {
            openReleasePage(release)
            return
        }
        isDownloading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isDownloading = false }
            do {
                let fileURL = try await self.downloader.downloadToDownloads(asset)
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } catch {
                self.presentDownloadFailure(error, release: release)
            }
        }
    }

    /// A failed or integrity-failed download must not look successful: tell the
    /// user why and offer the release page as the fallback.
    @MainActor
    private func presentDownloadFailure(_ error: Error, release: GitHubRelease) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The update could not be downloaded"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")
        if runModal(alert) == .alertFirstButtonReturn {
            openReleasePage(release)
        }
    }

    @MainActor
    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "\(configuration.appName) \(configuration.currentVersion) is the latest version."
        alert.addButton(withTitle: "OK")
        _ = runModal(alert)
    }

    /// A release tag or installed version the checker couldn't parse — distinct
    /// from "up to date", which would wrongly assert the user is current when
    /// the answer is unknown, and precise about which string failed.
    @MainActor
    private func presentInvalidVersion(label: String, value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't compare versions"
        alert.informativeText = "The \(label) '\(Self.displayed(value))' is not a valid semantic version."
        alert.addButton(withTitle: "OK")
        _ = runModal(alert)
    }

    @MainActor
    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = runModal(alert)
    }

    /// Brings the alert forward before running it modally — a menu-bar agent isn't
    /// the active app, so without this the alert can appear behind other windows
    /// with no Dock icon to click.
    @MainActor
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        if let alertSink { return alertSink(alert) }
        // Under XCTest a real modal would block the run loop forever — answer
        // "Remind Me Later" so check flows can still be exercised end-to-end.
        guard !TestEnvironment.isRunningTests else { return .alertSecondButtonReturn }
        if let activateForAlert = configuration.activateForAlert {
            activateForAlert()
        } else if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        alert.window.level = configuration.alertWindowLevel
        return alert.runModal()
    }

    /// Opens the release page — never an arbitrary URL from the API response.
    @MainActor
    private func openReleasePage(_ release: GitHubRelease) {
        guard let page = Self.releasePageURL(for: release.htmlURL, owner: configuration.owner,
                                             repo: configuration.repo) else { return }
        NSWorkspace.shared.open(page)
    }

    // MARK: Untrusted release data

    /// Longest version string an alert shows. Tags come from the API response,
    /// and a crafted one can be megabytes long.
    static let maxDisplayedVersionLength = 64

    /// `value` shortened for an alert.
    static func displayed(_ value: String) -> String {
        guard value.count > maxDisplayedVersionLength else { return value }
        return String(value.prefix(maxDisplayedVersionLength)) + "…"
    }

    /// The page the Download and Open Release Page buttons open. `htmlURL` comes
    /// from the untrusted API response, unlike every other URL the checker
    /// touches it would otherwise be opened unchecked, so it is kept only when
    /// it is an HTTPS github.com page of this repository; anything else is
    /// replaced by the repository's releases page.
    static func releasePageURL(for htmlURL: URL, owner: String, repo: String) -> URL? {
        let repositoryPrefix = "/\(owner)/\(repo)/".lowercased()
        if htmlURL.scheme?.lowercased() == "https",
           htmlURL.host?.lowercased() == "github.com",
           htmlURL.port == nil || htmlURL.port == 443,
           htmlURL.user == nil, htmlURL.password == nil,
           !htmlURL.pathComponents.contains(".."),
           (htmlURL.path.lowercased() + "/").hasPrefix(repositoryPrefix) {
            return htmlURL
        }
        var releases = URLComponents()
        releases.scheme = "https"
        releases.host = "github.com"
        releases.path = "/\(owner)/\(repo)/releases"
        return releases.url
    }

    // MARK: Helpers

    private func key(_ suffix: String) -> String { "\(configuration.defaultsKeyPrefix).\(suffix)" }
}
