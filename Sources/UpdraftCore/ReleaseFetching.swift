import Foundation

/// The one network call the update checker needs — seams the release fetch so
/// tests and previews can supply a release without touching the network.
public protocol ReleaseFetching: Sendable {
    func latestRelease(includePrereleases: Bool) async throws -> GitHubRelease
}
