// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MTPKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MTPKit", targets: ["MTPKit"]),
        .library(name: "TetherCore", targets: ["TetherCore"]),
    ],
    targets: [
        .target(name: "MTPKit"),
        .target(name: "TetherCore", dependencies: ["MTPKit"]),
        .testTarget(name: "MTPKitTests", dependencies: ["MTPKit"]),
        .testTarget(name: "TetherCoreTests", dependencies: ["TetherCore", "MTPKit"]),
    ]
)
