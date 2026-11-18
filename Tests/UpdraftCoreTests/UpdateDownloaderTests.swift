import XCTest
@testable import UpdraftCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Ported from Zap, Jetty, Invoque and Top Drawer, plus the shared downloader's
/// host allowlist, digest verification and quarantine stamping.
final class UpdateDownloaderTests: XCTestCase {

    private enum StubError: Error {
        case unexpectedRequest
    }

    private struct UnexpectedSession: UpdateDownloadSession {
        func downloadAsset(from url: URL) async throws -> (URL, URLResponse) {
            throw StubError.unexpectedRequest
        }
    }

    private struct StubSession: UpdateDownloadSession {
        let tempURL: URL
        let statusCode: Int
        let responseURL: URL?

        func downloadAsset(from url: URL) async throws -> (URL, URLResponse) {
            let response = HTTPURLResponse(url: responseURL ?? url,
                                           statusCode: statusCode,
                                           httpVersion: nil, headerFields: nil)!
            return (tempURL, response)
        }
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdraftDownloaderTests-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func asset(url: String, size: Int, digest: String? = nil) -> GitHubRelease.Asset {
        GitHubRelease.Asset(name: "App.dmg",
                            contentType: "application/x-apple-diskimage",
                            size: size,
                            browserDownloadURL: URL(string: url)!,
                            digest: digest)
    }

    // MARK: Unique destinations

    func testUniqueDestinationAvoidsCollisions() throws {
        let fm = FileManager.default
        let dir = try makeDirectory("collisions")
        defer { try? fm.removeItem(at: dir) }

        let first = try UpdateDownloader.uniqueDestination(in: dir, fileName: "App.dmg", fileManager: fm)
        XCTAssertEqual(first.lastPathComponent, "App.dmg")
        XCTAssertTrue(fm.createFile(atPath: first.path, contents: Data()))

        let second = try UpdateDownloader.uniqueDestination(in: dir, fileName: "App.dmg", fileManager: fm)
        XCTAssertEqual(second.lastPathComponent, "App-1.dmg")
        XCTAssertTrue(fm.createFile(atPath: second.path, contents: Data()))

        let third = try UpdateDownloader.uniqueDestination(in: dir, fileName: "App.dmg", fileManager: fm)
        XCTAssertEqual(third.lastPathComponent, "App-2.dmg")
    }

    func testUniqueDestinationHandlesNameWithoutExtension() throws {
        let fm = FileManager.default
        let dir = try makeDirectory("no-extension")
        defer { try? fm.removeItem(at: dir) }

        let first = try UpdateDownloader.uniqueDestination(in: dir, fileName: "App", fileManager: fm)
        XCTAssertEqual(first.lastPathComponent, "App")
        XCTAssertTrue(fm.createFile(atPath: first.path, contents: Data()))

        let second = try UpdateDownloader.uniqueDestination(in: dir, fileName: "App", fileManager: fm)
        XCTAssertEqual(second.lastPathComponent, "App-1")
    }

    func testUniqueDestinationSkipsExistingFilesAndDanglingSymlinks() throws {
        let fm = FileManager.default
        let dir = try makeDirectory("symlinks")
        defer { try? fm.removeItem(at: dir) }

        XCTAssertEqual(
            try UpdateDownloader.uniqueDestination(in: dir, fileName: "App.dmg").lastPathComponent,
            "App.dmg")

        try Data().write(to: dir.appendingPathComponent("App.dmg"))
        try Data().write(to: dir.appendingPathComponent("App-1.dmg"))
        XCTAssertEqual(
            try UpdateDownloader.uniqueDestination(in: dir, fileName: "App.dmg").lastPathComponent,
            "App-2.dmg")

        // A dangling symlink at the next candidate still counts as "taken":
        // fileExists(atPath:) follows the link and would report false.
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("App-2.dmg"),
            withDestinationURL: dir.appendingPathComponent("does-not-exist.dmg"))
        XCTAssertEqual(
            try UpdateDownloader.uniqueDestination(in: dir, fileName: "App.dmg").lastPathComponent,
            "App-3.dmg")
    }

