import XCTest
#if canImport(FoundationNetworking)
// Linux splits URLRequest and HTTPURLResponse out of Foundation.
import FoundationNetworking
#endif
@testable import UpdraftCore

/// Ported from Invoque, plus the shared error copy.
final class GitHubReleaseClientTests: XCTestCase {

    private func release(tag: String, draft: Bool = false) throws -> GitHubRelease {
        let json = """
        {
          "tag_name": "\(tag)",
          "html_url": "https://example.com/r",
          "prerelease": false, "draft": \(draft), "assets": []
        }
        """
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    func testNewestParseableSkipsUnparsableTags() throws {
        let releases = [
            try release(tag: "nightly"),
            try release(tag: "v1.2.0"),
            try release(tag: "build-42"),
            try release(tag: "v1.10.0"),
        ]
        XCTAssertEqual(GitHubReleaseClient.newestParseableRelease(releases)?.tagName,
                       "v1.10.0")
    }

    func testNewestParseableAllUnparsableReturnsNil() throws {
        let releases = [try release(tag: "nightly"), try release(tag: "build-42")]
        XCTAssertNil(GitHubReleaseClient.newestParseableRelease(releases))
        XCTAssertNil(GitHubReleaseClient.newestParseableRelease([]))
    }

    func testNewestParseableExcludesDrafts() throws {
        let releases = [
            try release(tag: "v9.9.9", draft: true),
            try release(tag: "v1.0.0"),
        ]
        XCTAssertEqual(GitHubReleaseClient.newestParseableRelease(releases)?.tagName,
                       "v1.0.0")
    }

    func testNoReleasesErrorCopy() {
        XCTAssertEqual(
            GitHubReleaseClient.ClientError.noReleases.errorDescription,
            "No published releases were found (the repository may have moved or gone private).")
        XCTAssertEqual(GitHubReleaseClient.ClientError.badResponse(404).errorDescription,
                       "GitHub returned HTTP 404.")
        XCTAssertEqual(GitHubReleaseClient.ClientError.invalidURL.errorDescription,
                       "Couldn't form a valid GitHub API URL.")
    }
}

// MARK: - Network behaviour (stubbed transport)

/// Records each request and answers from a script, so the client's paging and
/// error mapping can be tested without the network on macOS and Linux.
private final class StubTransport: @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data("[]".utf8)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requestedURLs: [URL] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        let url = try XCTUnwrap(request.url)
        requestedURLs.append(url)
        let reply = replies.isEmpty ? Reply(status: 500) : replies.removeFirst()
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: reply.status,
                                                     httpVersion: "HTTP/1.1",
                                                     headerFields: reply.headers))
        return (reply.body, response)
    }
}

final class GitHubReleaseClientNetworkTests: XCTestCase {

