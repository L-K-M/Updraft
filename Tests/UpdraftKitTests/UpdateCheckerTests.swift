import XCTest
@testable import UpdraftKit

/// Ported from Invoque's UpdateCheckerTests, plus coverage for the fixes the
/// shared checker carries: throttle fraction, parsed skip comparison, deferred
/// queue, queued user checks, invalid-version alerts and the exact persisted
/// keys.
final class UpdateCheckerTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "UpdateCheckerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func release(tag: String) throws -> GitHubRelease {
        let payload: [String: Any] = ["tag_name": tag,
                                      "html_url": "https://example.com/r",
                                      "prerelease": false, "draft": false,
                                      "assets": []]
        return try JSONDecoder().decode(
            GitHubRelease.self,
            from: try JSONSerialization.data(withJSONObject: payload))
    }

    private final class StubReleaseClient: ReleaseFetching, @unchecked Sendable {
        var release: GitHubRelease
        private let lock = NSLock()
        private var storage = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return storage }
        init(release: GitHubRelease) { self.release = release }
        func latestRelease(includePrereleases: Bool) async throws -> GitHubRelease {
            lock.withLock { storage += 1 }
            return release
        }
    }

    /// A suspending stub: `latestRelease` parks on a continuation so a test
    /// can act while a check is in flight, then releases it.
    private final class SuspendedReleaseClient: ReleaseFetching, @unchecked Sendable {
        private let release: GitHubRelease
        private let lock = NSLock()
        private var continuation: CheckedContinuation<GitHubRelease, Never>?
        private var released = false
        private var storage = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return storage }
        init(release: GitHubRelease) { self.release = release }
        func latestRelease(includePrereleases: Bool) async throws -> GitHubRelease {
            lock.withLock { storage += 1 }
            return await withCheckedContinuation { c in
                let fastPath = lock.withLock { () -> GitHubRelease? in
                    if released { return release }
                    continuation = c
                    return nil
                }
                if let fastPath { c.resume(returning: fastPath) }
            }
        }
        func resume() {
            lock.lock()
            released = true
            let c = continuation; continuation = nil
            lock.unlock()
            c?.resume(returning: release)
        }
    }

    private final class FailingReleaseClient: ReleaseFetching, @unchecked Sendable {
        func latestRelease(includePrereleases: Bool) async throws -> GitHubRelease {
            throw GitHubReleaseClient.ClientError.noReleases
        }
    }

    /// Records every `onPendingUpdateChanged` emission so tests can tell
    /// "never fired" apart from "fired with nil".
    private final class PendingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String?] = []
        var calls: [String?] { lock.lock(); defer { lock.unlock() }; return storage }
        var handler: (String?) -> Void { { [weak self] tag in self?.record(tag) } }
        private func record(_ tag: String?) {
            lock.lock(); defer { lock.unlock() }
            storage.append(tag)
        }
    }

    /// A thread-safe list of named events.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
        func append(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    }

    /// Records presented alerts and answers with a configurable button.
    private final class AlertRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        private var info: [String] = []
        private var buttons: [[String]] = []
        var response: NSApplication.ModalResponse = .alertSecondButtonReturn
        var messageTexts: [String] { lock.lock(); defer { lock.unlock() }; return messages }
        var informativeTexts: [String] { lock.lock(); defer { lock.unlock() }; return info }
        var buttonTitles: [[String]] { lock.lock(); defer { lock.unlock() }; return buttons }
        var count: Int { lock.lock(); defer { lock.unlock() }; return messages.count }
        func makeSink() -> (NSAlert) -> NSApplication.ModalResponse {
            { [weak self] alert in
                guard let self else { return .alertSecondButtonReturn }
                self.lock.lock()
                self.messages.append(alert.messageText)
                self.info.append(alert.informativeText)
                self.buttons.append(alert.buttons.map(\.title))
                let response = self.response
                self.lock.unlock()
                return response
            }
        }
    }

    private func makeChecker(client: any ReleaseFetching,
                             deferWhileInactive: Bool = true,
                             throttleFraction: Double = 0.9,
                             currentVersion: String = "1.0",
                             offersReleasePageForInvalidVersions: Bool = false) -> UpdateChecker {
        let checker = UpdateChecker(
            configuration: .init(owner: "test", repo: "test",
                                 appName: "Test", currentVersion: currentVersion,
                                 throttleFraction: throttleFraction,
                                 deferWhileInactive: deferWhileInactive,
                                 offersReleasePageForInvalidVersions: offersReleasePageForInvalidVersions),
            defaults: defaults, client: client)
        checker.openURL = { url in XCTFail("unexpected open of \(url)") }
        return checker
    }

    /// Records the URLs a checker asked to open.
    private final class OpenedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    }

    /// Polls until `condition` holds or ~1 s elapses — `performCheck` hops to
    /// the MainActor, so assertions can't run synchronously after the call.
    private func waitFor(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: Deferred queue (Invoque)

    func testBackgroundCheckQueuesUpdateWhileInactive() async throws {
        let client = StubReleaseClient(release: try release(tag: "v9.9.9"))
        let checker = makeChecker(client: client)
        let probe = PendingProbe()
        checker.onPendingUpdateChanged = probe.handler

        checker.checkInBackground()
        let queued = await waitFor { !probe.calls.isEmpty }
        XCTAssertTrue(queued, "background check should surface a pending update")
        XCTAssertEqual(probe.calls.first, "v9.9.9")
        XCTAssertEqual(checker.pendingUpdateTag, "v9.9.9")
        XCTAssertEqual(client.calls, 1)
    }

    func testSkippedVersionDoesNotQueue() async throws {
        // The skip must match semantically, so a retag ("v9.9.9" → "9.9.9")
        // still counts as skipped.
        defaults.set("v9.9.9", forKey: "UpdateChecker.test.test.skippedVersion")
        let client = StubReleaseClient(release: try release(tag: "9.9.9"))
        let checker = makeChecker(client: client)
        let probe = PendingProbe()
        checker.onPendingUpdateChanged = probe.handler

        checker.checkInBackground()
        let reached = await waitFor { client.calls == 1 }
        XCTAssertTrue(reached, "the check should reach the client")
        let done = await waitFor { !checker.isChecking }
        XCTAssertTrue(done)
        XCTAssertTrue(probe.calls.isEmpty,
                      "a semantically-equal skipped tag must not re-prompt")
    }

    func testNewerThanSkippedStillQueues() async throws {
        defaults.set("v9.9.9", forKey: "UpdateChecker.test.test.skippedVersion")
        let client = StubReleaseClient(release: try release(tag: "9.9.10"))
        let checker = makeChecker(client: client)
        let probe = PendingProbe()
        checker.onPendingUpdateChanged = probe.handler

        checker.checkInBackground()
        let queued = await waitFor { !probe.calls.isEmpty }
        XCTAssertTrue(queued)
        XCTAssertEqual(probe.calls.first, "9.9.10")
    }

    func testDeferredUpdateIsPresentedOnDemand() async throws {
        let client = StubReleaseClient(release: try release(tag: "v9.9.9"))
        let checker = makeChecker(client: client)
        let recorder = AlertRecorder()
        checker.alertSink = recorder.makeSink()

        checker.checkInBackground()
        let queued = await waitFor { checker.pendingUpdateTag == "v9.9.9" }
        XCTAssertTrue(queued)

        checker.presentPendingUpdateNow()
        let presented = await waitFor { recorder.count > 0 }
        XCTAssertTrue(presented)
        XCTAssertTrue(recorder.informativeTexts.first?.contains("9.9.9") == true)
        let cleared = await waitFor { checker.pendingUpdateTag == nil }
        XCTAssertTrue(cleared)
    }

    func testUserInitiatedNewerResultRetiresQueuedUpdate() async throws {
        let client = StubReleaseClient(release: try release(tag: "v9.9.9"))
        let checker = makeChecker(client: client)
        let probe = PendingProbe()
        checker.onPendingUpdateChanged = probe.handler

        checker.checkInBackground()
        let didQueue = await waitFor { checker.pendingUpdateTag == "v9.9.9" }
        XCTAssertTrue(didQueue)

        // A user-initiated check that finds a newer release presents it and
        // retires the stale queued tag.
        client.release = try release(tag: "9.9.10")
        let recorder = AlertRecorder()
        checker.alertSink = recorder.makeSink()
        checker.checkNow()

        let presented = await waitFor { recorder.count > 0 }
        XCTAssertTrue(presented)
        XCTAssertTrue(recorder.informativeTexts.first?.contains("9.9.10") == true)
        let cleared = await waitFor { checker.pendingUpdateTag == nil }
        XCTAssertTrue(cleared)
        XCTAssertNil(probe.calls.last ?? nil)
    }

    // MARK: Throttle

    func testBackgroundCheckIsThrottled() async throws {
        let client = StubReleaseClient(release: try release(tag: "1.0"))
        let checker = makeChecker(client: client)

        checker.checkInBackground()
        let first = await waitFor { client.calls == 1 && !checker.isChecking }
        XCTAssertTrue(first, "first background check should reach the client")

        checker.checkInBackground()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.calls, 1,
                       "the throttle window must suppress repeat checks")
    }

    func testThrottleFractionAllowsSlightlyEarlyCheck() async throws {
        let interval = 24 * 60 * 60.0
        // 95% of the interval has elapsed: a full-interval throttle would skip,
        // the 0.9 fraction must not.
        defaults.set(Date().addingTimeInterval(-interval * 0.95),
                     forKey: "UpdateChecker.test.test.lastCheck")
        let client = StubReleaseClient(release: try release(tag: "1.0"))
        let checker = makeChecker(client: client)
        checker.checkInBackground()
        let reached = await waitFor { client.calls == 1 }
        XCTAssertTrue(reached, "the 0.9 throttle fraction must allow a 95%-elapsed check")
    }

    func testThrottleFractionOfOneStillSkipsSlightlyEarlyCheck() async throws {
        let interval = 24 * 60 * 60.0
        defaults.set(Date().addingTimeInterval(-interval * 0.95),
                     forKey: "UpdateChecker.test.test.lastCheck")
        let client = StubReleaseClient(release: try release(tag: "1.0"))
        let checker = makeChecker(client: client, throttleFraction: 1.0)
        checker.checkInBackground()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.calls, 0,
                       "a full-interval throttle must still skip a slightly-early fire")
    }

    // MARK: Re-entrancy (Lucerne/Invoque)

    func testCheckNowDuringInFlightCheckIsConsumedByThatRun() async throws {
        let client = SuspendedReleaseClient(release: try release(tag: "9.9.9"))
        let checker = makeChecker(client: client)
        let probe = PendingProbe()
        checker.onPendingUpdateChanged = probe.handler

        checker.checkInBackground()        // fetch suspends mid-flight
        checker.checkNow()                 // marks this run user-requested
        client.resume()

        let done = await waitFor { !checker.isChecking }
        XCTAssertTrue(done)
        let fetchedOnce = await waitFor { client.calls >= 1 }
        XCTAssertTrue(fetchedOnce, "the user-initiated run must fetch")
        let leakedSecondFetch = await waitFor { client.calls > 1 }
        XCTAssertFalse(leakedSecondFetch,
                       "the user-request flag must be consumed at the read site")
        XCTAssertTrue(probe.calls.isEmpty,
                      "a run requested mid-flight must present, not queue")
    }

    func testOlderReleaseDoesNothing() async throws {
        let client = StubReleaseClient(release: try release(tag: "0.5"))
        let checker = makeChecker(client: client)
        let probe = PendingProbe()
        checker.onPendingUpdateChanged = probe.handler

        checker.checkInBackground()
        let reached = await waitFor { client.calls == 1 }
        XCTAssertTrue(reached, "the check should reach the client")
        let done = await waitFor { !checker.isChecking }
        XCTAssertTrue(done)
        XCTAssertTrue(probe.calls.isEmpty)
    }

    // MARK: Alerts

    /// Zap and Invoque hand activation back to the previously active app once
    /// an alert closes; the hooks run around every alert, in order.
    func testAlertRunsBetweenActivateAndRestoreHooks() async throws {
        let events = EventLog()
        let checker = UpdateChecker(
            configuration: .init(owner: "test", repo: "test", appName: "Test", currentVersion: "1.0",
                                 activateForAlert: { events.append("activate") },
                                 restoreAfterAlert: { events.append("restore") }),
            defaults: defaults, client: StubReleaseClient(release: try release(tag: "1.0")))
        checker.alertSink = { _ in
            events.append("alert")
            return .alertFirstButtonReturn
        }

        checker.checkNow()
        let shown = await waitFor { events.all.count == 3 }
        XCTAssertTrue(shown)
        XCTAssertEqual(events.all, ["activate", "alert", "restore"])
    }

    func testCheckNowReportsUpToDate() async throws {
        let client = StubReleaseClient(release: try release(tag: "1.0"))
        let checker = makeChecker(client: client)
        let recorder = AlertRecorder()
        checker.alertSink = recorder.makeSink()

        checker.checkNow()
        let shown = await waitFor { recorder.count > 0 }
        XCTAssertTrue(shown)
        XCTAssertEqual(recorder.messageTexts.first, "You're up to date")
    }

    func testInvalidCurrentVersionHasItsOwnAlert() async throws {
        let client = StubReleaseClient(release: try release(tag: "2.0.0"))
        let checker = makeChecker(client: client, currentVersion: "broken")
        let recorder = AlertRecorder()
        checker.alertSink = recorder.makeSink()

        checker.checkNow()
        let shown = await waitFor { recorder.count > 0 }
        XCTAssertTrue(shown)
        XCTAssertEqual(recorder.messageTexts.first, "Couldn't compare versions")
        XCTAssertEqual(recorder.informativeTexts.first,
                       "The installed version 'broken' is not a valid semantic version.")
    }

    func testInvalidReleaseTagHasItsOwnAlert() async throws {
        let client = StubReleaseClient(release: try release(tag: "latest"))
        let checker = makeChecker(client: client)
        let recorder = AlertRecorder()
        checker.alertSink = recorder.makeSink()

        checker.checkNow()
        let shown = await waitFor { recorder.count > 0 }
        XCTAssertTrue(shown)
        XCTAssertEqual(recorder.messageTexts.first, "Couldn't compare versions")
        XCTAssertEqual(recorder.informativeTexts.first,
                       "The release tag 'latest' is not a valid semantic version.")
        XCTAssertEqual(recorder.buttonTitles.first, ["OK"])
    }

    func testInvalidVersionAlertCanOfferTheReleasePage() async throws {
        let client = StubReleaseClient(release: try release(tag: "latest"))
        let checker = makeChecker(client: client, offersReleasePageForInvalidVersions: true)
        let opened = OpenedURLs()
        checker.openURL = { opened.append($0) }
        let recorder = AlertRecorder()
        recorder.response = .alertFirstButtonReturn
        checker.alertSink = recorder.makeSink()

        checker.checkNow()
        let didOpen = await waitFor { !opened.all.isEmpty }
        XCTAssertTrue(didOpen)
        XCTAssertEqual(recorder.messageTexts.first, "Couldn't compare versions")
        XCTAssertEqual(recorder.informativeTexts.first,
                       "The release tag 'latest' is not a valid semantic version."
                       + " Open the release page to see whether a newer version is available.")
        XCTAssertEqual(recorder.buttonTitles.first, ["Open Release Page", "Cancel"])
        // The fixture's html_url is not on github.com, so the validated
        // fallback opens instead.
        XCTAssertEqual(opened.all, [URL(string: "https://github.com/test/test/releases")!])
    }

    func testCancellingTheReleasePageOfferOpensNothing() async throws {
        let client = StubReleaseClient(release: try release(tag: "2.0.0"))
        let checker = makeChecker(client: client, currentVersion: "broken",
                                  offersReleasePageForInvalidVersions: true)
        let recorder = AlertRecorder()
        checker.alertSink = recorder.makeSink()  // answers the second button, Cancel

        checker.checkNow()
        let done = await waitFor { recorder.count > 0 && !checker.isChecking }
        XCTAssertTrue(done)
        XCTAssertEqual(recorder.buttonTitles.first, ["Open Release Page", "Cancel"])
        XCTAssertTrue(recorder.informativeTexts.first?
            .hasPrefix("The installed version 'broken' is not a valid semantic version.") ?? false)
    }

    func testBackgroundFailureIsNotPresented() async throws {
        let checker = makeChecker(client: FailingReleaseClient())
        let recorder = AlertRecorder()
        checker.alertSink = recorder.makeSink()

        checker.checkInBackground()
        let done = await waitFor { !checker.isChecking }
        XCTAssertTrue(done)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.count, 0, "background checks never show an error")
    }

    func testSkipButtonStoresTheRawTag() async throws {
        let client = StubReleaseClient(release: try release(tag: "v9.9.9"))
        let checker = makeChecker(client: client)
        let recorder = AlertRecorder()
        recorder.response = .alertThirdButtonReturn
        checker.alertSink = recorder.makeSink()

        checker.checkNow()
        let shown = await waitFor { recorder.count > 0 }
        XCTAssertTrue(shown)
        let stored = await waitFor {
            self.defaults.string(forKey: "UpdateChecker.test.test.skippedVersion") != nil
        }
        XCTAssertTrue(stored)
        XCTAssertEqual(defaults.string(forKey: "UpdateChecker.test.test.skippedVersion"),
                       "v9.9.9")
    }

    // MARK: Persisted state

    func testDefaultKeyPrefixAndExactKeys() throws {
        let configuration = UpdateChecker.Configuration(
            owner: "L-K-M", repo: "Zap", appName: "Zap", currentVersion: "1.0")
        XCTAssertEqual(configuration.defaultsKeyPrefix, "UpdateChecker.L-K-M.Zap")

        let checker = UpdateChecker(configuration: configuration, defaults: defaults)
        XCTAssertTrue(checker.automaticChecksEnabled, "default ON unless explicitly off")

        checker.automaticChecksEnabled = false
        XCTAssertEqual(defaults.bool(forKey: "UpdateChecker.L-K-M.Zap.enabled"), false)
        XCTAssertNil(defaults.object(forKey: "UpdateChecker.L-K-M.Zap.lastCheck"))
        XCTAssertNil(defaults.string(forKey: "UpdateChecker.L-K-M.Zap.skippedVersion"))
    }

    func testLastCheckIsPersistedAfterASuccessfulFetch() async throws {
        let checker = makeChecker(client: StubReleaseClient(release: try release(tag: "1.0")))
        checker.checkInBackground()
        let done = await waitFor { !checker.isChecking }
        XCTAssertTrue(done)
        let stored = await waitFor {
            self.defaults.object(forKey: "UpdateChecker.test.test.lastCheck") is Date
        }
        XCTAssertTrue(stored)
    }

    func testDownloadFallbackFileNameDefaultsToAppName() {
        let configuration = UpdateChecker.Configuration(
            owner: "L-K-M", repo: "Zap", appName: "Zap", currentVersion: "1.0")
        XCTAssertEqual(configuration.downloadFallbackFileName, "Zap-update")
    }

    // MARK: Untrusted release data

    /// `html_url` comes from the untrusted API response; only this
    /// repository's GitHub release pages may be opened.
    func testReleasePageURLAcceptsOnlyThisRepositoryOnGitHub() {
        let page = { (raw: String) in
            UpdateChecker.releasePageURL(for: URL(string: raw)!, owner: "L-K-M", repo: "Zap")
        }
        let fallback = URL(string: "https://github.com/L-K-M/Zap/releases")!
        let good = URL(string: "https://github.com/L-K-M/Zap/releases/tag/v1.2.0")!
        XCTAssertEqual(page(good.absoluteString), good)
        XCTAssertEqual(page("https://GitHub.com/l-k-m/zap/releases/tag/v1.2.0"),
                       URL(string: "https://GitHub.com/l-k-m/zap/releases/tag/v1.2.0")!)
        XCTAssertEqual(page("https://evil.example/L-K-M/Zap/releases/tag/v1.2.0"), fallback)
        XCTAssertEqual(page("http://github.com/L-K-M/Zap/releases/tag/v1.2.0"), fallback)
        XCTAssertEqual(page("https://github.com/someone-else/Zap/releases/tag/v1.2.0"), fallback)
        XCTAssertEqual(page("https://github.com/L-K-M/Zapper/releases/tag/v1.2.0"), fallback)
        XCTAssertEqual(page("https://github.com:8443/L-K-M/Zap/releases/tag/v1.2.0"), fallback)
        XCTAssertEqual(page("https://github.com@evil.example/L-K-M/Zap/releases"), fallback)
        XCTAssertEqual(page("file:///Applications/Calculator.app"), fallback)
    }

    /// A crafted multi-megabyte tag must not reach an alert unabridged.
    func testDisplayedVersionIsCapped() {
        let long = "1.0.0-" + String(repeating: "a", count: 10_000)
        let shown = UpdateChecker.displayed(long)
        XCTAssertLessThanOrEqual(shown.count, UpdateChecker.maxDisplayedVersionLength + 1)
        XCTAssertTrue(shown.hasSuffix("…"))
        XCTAssertEqual(UpdateChecker.displayed("1.2.3"), "1.2.3")
    }
}
