// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MTPKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MTPKit", targets: ["MTPKit"]),
        .library(name: "TetherCore", targets: ["TetherCore"]),
    ],
    targets: [
        .target(name: "MTPKit", resources: [.process("Resources")]),
        .target(name: "TetherCore", dependencies: ["MTPKit"], resources: [.process("Resources")]),
        .testTarget(name: "MTPKitTests", dependencies: ["MTPKit"]),
        .testTarget(name: "TetherCoreTests", dependencies: ["TetherCore", "MTPKit"]),
    ]
)
