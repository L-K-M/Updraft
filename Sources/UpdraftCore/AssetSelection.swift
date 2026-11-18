import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Chooses which asset of a GitHub release this machine should download.
///
/// The rules, in order:
/// 1. Only assets whose lowercased extension is in `extensions` are candidates —
///    an unknown or `.deb` file is never offered on macOS.
/// 2. Assets whose name names another operating system are dropped.
/// 3. Architecture tier: a name hinting at the host architecture ranks first,
///    then a universal or unlabelled build, then the other architecture. On
///    Intel an asset that names only arm64 cannot run (there is no Rosetta for
///    it) and is dropped; on Apple Silicon an x86_64 build still runs under
///    Rosetta 2, so it stays as the last resort.
/// 4. Extension order (`extensions` order).
/// 5. The release's own upload order.
public struct AssetSelection: Sendable {

    /// Container extensions offered to the user, most preferred first.
    public let extensions: [String]

    /// The shared default: disk image, then zip, then pkg.
    public static let `default` = AssetSelection()

    public init(extensions: [String] = ["dmg", "zip", "pkg"]) {
        self.extensions = extensions.map { $0.lowercased() }
    }

    public func preferredAsset(in release: GitHubRelease) -> GitHubRelease.Asset? {
        let candidates = release.assets.enumerated().filter { _, asset in
            guard let ext = Self.pathExtension(of: asset.name) else { return false }
            return extensions.contains(ext)
        }
        // Runnability dominates the container format: an archive for another OS
        // can never be installed here, whatever its extension.
        let runnable = candidates.filter { !Self.namesOtherOperatingSystem($0.element.name) }
        guard !runnable.isEmpty else { return nil }

        // Rosetta 2 runs x86_64 on Apple Silicon, so the foreign-architecture
        // tier is a last resort there. On Intel there is no Rosetta for arm64.
        let keepOtherArchitecture = Self.isAppleSiliconHost
        var best: (offset: Int, element: GitHubRelease.Asset)?
        var bestTier = Int.max
        var bestExtensionRank = Int.max
        for (offset, asset) in runnable {
            let tier = Self.architectureTier(for: asset)
            if tier == 2 && !keepOtherArchitecture { continue }
            let extensionRank = extensionRank(of: asset.name)
            let isBetter = tier < bestTier
                || (tier == bestTier && extensionRank < bestExtensionRank)
                || (tier == bestTier && extensionRank == bestExtensionRank
                    && offset < (best?.offset ?? Int.max))
            if isBetter {
                best = (offset, asset)
                bestTier = tier
                bestExtensionRank = extensionRank
            }
        }
        return best?.element
    }

    // MARK: Host

    /// Whether the host is Apple Silicon. A binary compiled for x86_64 but
    /// translated by Rosetta 2 runs on Apple Silicon hardware, where arm64 is
    /// what is actually native — detect translation at runtime and pick hints
    /// for the machine, not the binary.
    static var isAppleSiliconHost: Bool {
        #if arch(arm64)
        return true
        #elseif arch(x86_64)
        #if canImport(Darwin)
        var procTranslated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &procTranslated, &size, nil, 0) == 0 else { return false }
        return procTranslated == 1
        #else
        return false
        #endif
        #else
        return false
        #endif
    }

    private static let nativeArchitectureHints: [String] = isAppleSiliconHost
        ? ["arm64", "aarch64", "apple-silicon"]
        : ["x86_64", "x64", "amd64", "intel"]

    private static let foreignArchitectureHints: [String] = isAppleSiliconHost
        ? ["x86_64", "x64", "amd64", "intel"]
        : ["arm64", "aarch64", "apple-silicon"]

    /// Tokens that name another operating system. A leading `.` marks a file
    /// extension, which only matches at the end of the name; every other token
    /// matches anywhere in the lowercased name.
    private static let otherOperatingSystemTokens: [String] = {
        #if os(macOS)
        return ["linux", "ubuntu", "debian", "flatpak", "appimage",
                "windows", "win32", "win64", ".deb", ".rpm", ".exe", ".msi"]
        #elseif os(Linux)
        return ["mac", "macos", "osx", "darwin",
                "windows", "win32", "win64", ".dmg", ".pkg", ".exe", ".msi"]
        #else
        // Unknown platforms recognise no tokens either way; only the generic
        // architecture scoring below applies.
        return []
        #endif
    }()

    // MARK: Matching

    private static func architectureTier(for asset: GitHubRelease.Asset) -> Int {
        let tokens = tokens(in: asset.name)
        if nativeArchitectureHints.contains(where: { tokensContain(tokens, hint: $0) }) { return 0 }
        if tokens.contains("universal") { return 1 }
        if foreignArchitectureHints.contains(where: { tokensContain(tokens, hint: $0) }) { return 2 }
        return 1
    }

    private static func namesOtherOperatingSystem(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return otherOperatingSystemTokens.contains { token in
            token.hasPrefix(".") ? lowered.hasSuffix(token) : lowered.contains(token)
        }
    }

    private static func pathExtension(of name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    private func extensionRank(of name: String) -> Int {
        guard let ext = Self.pathExtension(of: name) else { return extensions.count }
        return extensions.firstIndex(of: ext) ?? extensions.count
    }

    /// Lowercase alphanumeric tokens of an asset name — "App-x64.dmg" →
    /// ["app", "x64", "dmg"] — so hints match whole words: "intel" fires on
    /// "App-intel.dmg" but not "IntelligentApp.dmg", and "x64" not on "x6400".
    static func tokens(in name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Whether the tokenized hint appears as a contiguous run in the tokenized
    /// name — "x86_64" (tokens "x86", "64") matches "App-x86_64.dmg" but
    /// neither "x86" nor "64" alone promotes a build.
    private static func tokensContain(_ tokenList: [String], hint: String) -> Bool {
        let parts = tokens(in: hint)
        guard !parts.isEmpty else { return false }
        return tokenList.indices.contains { start in
            start + parts.count <= tokenList.count
                && tokenList[start..<(start + parts.count)].elementsEqual(parts)
        }
    }
}
