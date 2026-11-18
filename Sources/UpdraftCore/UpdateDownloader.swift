import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Downloads a release asset into a directory (the user's Downloads folder for
/// the update flow), picking a non-colliding filename and verifying what
/// arrived: every URL the download passes through — the initial URL, each
/// redirect hop, and the URL the response came from — must be HTTPS on a GitHub
/// host, the size must match the API's `size`, and on Apple platforms, when the
/// API supplied a `sha256:` digest, the file's SHA-256 must match it (Linux has
/// no CryptoKit, so the digest is not checked there).
public struct UpdateDownloader {

    public enum DownloadError: LocalizedError {
        case insecureURL(URL)
        case badResponse(Int)
        case sizeMismatch(expected: Int, actual: Int)
        case digestMismatch(expected: String, actual: String)
        case noUniqueFileName(directory: String, fileName: String, attempts: Int)

        public var errorDescription: String? {
            switch self {
            case .insecureURL:
                return "The update asset URL is not a trusted GitHub HTTPS URL."
            case .badResponse(let code):
                return "The update download returned HTTP \(code)."
            case .sizeMismatch(let expected, let actual):
                return "The downloaded update failed its size check (expected \(expected) bytes, received \(actual))."
            case .digestMismatch(let expected, let actual):
                // `expected` comes from the API response; keep a crafted
                // megabyte-long value out of the alert.
                let shownExpected = expected.count > 80 ? expected.prefix(80) + "…" : expected
                return "SHA-256 mismatch: expected \(shownExpected), got \(actual). The download was tampered with."
            case .noUniqueFileName(let directory, let fileName, let attempts):
                return "Couldn't find an unused name for \(fileName) in \(directory) after \(attempts) attempts."
            }
        }
    }

    /// Hosts a release asset may be fetched from. The API response itself comes
    /// from api.github.com over HTTPS; the asset URL must stay on GitHub.
    /// `browser_download_url` answers a 302 to release-assets.githubusercontent.com;
    /// objects.githubusercontent.com is that CDN's older name.
    private static let allowedHosts: Set<String> = [
        "github.com", "api.github.com", "codeload.github.com",
        "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    /// Longest file name, in UTF-8 bytes, the downloader writes. File systems
    /// cap a name at 255 bytes; the margin leaves room for the "-N" suffix
    /// `uniqueDestination` adds on a collision.
    static let maxFileNameBytes = 200

    /// Remembers the redirect target the session vetoed, so the refusal can be
    /// reported by URL: a refused hop ends the task with the bare 3xx response,
    /// which on its own would surface as an unhelpful HTTP error.
    private static let redirectGate = RedirectGate()

    /// The session used when none is injected. It carries a resource timeout so
    /// a stalled download eventually fails instead of hanging forever, and a
    /// task delegate that applies the host policy to every redirect hop —
    /// without it, a `browser_download_url` that 302s to an attacker-chosen host
    /// would be followed unchecked.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30          // per chunk of progress
        configuration.timeoutIntervalForResource = 15 * 60    // whole-file ceiling
        return URLSession(configuration: configuration, delegate: redirectGate, delegateQueue: nil)
    }()

    private let session: any UpdateDownloadSession
    private let fileManager: FileManager
    private let fallbackFileName: String
    private let redirectGate: RedirectGate?

    public init(session: any UpdateDownloadSession = UpdateDownloader.defaultSession,
                fileManager: FileManager = .default,
                fallbackFileName: String = "update") {
        self.session = session
        self.fileManager = fileManager
        self.fallbackFileName = fallbackFileName
        // Only the shared default session has the redirect delegate; a custom
        // session is the caller's responsibility, but its initial and final URLs
        // are still checked.
        self.redirectGate = (session as? URLSession) === UpdateDownloader.defaultSession
            ? UpdateDownloader.redirectGate
            : nil
    }

    /// Downloads `asset` to `~/Downloads`, returning the saved file URL.
    public func downloadToDownloads(_ asset: GitHubRelease.Asset) async throws -> URL {
        let downloads = try fileManager.url(for: .downloadsDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: true)
        return try await download(asset, to: downloads)
    }

    /// Downloads `asset` into `directory`, returning the saved file URL. The
    /// download is verified before it is moved into place: HTTPS GitHub host on
    /// every redirect hop, exact size, and SHA-256 when the API provided a
    /// digest.
    public func download(_ asset: GitHubRelease.Asset, to directory: URL) async throws -> URL {
        let url = asset.browserDownloadURL
        guard Self.isAllowedDownloadURL(url) else {
            throw DownloadError.insecureURL(url)
        }
        // The gate is shared by every download on the default session, so its
        // refusals are keyed by the URL each download started from; clear any
        // stale one for this URL first.
        redirectGate?.takeRefusal(for: url)
        let (tempURL, response) = try await session.downloadAsset(from: url)
        var removeTemporaryFile = true
        defer {
            if removeTemporaryFile { try? fileManager.removeItem(at: tempURL) }
        }

        if let refused = redirectGate?.takeRefusal(for: url) {
            throw DownloadError.insecureURL(refused)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.badResponse(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.badResponse(http.statusCode)
        }
        // The delegate vetted each hop; still check the URL the bytes actually
        // came from before accepting the file.
        if let finalURL = response.url, !Self.isAllowedDownloadURL(finalURL) {
            throw DownloadError.insecureURL(finalURL)
        }
        try Self.validateDownloadedFile(at: tempURL, expectedSize: asset.size,
                                        fileManager: fileManager)
        #if canImport(CryptoKit)
        if let digest = asset.digest, digest.lowercased().hasPrefix("sha256:") {
            let expected = String(digest.dropFirst("sha256:".count)).lowercased()
            let actual = try Self.sha256Hex(ofFileAt: tempURL)
            if actual != expected {
                throw DownloadError.digestMismatch(expected: expected, actual: actual)
            }
        }
        #endif

        // Quarantine the verified file before it reaches the destination, so no
        // crash or failure between the move and the stamp can leave an
        // unquarantined payload there. The stamp is repeated after the move in
        // case a cross-volume move dropped the attribute.
        #if canImport(Darwin)
        Self.applyQuarantine(to: tempURL)
        #endif

        let fileName = Self.sanitizedFileName(asset.name, fallback: fallbackFileName)
        // Retry the name race a few times: a same-named file appearing between
        // the exists-check and the move shouldn't discard a finished download.
        for _ in 0..<5 {
            let destination = try Self.uniqueDestination(in: directory, fileName: fileName,
                                                         fileManager: fileManager)
            do {
                try fileManager.moveItem(at: tempURL, to: destination)
                removeTemporaryFile = false
                #if canImport(Darwin)
                Self.applyQuarantine(to: destination)
                #endif
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                // Don't strand a full-size temp file when the move fails
                // (disk-full on another volume, permissions).
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Whether `url` may serve a release asset: HTTPS on an allowlisted host and
    /// the default port.
    public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host.map { allowedHosts.contains($0.lowercased()) } == true
            && (url.port == nil || url.port == 443)
    }

    /// Rejects truncated or unexpectedly enlarged downloads before they leave
    /// the private URLSession temporary location. The size is checked even when
    /// the API reports zero, so a 0-byte asset is a real failure. This is an
    /// integrity baseline, not a substitute for signature/Team-ID verification.
    public static func validateDownloadedFile(at url: URL, expectedSize: Int,
                                              fileManager: FileManager = .default) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard actualSize == expectedSize else {
            throw DownloadError.sizeMismatch(expected: expectedSize, actual: actualSize)
        }
    }

    /// A non-colliding URL in `directory` for `fileName` (`Foo.dmg`, then `Foo-1.dmg`,
    /// `Foo-2.dmg`, …) so re-downloading never clobbers an existing file. Throws
    /// `DownloadError.noUniqueFileName` if every candidate up to `maxAttempts` is taken.
    public static func uniqueDestination(in directory: URL, fileName: String,
                                         fileManager: FileManager = .default,
                                         maxAttempts: Int = 10_000) throws -> URL {
        let name = sanitizedFileName(fileName, fallback: "update")
        let first = directory.appendingPathComponent(name)
        guard itemExists(at: first, fileManager: fileManager) else { return first }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 1...max(1, maxAttempts) {
            let candidateName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !itemExists(at: candidate, fileManager: fileManager) { return candidate }
        }
        throw DownloadError.noUniqueFileName(directory: directory.path, fileName: name,
                                             attempts: max(1, maxAttempts))
    }

    /// GitHub asset names should be filenames, but sanitize defensively before
    /// writing into the destination directory so path separators and control
    /// characters never matter. Leading dots are dropped (a hidden file would
    /// make the reveal after a successful download show nothing) and the name
    /// is capped at `maxFileNameBytes`, keeping a short extension. Falls back
    /// when nothing usable remains.
    public static func sanitizedFileName(_ fileName: String, fallback: String) -> String {
        let candidate = (fileName as NSString).lastPathComponent
        let filtered = candidate.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? "-" : String(scalar)
        }.joined()
        // Trimming can expose another leading dot (". .dmg"), so alternate the
        // two until neither changes the name. That also makes the result
        // stable when `uniqueDestination` sanitizes it again.
        var trimmed = filtered
        var previous: String
        repeat {
            previous = trimmed
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        } while trimmed != previous
        guard !trimmed.isEmpty, trimmed != "/" else { return fallback }
        return cappedFileName(trimmed)
    }

    /// `name` shortened to `maxFileNameBytes` UTF-8 bytes, cutting whole
    /// characters from the end of the base name so the extension survives.
    private static func cappedFileName(_ name: String) -> String {
        guard name.utf8.count > maxFileNameBytes else { return name }
        let pathExtension = (name as NSString).pathExtension
        let keepsExtension = !pathExtension.isEmpty && pathExtension.utf8.count <= 16
        let suffix = keepsExtension ? "." + pathExtension : ""
        var base = keepsExtension ? (name as NSString).deletingPathExtension : name
        while !base.isEmpty, base.utf8.count + suffix.utf8.count > maxFileNameBytes {
            base.removeLast()
        }
        return base + suffix
    }

    #if canImport(CryptoKit)
    /// Streams `fileURL` through SHA-256 in 1 MiB chunks and returns the lowercase
    /// hex digest, so hashing a large disk image never holds it all in memory.
    public static func sha256Hex(ofFileAt fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    #endif

    /// Whether *anything* — file, directory, or symlink (dangling or not) — occupies
    /// `url`. `fileExists(atPath:)` follows symlinks, so a dangling symlink reports
    /// false and `moveItem` would then fail (or, worse, the link could be swapped to
    /// point elsewhere). `attributesOfItem(atPath:)` has `lstat` semantics: it reports
    /// the symlink itself without following it.
    private static func itemExists(at url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    #if canImport(Darwin)
    /// Marks the download with `com.apple.quarantine` so Gatekeeper and
    /// notarization checks still apply when the user opens it — the same
    /// protection a browser gives its downloads. URLSession doesn't set it,
    /// so the downloading app must. Best-effort: a failure mustn't fail the
    /// download.
    private static func applyQuarantine(to url: URL) {
        // Flags 0x0081: quarantined + Gatekeeper checks pending — the value
        // browsers stamp on potentially executable payloads. Timestamp is hex
        // seconds; the agent names the embedding app's bundle.
        let timestamp = String(UInt64(Date().timeIntervalSince1970), radix: 16)
        let agent = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Updraft"
        let value = "0081;\(timestamp);\(agent);"
        value.withCString { cValue in
            "com.apple.quarantine".withCString { name in
                _ = setxattr(url.path, name, cValue, strlen(cValue), 0, 0)
            }
        }
    }
    #endif

    /// Session delegate that applies the asset host policy to every redirect hop.
    /// Refused targets are keyed by the task's original URL, so concurrent
    /// downloads of different assets never see each other's refusals. Two
    /// concurrent downloads of the *same* URL share an entry: both still fail,
    /// but one may report the bare 3xx instead of the refused URL. Every
    /// access to `refusedTargets` is lock-protected, so the class is explicitly
    /// `@unchecked Sendable` rather than implicitly non-Sendable.
    private final class RedirectGate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var refusedTargets: [URL: URL] = [:]

        /// Returns and forgets the redirect target refused for a download that
        /// started at `originalURL`, if any (read after the task ends).
        @discardableResult
        func takeRefusal(for originalURL: URL) -> URL? {
            lock.lock()
            defer { lock.unlock() }
            return refusedTargets.removeValue(forKey: originalURL)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let target = request.url, UpdateDownloader.isAllowedDownloadURL(target) else {
                if let original = task.originalRequest?.url {
                    lock.lock()
                    // A refusal with no target URL still has to be reported.
                    refusedTargets[original] = request.url ?? original
                    lock.unlock()
                }
                completionHandler(nil)  // refuse: the task ends with the 3xx response
                return
            }
            completionHandler(request)
        }
    }
}
