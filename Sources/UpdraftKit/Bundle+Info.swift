import Foundation

public extension Bundle {
    /// `CFBundleShortVersionString` (the marketing version), or `"0"`.
    var shortVersionString: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// The app's display name, falling back to the bundle name then the process name.
    var appDisplayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }
}
