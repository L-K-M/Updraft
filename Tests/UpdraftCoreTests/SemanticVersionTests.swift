import XCTest
@testable import UpdraftCore

/// Ported from Zap, Jetty, Top Drawer, Gans, RepoMen and Lucerne. The shared
/// type uses Jetty's strict identifiers and overflow-safe SemVer §11 ordering,
/// so tests that asserted the old lax parsing or lexical pre-release order now
/// assert the strict/spec behaviour.
final class SemanticVersionTests: XCTestCase {

    // MARK: Parsing

    func testParsesAndStripsLeadingV() {
        XCTAssertEqual(SemanticVersion("v1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(SemanticVersion("1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(SemanticVersion("  V2.0  ")?.components, [2, 0])
    }

    func testParsesPrereleaseAndIgnoresBuildMetadata() {
        let version = SemanticVersion("1.4.0-beta.2+build.5")
        XCTAssertEqual(version?.components, [1, 4, 0])
        XCTAssertEqual(version?.prerelease, "beta.2")
    }

    func testRejectsGarbage() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("abc"))
        XCTAssertNil(SemanticVersion("1.x.3"))
        XCTAssertNil(SemanticVersion("v"))
        XCTAssertNil(SemanticVersion("latest"))
    }

    func testZeroIsTheNeutralVersion() {
        XCTAssertEqual(SemanticVersion.zero.components, [0])
        XCTAssertNil(SemanticVersion.zero.prerelease)
    }

    // MARK: Strict identifiers (Jetty)

    func testRejectsLeadingZerosInReleaseComponents() {
        XCTAssertNil(SemanticVersion("01.2.3"))
        XCTAssertNil(SemanticVersion("1.02.3"))
        XCTAssertNil(SemanticVersion("1.2.03"))
    }

    func testRejectsLeadingZerosInNumericPrereleaseIdentifiers() {
        XCTAssertNil(SemanticVersion("1.0.0-01"))
        XCTAssertNil(SemanticVersion("1.0.0-alpha.01"))
    }

    func testAcceptsSingleZeroAndAlphanumericPrereleaseIdentifiers() {
        XCTAssertNotNil(SemanticVersion("0.1.0"))
        XCTAssertNotNil(SemanticVersion("1.0.0-0"))
        XCTAssertNotNil(SemanticVersion("1.0.0-alpha01"))
    }

    func testRejectsEmptyPrereleaseIdentifiers() {
        XCTAssertNil(SemanticVersion("1.0.0-"))
        XCTAssertNil(SemanticVersion("1.0.0-alpha..1"))
    }

    func testRejectsInvalidPrereleaseCharacters() {
        // The old copies accepted these; strict SemVer does not.
        XCTAssertNil(SemanticVersion("1.0.0-alpha_1"))
        XCTAssertNil(SemanticVersion("1.0.0-alpha beta"))
        XCTAssertNil(SemanticVersion("1.0.0-١"))
    }

    // MARK: Numeric components

    func testComparisonIsNumericNotLexical() {
        XCTAssertTrue(SemanticVersion("1.10.0")! > SemanticVersion("1.9.0")!)   // 10 > 9
        XCTAssertTrue(SemanticVersion("2.0.0")! > SemanticVersion("1.999.0")!)
        XCTAssertLessThan(SemanticVersion("0.9.0")!, SemanticVersion("0.10.0")!)
    }

