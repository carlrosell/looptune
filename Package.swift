// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LoopTune",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LoopTuneKit", targets: ["LoopTuneKit"]),
        .executable(name: "looptune", targets: ["LoopTuneCLI"]),
        .executable(name: "LoopTuneApp", targets: ["LoopTuneApp"]),
    ],
    dependencies: [
        // The actual production Loop algorithm, extracted by LoopKit as a standalone package.
        // Pinned by revision because the repository publishes no version tags.
        .package(
            url: "https://github.com/LoopKit/LoopAlgorithm.git",
            revision: "2f5c630084aa0d72b8d14999e1e0f7c836b0c341"
        ),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "LoopTuneKit",
            dependencies: [
                .product(name: "LoopAlgorithm", package: "LoopAlgorithm")
            ]
        ),
        .executableTarget(
            name: "LoopTuneCLI",
            dependencies: [
                "LoopTuneKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "LoopTuneApp",
            dependencies: ["LoopTuneKit"]
        ),
        .testTarget(
            name: "LoopTuneKitTests",
            dependencies: ["LoopTuneKit"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "LoopTuneAppTests",
            dependencies: ["LoopTuneApp"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
