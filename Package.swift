// swift-tools-version:5.9
import PackageDescription

let coreProducts: [Product] = [
    .library(name: "UpdraftCore", targets: ["UpdraftCore"]),
]

let coreTargets: [Target] = [
    .target(name: "UpdraftCore"),
    .testTarget(name: "UpdraftCoreTests", dependencies: ["UpdraftCore"]),
]

// UpdraftKit needs AppKit and exists only where AppKit does. On Linux the
// package still builds and tests the Foundation-only core.
#if os(macOS)
let kitProducts: [Product] = [
    .library(name: "UpdraftKit", targets: ["UpdraftKit"]),
]

let kitTargets: [Target] = [
    .target(name: "UpdraftKit", dependencies: ["UpdraftCore"]),
    .testTarget(name: "UpdraftKitTests", dependencies: ["UpdraftKit", "UpdraftCore"]),
]
#else
let kitProducts: [Product] = []
let kitTargets: [Target] = []
#endif

let package = Package(
    name: "Updraft",
    platforms: [.macOS(.v13)],
    products: coreProducts + kitProducts,
    targets: coreTargets + kitTargets
)