    func testZeroPaddingEquivalence() {
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion("1.2.0"))
        XCTAssertFalse(SemanticVersion("1.2")! < SemanticVersion("1.2.0")!)
        XCTAssertFalse(SemanticVersion("1.2.0")! < SemanticVersion("1.2")!)
    }

    // MARK: Pre-release ordering (SemVer §11)

    func testPrereleaseSortsBelowFinal() {
        XCTAssertTrue(SemanticVersion("1.2.0-beta.1")! < SemanticVersion("1.2.0")!)
        XCTAssertTrue(SemanticVersion("1.2.0")! > SemanticVersion("1.2.0-rc.1")!)
        XCTAssertTrue(SemanticVersion("1.2.0-beta")! > SemanticVersion("1.1.9")!)   // numbers win first
    }

    func testPrereleaseUsesSemVerIdentifierOrdering() {
        // The old lexical comparison sorted "beta.10" below "beta.9".
        XCTAssertTrue(SemanticVersion("1.2.0-beta.2")! < SemanticVersion("1.2.0-beta.10")!)
        XCTAssertTrue(SemanticVersion("1.2.0-1")! < SemanticVersion("1.2.0-alpha")!)
        XCTAssertTrue(SemanticVersion("1.2.0-alpha")! < SemanticVersion("1.2.0-alpha.1")!)
        XCTAssertTrue(SemanticVersion("1.2.0-alpha.1")! < SemanticVersion("1.2.0-alpha.beta")!)
    }

    func testPrereleaseMixedIdentifiersKeepStrictOrdering() {
        let beta2 = SemanticVersion("1.0.0-beta.2")!
        let beta10 = SemanticVersion("1.0.0-beta.10")!
        let beta1a = SemanticVersion("1.0.0-beta.1a")!
        XCTAssertTrue(beta2 < beta10)   // numeric < numeric
        XCTAssertTrue(beta2 < beta1a)   // numeric < alphanumeric
        XCTAssertTrue(beta10 < beta1a)
        // A hyphen-led identifier is alphanumeric — still outranks numeric.
        XCTAssertTrue(SemanticVersion("1.0.0-beta.1")! < SemanticVersion("1.0.0-beta.-rc")!)
        XCTAssertTrue(SemanticVersion("1.0.0-beta")! < SemanticVersion("1.0.0-beta.1")!)
    }

    func testPrereleaseOverflowLengthNumericsOrderByMagnitude() {
        // No fixed-width integer parse: huge identifiers still order numerically,
        // so the comparison stays a strict weak order.
        let huge = SemanticVersion("1.0.0-a.20000000000000000000")!
        XCTAssertTrue(SemanticVersion("1.0.0-a.3")! < SemanticVersion("1.0.0-a.19")!)
        XCTAssertTrue(SemanticVersion("1.0.0-a.19")! < huge)
        XCTAssertFalse(huge < SemanticVersion("1.0.0-a.3")!)
        XCTAssertTrue(SemanticVersion("1.0.0-a.10000000000000000000")! < huge)
        let smaller = SemanticVersion("1.0.0-9223372036854775808")!
        let larger = SemanticVersion("1.0.0-10000000000000000000")!
        XCTAssertLessThan(smaller, larger)
    }

    func testSemverSpecExampleChain() {
        // 1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta
        //   < 1.0.0-beta.2 < 1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0
        let chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                     "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
            .compactMap(SemanticVersion.init)
        XCTAssertEqual(chain.count, 8)
        for (lower, higher) in zip(chain, chain.dropFirst()) {
            XCTAssertLessThan(lower, higher, "\(lower) should sort below \(higher)")
        }
    }

    func testEqualPrereleasesAreEqual() {
        XCTAssertEqual(SemanticVersion("1.0.0-beta.2"), SemanticVersion("v1.0.0-beta.2"))
        XCTAssertFalse(SemanticVersion("1.0.0-beta.2")! < SemanticVersion("1.0.0-beta.2")!)
    }

    func testNewerThanCurrentDetection() {
        let current = SemanticVersion("1.0")!
        XCTAssertTrue(SemanticVersion("1.0.1")! > current)
        XCTAssertTrue(SemanticVersion("1.1")! > current)
        XCTAssertFalse(SemanticVersion("1.0")! > current)
        XCTAssertFalse(SemanticVersion("0.9")! > current)
    }

    func testDescriptionIsTheOriginalString() {
        XCTAssertEqual(SemanticVersion("v1.2.3")?.description, "v1.2.3")
        XCTAssertEqual(SemanticVersion(" 1.2.3 ")?.description, "1.2.3")
    }
}
