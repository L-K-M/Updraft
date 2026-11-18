import XCTest
@testable import UpdraftCore

/// Asset-selection table built from the real release asset names recorded in
/// the updater ledger (section 3.2), plus the foreign-OS and unknown-extension
/// cases the shared rules must refuse. On Linux the platform tokens mirror the
/// macOS ones, so `.dmg`/`.pkg` and macOS-named assets are refused there; tests
/// that need several container formats use the OS-neutral `.zip`.
final class AssetSelectionTests: XCTestCase {

    private func release(_ assetNames: [String]) throws -> GitHubRelease {
        let assets = assetNames.map { name in
            "{ \"name\": \"\(name)\", \"content_type\": \"application/octet-stream\", "
                + "\"size\": 1, \"browser_download_url\": \"https://example.com/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)\" }"
        }.joined(separator: ", ")
        let document = Data("""
            { "tag_name": "v1.0.0", "html_url": "https://example.com",
              "prerelease": false, "draft": false, "assets": [\(assets)] }
            """.utf8)
        return try JSONDecoder().decode(GitHubRelease.self, from: document)
    }

    private var hostIsAppleSilicon: Bool { AssetSelection.isAppleSiliconHost }

    // MARK: Real release layouts (ledger 3.2)

    #if os(macOS)
    func testUniversalDiskImageBeatsUniversalZip() throws {
        // The Zap/Jetty/Invoque/TopDrawer/Vervellum/Wrapybara/Gans/RepoMen layout.
        let release = try release(["App-1.0-macos-universal.zip",
                                   "App-1.0-macos-universal.dmg"])
        XCTAssertEqual(release.preferredAsset?.name, "App-1.0-macos-universal.dmg")
    }

    func testSplitArchReleasePicksTheHostArchitecture() throws {
        // Lucerne's layout: one disk image per architecture plus a universal one.
        let release = try release([
            "Lucerne-1.0-macos-x86_64.dmg",
            "Lucerne-1.0-macos-universal.dmg",
            "Lucerne-1.0-macos-arm64.dmg",
            "Lucerne-1.0-macos-x86_64.zip",
            "Lucerne-1.0-macos-arm64.zip",
        ])
        let expected = hostIsAppleSilicon
            ? "Lucerne-1.0-macos-arm64.dmg"
            : "Lucerne-1.0-macos-x86_64.dmg"
        XCTAssertEqual(release.preferredAsset?.name, expected)
    }

    func testSplitArchReleaseFallsBackToUniversal() throws {
        let release = try release([
            "Lucerne-1.0-macos-x86_64.dmg",
            "Lucerne-1.0-macos-universal.dmg",
        ])
        // On Apple Silicon the x86_64 build runs under Rosetta 2, so the
        // explicitly native tier is empty and the universal build wins; on
        // Intel the x86_64 build is native.
        let expected = hostIsAppleSilicon
            ? "Lucerne-1.0-macos-universal.dmg"
            : "Lucerne-1.0-macos-x86_64.dmg"
        XCTAssertEqual(release.preferredAsset?.name, expected)
    }
    #endif

    #if os(Linux)
    func testMacOSNamedReleaseIsNotOfferedOnLinux() throws {
        // The mirror image of the macOS rule: these assets all name macOS.
        let release = try release([
            "App-1.0-macos-universal.zip",
            "Lucerne-1.0-macos-arm64.dmg",
            "Lucerne-1.0-macos-x86_64.zip",
        ])
        XCTAssertNil(release.preferredAsset)
    }

    func testLinuxMirrorPicksTheHostArchitecture() throws {
        let release = try release([
            "App-1.0-x86_64.zip",
            "App-1.0-universal.zip",
            "App-1.0-arm64.zip",
        ])
        let expected = hostIsAppleSilicon ? "App-1.0-arm64.zip" : "App-1.0-x86_64.zip"
        XCTAssertEqual(release.preferredAsset?.name, expected)
    }

    func testLinuxMirrorRefusesDiskImageAndPkg() throws {
        let release = try release(["App-1.0-linux-amd64.zip", "App-1.0-linux-amd64.dmg"])
        XCTAssertEqual(release.preferredAsset?.name, "App-1.0-linux-amd64.zip")
    }
    #endif

    func testLinuxOnlyReleaseIsNotOfferedOnMacOS() throws {
        #if os(macOS)
        let release = try release(["vervellum_1.0_arm64.deb", "vervellum_1.0_amd64.deb"])
        XCTAssertNil(release.preferredAsset, "a .deb is never offered on macOS")
        #endif
    }

    // MARK: Refusals

    func testUnknownExtensionIsNotOffered() throws {
        let release = try release(["notes.txt", "App.tar.gz", "App"])
        XCTAssertNil(release.preferredAsset)
    }