    private func page(_ tags: [String]) -> Data {
        let items = tags.map {
            #"{"tag_name":"\#($0)","html_url":"https://example.com/r","prerelease":true,"draft":false,"assets":[]}"#
        }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    private func client(_ stub: StubTransport) -> GitHubReleaseClient {
        GitHubReleaseClient(owner: "L-K-M", repo: "Example", userAgent: "UpdraftTests",
                            transport: { try stub.send($0) })
    }

    /// GitHub lists releases newest-created first, so a higher version can sit
    /// on a later page. The scan must read past the first page to find it.
    func testPrereleaseScanReadsLaterPages() async throws {
        let perPage = GitHubReleaseClient.releasesPerPage
        let first = (0..<perPage).map { "v1.0.0-beta.\($0)" }
        let stub = StubTransport([
            .init(status: 200, body: page(first)),
            .init(status: 200, body: page(["v2.0.0-rc.1", "v0.9.0"])),
        ])

        let newest = try await client(stub).latestRelease(includePrereleases: true)

        XCTAssertEqual(newest.tagName, "v2.0.0-rc.1")
        XCTAssertEqual(stub.requestedURLs.map(\.query), [
            "per_page=\(perPage)&page=1",
            "per_page=\(perPage)&page=2",
        ], "stops at the first short page")
    }

    func testPrereleaseScanStopsAtThePageBudget() async throws {
        let perPage = GitHubReleaseClient.releasesPerPage
        let budget = GitHubReleaseClient.maximumReleasePages
        let full = (0..<perPage).map { "v1.0.\($0)" }
        let stub = StubTransport(Array(repeating: .init(status: 200, body: page(full)),
                                       count: budget + 1))

        _ = try await client(stub).latestRelease(includePrereleases: true)

        XCTAssertEqual(stub.requestedURLs.count, budget)
    }

    /// No releases at all: an empty first page is a short page, so the scan
    /// stops after one request and surfaces as `noReleases`.
    func testEmptyReleaseListThrowsNoReleases() async throws {
        let stub = StubTransport([.init(status: 200)])

        do {
            _ = try await client(stub).latestRelease(includePrereleases: true)
            XCTFail("expected noReleases")
        } catch GitHubReleaseClient.ClientError.noReleases {
            XCTAssertEqual(stub.requestedURLs.count, 1)
        }
    }

    /// A limit answer on a later page aborts the scan rather than being read
    /// as a short page or decoded as releases.
    func testRateLimitOnALaterPageAbortsTheScan() async throws {
        let perPage = GitHubReleaseClient.releasesPerPage
        let full = (0..<perPage).map { "v1.0.\($0)" }
        let stub = StubTransport([
            .init(status: 200, body: page(full)),
            .init(status: 403, headers: [
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": "1900000000",
            ]),
        ])

        do {
            _ = try await client(stub).latestRelease(includePrereleases: true)
            XCTFail("expected a rate-limit error")
        } catch GitHubReleaseClient.ClientError.rateLimited(let resetsAt) {
            XCTAssertEqual(resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
            XCTAssertEqual(stub.requestedURLs.count, 2)
        }
    }

    func testStableCheckUsesTheLatestEndpointOnly() async throws {
        let latest = #"{"tag_name":"v3.1.0","html_url":"https://example.com/r","prerelease":false,"draft":false,"assets":[]}"#
        let stub = StubTransport([.init(status: 200, body: Data(latest.utf8))])

        let release = try await client(stub).latestRelease(includePrereleases: false)

        XCTAssertEqual(release.tagName, "v3.1.0")
        XCTAssertEqual(stub.requestedURLs.map(\.path), ["/repos/L-K-M/Example/releases/latest"])
    }

    /// GitHub's primary limit: 403 (or 429) with no requests left in the
    /// window. The reset time comes from `x-ratelimit-reset` (epoch seconds).
    func testExhaustedRateLimitIsReportedWithItsResetTime() async throws {
        let stub = StubTransport([.init(status: 403, headers: [
            "x-ratelimit-remaining": "0",
            "x-ratelimit-reset": "1900000000",
        ])])

        do {
            _ = try await client(stub).latestRelease(includePrereleases: false)
            XCTFail("expected a rate-limit error")
        } catch GitHubReleaseClient.ClientError.rateLimited(let resetsAt) {
            XCTAssertEqual(resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
        }
    }

    /// GitHub's secondary limits answer with `retry-after` (seconds).
    func testRetryAfterIsReportedAsARateLimit() async throws {
        let stub = StubTransport([.init(status: 429, headers: ["retry-after": "120"])])
        let before = Date()

        do {
            _ = try await client(stub).latestRelease(includePrereleases: true)
            XCTFail("expected a rate-limit error")
        } catch GitHubReleaseClient.ClientError.rateLimited(let resetsAt) {
            let reset = try XCTUnwrap(resetsAt)
            XCTAssertGreaterThanOrEqual(reset.timeIntervalSince(before), 120)
            XCTAssertLessThan(reset.timeIntervalSince(before), 180)
        }
    }

    func testTooManyRequestsWithoutHeadersIsStillARateLimit() async throws {
        let stub = StubTransport([.init(status: 429)])

        do {
            _ = try await client(stub).latestRelease(includePrereleases: false)
            XCTFail("expected a rate-limit error")
        } catch GitHubReleaseClient.ClientError.rateLimited(let resetsAt) {
            XCTAssertNil(resetsAt)
        }
    }

    /// A 403 that is not about the rate limit (requests remain) stays an
    /// ordinary HTTP error, not a misleading "try again later".
    func testForbiddenWithRequestsLeftIsABadResponse() async throws {
        let stub = StubTransport([.init(status: 403, headers: ["x-ratelimit-remaining": "12"])])

        do {
            _ = try await client(stub).latestRelease(includePrereleases: false)
            XCTFail("expected an HTTP error")
        } catch GitHubReleaseClient.ClientError.badResponse(let code) {
            XCTAssertEqual(code, 403)
        }
    }

    func testRateLimitErrorCopy() throws {
        XCTAssertEqual(GitHubReleaseClient.ClientError.rateLimited(resetsAt: nil).errorDescription,
                       "GitHub is limiting requests from this network. Try again later.")

        let reset = Date(timeIntervalSinceNow: 15 * 60)
        let message = try XCTUnwrap(GitHubReleaseClient.ClientError.rateLimited(resetsAt: reset).errorDescription)
        XCTAssertTrue(message.hasPrefix("GitHub is limiting requests from this network. Try again after "),
                      message)
        XCTAssertFalse(message.contains("later"), message)
    }
}
