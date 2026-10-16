// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MTPKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MTPKit", targets: ["MTPKit"]),
        .library(name: "TetherCore", targets: ["TetherCore"]),
        .library(name: "PhoneDetection", targets: ["PhoneDetection"]),
    ],
    targets: [
        .target(name: "MTPKit", resources: [.process("Resources")]),
        .target(name: "TetherCore", dependencies: ["MTPKit"], resources: [.process("Resources")]),
        .target(name: "PhoneDetection"),
        .testTarget(name: "PhoneDetectionTests", dependencies: ["PhoneDetection"]),
        .testTarget(name: "MTPKitTests", dependencies: ["MTPKit"]),
        .testTarget(name: "TetherCoreTests", dependencies: ["TetherCore", "MTPKit"]),
    ]
)
