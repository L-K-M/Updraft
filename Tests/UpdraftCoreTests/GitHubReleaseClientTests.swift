import XCTest
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
