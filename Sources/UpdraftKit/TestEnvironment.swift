import Foundation

/// Whether the process is running under XCTest. One definition for the whole
/// package: `start()` is a no-op and alerts never run modally during tests.
enum TestEnvironment {
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