    func testUniqueDestinationThrowsWhenAttemptCapIsExhausted() throws {
        let fm = FileManager.default
        let dir = try makeDirectory("cap")
        defer { try? fm.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("App.dmg"))
        try Data().write(to: dir.appendingPathComponent("App-1.dmg"))
        try Data().write(to: dir.appendingPathComponent("App-2.dmg"))

        XCTAssertThrowsError(
            try UpdateDownloader.uniqueDestination(in: dir, fileName: "App.dmg", maxAttempts: 2)
        ) { error in
            guard case UpdateDownloader.DownloadError.noUniqueFileName(_, let fileName, let attempts) = error else {
                return XCTFail("Expected noUniqueFileName, got \(error)")
            }
            XCTAssertEqual(fileName, "App.dmg")
            XCTAssertEqual(attempts, 2)
        }

        // The default cap is far beyond any real Downloads folder.
        XCTAssertEqual(
            try UpdateDownloader.uniqueDestination(in: dir, fileName: "App.dmg").lastPathComponent,
            "App-3.dmg")
    }

    // MARK: Filename sanitization

    func testSanitizedFileNameStripsTraversal() {
        XCTAssertEqual(UpdateDownloader.sanitizedFileName("../../evil.sh", fallback: "update"),
                       "evil.sh")
        XCTAssertEqual(UpdateDownloader.sanitizedFileName("sub/dir/App.dmg", fallback: "update"),
                       "App.dmg")
        XCTAssertEqual(UpdateDownloader.sanitizedFileName("..", fallback: "update"), "update")
        XCTAssertEqual(UpdateDownloader.sanitizedFileName(".", fallback: "update"), "update")
        XCTAssertEqual(UpdateDownloader.sanitizedFileName("/", fallback: "update"), "update")
        XCTAssertEqual(UpdateDownloader.sanitizedFileName("//", fallback: "update"), "update")
        XCTAssertEqual(UpdateDownloader.sanitizedFileName("", fallback: "update"), "update")
        XCTAssertEqual(UpdateDownloader.sanitizedFileName("App.dmg", fallback: "update"),
                       "App.dmg")
    }

    func testSanitizedFileNameReplacesControlCharacters() {
        XCTAssertEqual(UpdateDownloader.sanitizedFileName("App\u{0000}.zip", fallback: "update"),
                       "App-.zip")
    }

