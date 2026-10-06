// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "reel",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "reel", targets: ["reel"]),
        .library(name: "ReelCore", targets: ["ReelCore"]),
    ],
    targets: [
        .target(name: "ReelCore"),
        .executableTarget(name: "reel", dependencies: ["ReelCore"]),
    ],
    swiftLanguageModes: [.v5]
)
