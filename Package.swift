// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mac-cleaner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mac-cleaner", targets: ["MacCleanerCLI"]),
        .library(name: "MacCleanerCore", targets: ["MacCleanerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "MacCleanerCore",
            dependencies: []
        ),
        .executableTarget(
            name: "MacCleanerCLI",
            dependencies: [
                "MacCleanerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "MacCleanerBenchmarks",
            dependencies: ["MacCleanerCore"],
            path: "Benchmarks/MacCleanerBenchmarks"
        ),
        .testTarget(
            name: "MacCleanerTests",
            dependencies: ["MacCleanerCore"],
            path: "Tests/MacCleanerTests"
        ),
    ]
)