    func testUniqueDestinationSanitizesPathlikeNames() throws {
        let fm = FileManager.default
        let dir = try makeDirectory("pathlike")
        defer { try? fm.removeItem(at: dir) }

        let nested = try UpdateDownloader.uniqueDestination(
            in: dir, fileName: "../../App.dmg", fileManager: fm)
        // Compare paths, not URLs: `deletingLastPathComponent()` always yields a
        // trailing slash that `dir` lacks.
        XCTAssertEqual(nested.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(nested.lastPathComponent, "App.dmg")

        // The shared static uses the package fallback, not an app name; the
        // app-specific fallback travels through `download(_:to:)`.
        let empty = try UpdateDownloader.uniqueDestination(in: dir, fileName: "   ", fileManager: fm)
        XCTAssertEqual(empty.lastPathComponent, "update")

        let slashes = try UpdateDownloader.uniqueDestination(in: dir, fileName: "///", fileManager: fm)
        XCTAssertEqual(slashes.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(slashes.lastPathComponent, "update")
    }

    // MARK: Size validation

    func testDownloadedAssetSizeValidation() throws {
        let dir = try makeDirectory("size")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("App.dmg")
        try Data([0, 1, 2, 3]).write(to: file)

        XCTAssertNoThrow(try UpdateDownloader.validateDownloadedFile(at: file, expectedSize: 4))
        XCTAssertThrowsError(
            try UpdateDownloader.validateDownloadedFile(at: file, expectedSize: 5)
        ) { error in
            guard case UpdateDownloader.DownloadError.sizeMismatch(let expected, let actual) = error else {
                return XCTFail("Expected sizeMismatch, got \(error)")
            }
            XCTAssertEqual(expected, 5)
            XCTAssertEqual(actual, 4)
        }
        XCTAssertThrowsError(
            try UpdateDownloader.validateDownloadedFile(at: file, expectedSize: 3))
    }

    // MARK: Host allowlist

    func testAllowedDownloadURLTable() {
        for host in ["github.com", "api.github.com", "codeload.github.com",
                     "objects.githubusercontent.com", "release-assets.githubusercontent.com"] {
            XCTAssertTrue(UpdateDownloader.isAllowedDownloadURL(
                URL(string: "https://\(host)/asset.dmg")!), "\(host) must be allowed")
        }
        XCTAssertFalse(UpdateDownloader.isAllowedDownloadURL(
            URL(string: "http://github.com/asset.dmg")!))
        XCTAssertFalse(UpdateDownloader.isAllowedDownloadURL(
            URL(string: "https://evil.example/asset.dmg")!))
        XCTAssertFalse(UpdateDownloader.isAllowedDownloadURL(
            URL(string: "https://github.com.evil.example/asset.dmg")!))
        XCTAssertTrue(UpdateDownloader.isAllowedDownloadURL(
            URL(string: "HTTPS://GitHub.com/asset.dmg")!))
    }

    // MARK: Download flow

    func testRejectsNonHTTPSAssetWithoutStartingDownload() async {
        let downloader = UpdateDownloader(session: UnexpectedSession(), fileManager: .default)

        do {
            _ = try await downloader.download(
                asset(url: "http://example.com/App.dmg", size: 1), to: URL(fileURLWithPath: "/tmp"))
            XCTFail("Expected an insecure-URL error")
        } catch let error as UpdateDownloader.DownloadError {
            guard case .insecureURL(let url) = error else {
                return XCTFail("Unexpected download error: \(error)")
            }
            XCTAssertEqual(url.scheme, "http")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsDisallowedHostWithoutStartingDownload() async {
        let downloader = UpdateDownloader(session: UnexpectedSession(), fileManager: .default)

        do {
            _ = try await downloader.download(
                asset(url: "https://evil.example/App.dmg", size: 1),
                to: URL(fileURLWithPath: "/tmp"))
            XCTFail("Expected an insecure-URL error")
        } catch let error as UpdateDownloader.DownloadError {
            guard case .insecureURL = error else {
                return XCTFail("Unexpected download error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsSizeMismatchAndRemovesTemporaryFile() async throws {
        let fm = FileManager.default
        let dir = try makeDirectory("mismatch")
        defer { try? fm.removeItem(at: dir) }

        let tempURL = dir.appendingPathComponent("download.tmp")
        let contents = Data("incomplete".utf8)
        try contents.write(to: tempURL)
        let downloader = UpdateDownloader(session: StubSession(tempURL: tempURL, statusCode: 200, responseURL: nil),
                                          fileManager: fm)

        do {
            _ = try await downloader.download(
                asset(url: "https://github.com/L-K-M/App/releases/download/v1/App.dmg",
                      size: contents.count + 1),
                to: dir.appendingPathComponent("out"))
            XCTFail("Expected a file-size mismatch")
        } catch let error as UpdateDownloader.DownloadError {
            guard case .sizeMismatch(let expected, let actual) = error else {
                return XCTFail("Unexpected download error: \(error)")
            }
            XCTAssertEqual(expected, contents.count + 1)
            XCTAssertEqual(actual, contents.count)
        }
        XCTAssertFalse(fm.fileExists(atPath: tempURL.path))
    }

    func testRejectsBadResponseAndRemovesTemporaryFile() async throws {
        let fm = FileManager.default
        let dir = try makeDirectory("bad-response")
        defer { try? fm.removeItem(at: dir) }

        let tempURL = dir.appendingPathComponent("download.tmp")
        try Data("payload".utf8).write(to: tempURL)
        let downloader = UpdateDownloader(session: StubSession(tempURL: tempURL, statusCode: 500, responseURL: nil),
                                          fileManager: fm)

        do {
            _ = try await downloader.download(
                asset(url: "https://github.com/L-K-M/App/releases/download/v1/App.dmg", size: 7),
                to: dir.appendingPathComponent("out"))
            XCTFail("Expected an HTTP error")
        } catch let error as UpdateDownloader.DownloadError {
            guard case .badResponse(let code) = error else {
                return XCTFail("Unexpected download error: \(error)")
            }
            XCTAssertEqual(code, 500)
        }
        XCTAssertFalse(fm.fileExists(atPath: tempURL.path))
    }

    func testRejectsDisallowedFinalResponseURL() async throws {
        let fm = FileManager.default
        let dir = try makeDirectory("final-url")
        defer { try? fm.removeItem(at: dir) }

        let tempURL = dir.appendingPathComponent("download.tmp")
        try Data("payload".utf8).write(to: tempURL)
        let downloader = UpdateDownloader(
            session: StubSession(tempURL: tempURL, statusCode: 200,
                                 responseURL: URL(string: "http://evil.example/App.dmg")!),
            fileManager: fm)

        do {
            _ = try await downloader.download(
                asset(url: "https://github.com/L-K-M/App/releases/download/v1/App.dmg", size: 7),
                to: dir.appendingPathComponent("out"))
            XCTFail("Expected an insecure final-URL error")
        } catch let error as UpdateDownloader.DownloadError {
            guard case .insecureURL = error else {
                return XCTFail("Unexpected download error: \(error)")
            }
        }
        XCTAssertFalse(fm.fileExists(atPath: tempURL.path))
    }

    func testDownloadSucceedsAndCleansUp() async throws {
        let fm = FileManager.default
        let dir = try makeDirectory("success")
        defer { try? fm.removeItem(at: dir) }

        let tempURL = dir.appendingPathComponent("download.tmp")
        let contents = Data("payload".utf8)
        try contents.write(to: tempURL)
        let destination = dir.appendingPathComponent("destination")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let downloader = UpdateDownloader(session: StubSession(tempURL: tempURL, statusCode: 200, responseURL: nil),
                                          fileManager: fm)
        let fileURL = try await downloader.download(
            asset(url: "https://github.com/L-K-M/App/releases/download/v1/App.dmg",
                  size: contents.count),
            to: destination)

        XCTAssertEqual(fileURL.lastPathComponent, "App.dmg")
        XCTAssertEqual(try Data(contentsOf: fileURL), contents)
        XCTAssertFalse(fm.fileExists(atPath: tempURL.path), "the temp file must not leak")
    }

    func testDownloadUsesConfiguredFallbackFileName() async throws {
        let fm = FileManager.default
        let dir = try makeDirectory("fallback")
        defer { try? fm.removeItem(at: dir) }

        let tempURL = dir.appendingPathComponent("download.tmp")
        try Data("payload".utf8).write(to: tempURL)
        let destination = dir.appendingPathComponent("destination")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let downloader = UpdateDownloader(
            session: StubSession(tempURL: tempURL, statusCode: 200, responseURL: nil),
            fileManager: fm, fallbackFileName: "Zap-update")
        let fileURL = try await downloader.download(
            GitHubRelease.Asset(name: "..", contentType: "application/octet-stream",
                                size: 7,
                                browserDownloadURL: URL(string: "https://github.com/x/App.dmg")!),
            to: destination)
        XCTAssertEqual(fileURL.lastPathComponent, "Zap-update")
    }

    #if canImport(CryptoKit)
    func testDigestMismatchThrows() async throws {
        let fm = FileManager.default
        let dir = try makeDirectory("digest-mismatch")
        defer { try? fm.removeItem(at: dir) }

        let tempURL = dir.appendingPathComponent("download.tmp")
        let contents = Data("payload".utf8)
        try contents.write(to: tempURL)
        let actualDigest = SHA256.hash(data: contents)
            .map { String(format: "%02x", $0) }.joined()
        let downloader = UpdateDownloader(session: StubSession(tempURL: tempURL, statusCode: 200, responseURL: nil),
                                          fileManager: fm)

        do {
            _ = try await downloader.download(
                asset(url: "https://github.com/x/App.dmg", size: contents.count,
                      digest: "sha256:deadbeef"),
                to: dir.appendingPathComponent("out"))
            XCTFail("Expected a digest mismatch")
        } catch let error as UpdateDownloader.DownloadError {
            guard case .digestMismatch(let expected, let actual) = error else {
                return XCTFail("Unexpected download error: \(error)")
            }
            XCTAssertEqual(expected, "deadbeef")
            XCTAssertEqual(actual, actualDigest)
        }
        XCTAssertFalse(fm.fileExists(atPath: tempURL.path))
    }

    func testMatchingDigestSucceeds() async throws {
        let fm = FileManager.default
        let dir = try makeDirectory("digest-match")
        defer { try? fm.removeItem(at: dir) }

        let tempURL = dir.appendingPathComponent("download.tmp")
        let contents = Data("payload".utf8)
        try contents.write(to: tempURL)
        let expected = SHA256.hash(data: contents)
            .map { String(format: "%02x", $0) }.joined()
        let destination = dir.appendingPathComponent("out")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let downloader = UpdateDownloader(session: StubSession(tempURL: tempURL, statusCode: 200, responseURL: nil),
                                          fileManager: fm)
        let fileURL = try await downloader.download(
            asset(url: "https://github.com/x/App.dmg", size: contents.count,
                  digest: "sha256:\(expected)"),
            to: destination)
        XCTAssertEqual(fileURL.lastPathComponent, "App.dmg")
    }

    func testSha256HexStreamsInChunks() throws {
        let dir = try makeDirectory("sha256")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("blob.bin")
        let contents = Data(repeating: 0xAB, count: (1 << 20) + 17)
        try contents.write(to: file)
        let expected = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try UpdateDownloader.sha256Hex(ofFileAt: file), expected)
    }
    #endif

    #if !canImport(CryptoKit)
    func testDigestIsSkippedWhereCryptoKitIsUnavailable() async throws {
        // On Linux the digest check is compiled out rather than failing the
        // download: a missing digest algorithm must not brick updates.
        let fm = FileManager.default
        let dir = try makeDirectory("digest-skip")
        defer { try? fm.removeItem(at: dir) }
        let tempURL = dir.appendingPathComponent("download.tmp")
        try Data("payload".utf8).write(to: tempURL)
        let destination = dir.appendingPathComponent("out")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let downloader = UpdateDownloader(session: StubSession(tempURL: tempURL, statusCode: 200, responseURL: nil),
                                          fileManager: fm)
        let fileURL = try await downloader.download(
            asset(url: "https://github.com/x/App.dmg", size: 7, digest: "sha256:deadbeef"),
            to: destination)
        XCTAssertEqual(fileURL.lastPathComponent, "App.dmg")
    }
    #endif

    #if canImport(Darwin)
    func testDownloadStampsQuarantineForGatekeeper() async throws {
        let fm = FileManager.default
        let dir = try makeDirectory("quarantine")
        defer { try? fm.removeItem(at: dir) }

        let tempURL = dir.appendingPathComponent("download.tmp")
        try Data("payload".utf8).write(to: tempURL)
        let destination = dir.appendingPathComponent("destination")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let downloader = UpdateDownloader(session: StubSession(tempURL: tempURL, statusCode: 200, responseURL: nil),
                                          fileManager: fm)
        let fileURL = try await downloader.download(
            asset(url: "https://github.com/x/App.dmg", size: 7), to: destination)

        var length = getxattr(fileURL.path, "com.apple.quarantine", nil, 0, 0, 0)
        XCTAssertGreaterThan(length, 0, "the downloaded file must carry the quarantine attribute")
        var buffer = [CChar](repeating: 0, count: length)
        length = getxattr(fileURL.path, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
        let value = String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        XCTAssertTrue(value.hasPrefix("0081;"), "unexpected quarantine value: \(value)")
        XCTAssertTrue(value.components(separatedBy: ";").count >= 3)
    }
    #endif
}
