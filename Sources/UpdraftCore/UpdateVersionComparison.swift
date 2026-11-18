import Foundation

/// Pure classification of installed and release version strings for update checks.
///
/// Kept as a type so the failure paths are testable without presenting an alert:
/// an unparseable tag is `invalidRemote`, never a silent "up to date".
public enum UpdateVersionComparison: Equatable, Sendable {
    case updateAvailable(remote: SemanticVersion, current: SemanticVersion)
    case upToDate
    case invalidCurrent(String)
    case invalidRemote(String)

    public static func evaluate(remote remoteValue: String, current currentValue: String) -> Self {
        guard let current = SemanticVersion(currentValue) else {
            return .invalidCurrent(currentValue)
        }
        guard let remote = SemanticVersion(remoteValue) else {
            return .invalidRemote(remoteValue)
        }
        return remote > current ? .updateAvailable(remote: remote, current: current) : .upToDate
    }
}
