import XCTest
@testable import UpdraftCore

/// Ported from Zap, Jetty, Invoque and Top Drawer. The shared model adopts
/// Invoque's self-contained date decoding and release-notes bound, Lucerne's
/// `digest`, and the strict asset selection rules; where a ported test asserted
/// the old "fall back to the first asset" rule it now asserts the replacement.
final class GitHubReleaseTests: XCTestCase {

    private func decode(_ json: String) throws -> GitHubRelease {
        // A default-configured decoder on purpose: GitHubRelease parses
        // `published_at` itself, so correctness can't depend on decoder
        // configuration at the call site.
        try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    func testDecodesLatestReleasePayload() throws {
        let release = try decode("""
        {
          "tag_name": "v1.3.0",
          "name": "App 1.3.0",
          "body": "- Fixed a thing\\n- Added another",
          "html_url": "https://github.com/L-K-M/App/releases/tag/v1.3.0",
          "prerelease": false,
          "draft": false,
          "published_at": "2026-05-01T12:00:00Z",
          "assets": [
            {
              "name": "App.dmg",
              "content_type": "application/x-apple-diskimage",
              "size": 1048576,
              "browser_download_url": "https://github.com/L-K-M/App/releases/download/v1.3.0/App.dmg",
              "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            }
          ]
        }
        """)

        XCTAssertEqual(release.tagName, "v1.3.0")
        XCTAssertEqual(SemanticVersion(release.tagName), SemanticVersion("1.3.0"))
        XCTAssertFalse(release.prerelease)
        XCTAssertEqual(release.htmlURL.absoluteString,
                       "https://github.com/L-K-M/App/releases/tag/v1.3.0")
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets.first?.name, "App.dmg")
        XCTAssertEqual(release.assets.first?.contentType, "application/x-apple-diskimage")
        XCTAssertEqual(release.assets.first?.size, 1048576)
        XCTAssertEqual(release.assets.first?.browserDownloadURL.lastPathComponent, "App.dmg")
        XCTAssertEqual(release.assets.first?.digest,
                       "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        XCTAssertNotNil(release.publishedAt)
    }

    func testDecodesWithMissingOptionalFields() throws {
        // body/name/published_at/digest absent, no assets — must still decode.
        let release = try decode("""
        {
          "tag_name": "2.0",
          "html_url": "https://github.com/L-K-M/App/releases/tag/2.0",
          "prerelease": true,
          "draft": false,
          "assets": []
        }
        """)
        XCTAssertEqual(release.tagName, "2.0")
        XCTAssertTrue(release.prerelease)
        XCTAssertNil(release.releaseNotes())
        XCTAssertTrue(release.assets.isEmpty)
        XCTAssertNil(release.assets.first?.digest)
    }

    func testDecodesFractionalSecondsPublishedAt() throws {
        // GitHub sometimes emits milliseconds — a fractional timestamp must
        // decode like a plain one, not silently drop `publishedAt`.
        let release = try decode("""
        { "tag_name": "1.0", "html_url": "https://e.com", "prerelease": false, "draft": false, "assets": [],
          "published_at": "2026-05-01T12:34:56.123Z" }
        """)
        let expected = ISO8601DateFormatter()
        expected.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(release.publishedAt,
                       expected.date(from: "2026-05-01T12:34:56.123Z"))
    }

    // MARK: Release notes

    func testReleaseNotesAreTrimmedAndCapped() throws {
        let long = String(repeating: "x", count: 1000)
        let release = try decode("""
        { "tag_name": "1.0", "html_url": "https://example.com", "prerelease": false, "draft": false, "assets": [], "body": "  \(long)  " }
        """)
        let notes = release.releaseNotes(maxLength: 100)
        XCTAssertEqual(notes?.first, "x")             // leading whitespace trimmed
        XCTAssertEqual(notes?.count, 100)             // maxLength bounds the result, "…" included
        XCTAssertEqual(notes?.last, "…")
    }

    func testReleaseNotesShortBodyIsNotTruncated() throws {
        let release = try decode("""
        { "tag_name": "1.0", "html_url": "https://example.com", "prerelease": false, "draft": false, "assets": [], "body": "  short  " }
        """)
        XCTAssertEqual(release.releaseNotes(maxLength: 10), "short")
        XCTAssertEqual(release.releaseNotes(maxLength: 1), nil)
    }

    // MARK: Asset selection

    func testPreferredAssetPrefersDiskImageThenZipThenPkg() throws {
        let release = try decode("""
        {
          "tag_name": "1.0", "html_url": "https://e.com", "prerelease": false, "draft": false,
          "assets": [
            {"name":"App.pkg","content_type":"application/vnd.apple.installer+xml","size":1,"browser_download_url":"https://e.com/App.pkg"},
            {"name":"App.zip","content_type":"application/zip","size":1,"browser_download_url":"https://e.com/App.zip"},
            {"name":"App.dmg","content_type":"application/x-apple-diskimage","size":1,"browser_download_url":"https://e.com/App.dmg"}
          ]
        }
        """)
        #if os(macOS)
        XCTAssertEqual(release.preferredAsset?.name, "App.dmg")
        #else
        // On Linux `.dmg`/`.pkg` name macOS and are refused, so the zip wins.
        XCTAssertEqual(release.preferredAsset?.name, "App.zip")
        #endif

        let withoutDMG = try decode("""
        {
          "tag_name": "1.0", "html_url": "https://e.com", "prerelease": false, "draft": false,
          "assets": [
            {"name":"App.pkg","content_type":"application/vnd.apple.installer+xml","size":1,"browser_download_url":"https://e.com/App.pkg"},
            {"name":"App.zip","content_type":"application/zip","size":1,"browser_download_url":"https://e.com/App.zip"}
          ]
        }
        """)
        XCTAssertEqual(withoutDMG.preferredAsset?.name, "App.zip")
    }

    func testPreferredAssetNeverFallsBackToAnUnknownType() throws {
        // Replaces Zap's `testPreferredAssetFallsBackToFirstWhenNoKnownType`:
        // the shared rule never offers an unknown or other-OS asset, so a
        // release with only `notes.txt` has no downloadable asset.
        let release = try decode("""
        {
          "tag_name": "1.0", "html_url": "https://e.com", "prerelease": false, "draft": false,
          "assets": [
            {"name":"notes.txt","content_type":"text/plain","size":1,"browser_download_url":"https://e.com/notes.txt"}
          ]
        }
        """)
        XCTAssertNil(release.preferredAsset)
    }

    func testPreferredAssetNilWhenNoAssets() throws {
        let release = try decode("""
        { "tag_name": "1.0", "html_url": "https://e.com", "prerelease": false, "draft": false, "assets": [] }
        """)
        XCTAssertNil(release.preferredAsset)
    }

    func testPreferredAssetUsesTheInjectedSelection() throws {
        let release = try decode("""
        {
          "tag_name": "1.0", "html_url": "https://e.com", "prerelease": false, "draft": false,
          "assets": [
            {"name":"App.dmg","content_type":"application/x-apple-diskimage","size":1,"browser_download_url":"https://e.com/App.dmg"},
            {"name":"App.zip","content_type":"application/zip","size":1,"browser_download_url":"https://e.com/App.zip"}
          ]
        }
        """)
        XCTAssertEqual(release.preferredAsset(using: AssetSelection(extensions: ["zip"]))?.name,
                       "App.zip")
        #if os(macOS)
        XCTAssertEqual(release.preferredAsset(using: .default)?.name, "App.dmg")
        #else
        XCTAssertEqual(release.preferredAsset(using: .default)?.name, "App.zip")
        #endif
    }
}