    func testForeignOperatingSystemAssetsAreNeverOffered() throws {
        #if os(macOS)
        let foreign = ["App-linux.dmg", "App-windows.zip", "App-ubuntu.pkg",
                       "App-debian.dmg", "App-flatpak.zip", "App.AppImage.dmg",
                       "App-win64.zip"]
        #elseif os(Linux)
        let foreign = ["App-macos.dmg", "App-osx.zip", "App-darwin.pkg",
                       "App-win64.zip", "App-windows.dmg"]
        #else
        let foreign: [String] = []
        #endif
        for name in foreign {
            let release = try release([name])
            XCTAssertNil(release.preferredAsset, "\(name) must not be offered")
        }
    }

    func testForeignArchitectureIsDroppedOnIntel() throws {
        #if arch(x86_64)
        // Under Rosetta the host counts as Apple Silicon, so only assert the
        // Intel behaviour on a non-translated run.
        try XCTSkipIf(hostIsAppleSilicon, "x86_64 test slice is running under Rosetta")
        let release = try release(["App-arm64.zip"])
        XCTAssertNil(release.preferredAsset, "arm64 cannot run on Intel")
        #endif
    }

    // MARK: Architecture tiers (OS-neutral .zip)

    func testNativeArchitectureBeatsUniversalAndOther() throws {
        let release = try release(["App-x86_64.zip", "App-universal.zip", "App-arm64.zip"])
        if hostIsAppleSilicon {
            XCTAssertEqual(release.preferredAsset?.name, "App-arm64.zip")
        } else {
            XCTAssertEqual(release.preferredAsset?.name, "App-x86_64.zip")
        }
    }

    func testUniversalBeatsForeignArchitecture() throws {
        let release = try release(["App-x86_64.zip", "App-universal.zip"])
        if hostIsAppleSilicon {
            XCTAssertEqual(release.preferredAsset?.name, "App-universal.zip")
        } else {
            XCTAssertEqual(release.preferredAsset?.name, "App-x86_64.zip")
        }
    }

    func testUnlabelledBuildBeatsForeignArchitecture() throws {
        let release = try release(["App-x86_64.zip", "App.zip"])
        if hostIsAppleSilicon {
            XCTAssertEqual(release.preferredAsset?.name, "App.zip")
        } else {
            XCTAssertEqual(release.preferredAsset?.name, "App-x86_64.zip")
        }
    }

    #if os(macOS)
    func testRunnabilityDominatesExtension() throws {
        // A foreign-architecture disk image loses to a native zip: there is no
        // Rosetta for arm64 on Intel.
        let release = try release(["App-x86_64.dmg", "App-arm64.zip"])
        if hostIsAppleSilicon {
            XCTAssertEqual(release.preferredAsset?.name, "App-arm64.zip")
        } else {
            XCTAssertEqual(release.preferredAsset?.name, "App-x86_64.dmg")
        }
    }

    func testExtensionOrderBreaksSameTierTies() throws {
        let release = try release(["App.zip", "App.pkg", "App.dmg"])
        XCTAssertEqual(release.preferredAsset?.name, "App.dmg")
    }
    #endif

    func testAppleSiliconAndAmd64TokensMatch() throws {
        #if arch(arm64)
        if hostIsAppleSilicon {
            let release = try release(["App-Apple-Silicon.zip", "App-x86_64.zip"])
            XCTAssertEqual(release.preferredAsset?.name, "App-Apple-Silicon.zip")
        }
        #elseif arch(x86_64)
        if !hostIsAppleSilicon {
            let release = try release(["App-amd64.zip", "App-arm64.zip"])
            XCTAssertEqual(release.preferredAsset?.name, "App-amd64.zip")
        }
        #endif
    }

    func testArchHintsMatchWholeTokensOnly() throws {
        // "intel" is inside "Intelligent" and "x64" inside "x6400"; neither
        // names an architecture, so the first uploaded build wins the tie.
        let release = try release(["App-x6400.zip", "IntelligentApp.zip"])
        XCTAssertEqual(release.preferredAsset?.name, "App-x6400.zip")
    }

    // MARK: Order

    func testUploadOrderBreaksTies() throws {
        let release = try release(["App-one.zip", "App-two.zip"])
        XCTAssertEqual(release.preferredAsset?.name, "App-one.zip")
    }

    func testCustomExtensionList() throws {
        let release = try release(["App.zip", "App.pkg"])
        #if os(macOS)
        XCTAssertEqual(
            release.preferredAsset(using: AssetSelection(extensions: ["pkg", "zip"]))?.name,
            "App.pkg")
        #else
        // On Linux a `.pkg` names macOS and is refused.
        XCTAssertEqual(
            release.preferredAsset(using: AssetSelection(extensions: ["pkg", "zip"]))?.name,
            "App.zip")
        #endif
        XCTAssertNil(release.preferredAsset(using: AssetSelection(extensions: ["deb"])))
    }

    // MARK: Token helper

    func testTokensSplitAtNonAlphanumerics() {
        XCTAssertEqual(AssetSelection.tokens(in: "App-x86_64.dmg"), ["app", "x86", "64", "dmg"])
        XCTAssertEqual(AssetSelection.tokens(in: "App Apple Silicon.zip"),
                       ["app", "apple", "silicon", "zip"])
        XCTAssertEqual(AssetSelection.tokens(in: ""), [])
    }
}
