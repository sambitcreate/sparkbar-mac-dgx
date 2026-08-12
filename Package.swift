// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SparkBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SparkBarCore", targets: ["SparkBarCore"]),
        .executable(name: "SparkBar", targets: ["SparkBar"]),
        .executable(name: "SparkBarSmoke", targets: ["SparkBarSmoke"])
    ],
    targets: [
        .target(
            name: "SparkBarCore",
            path: "Sources/SparkBarCore"
        ),
        .executableTarget(
            name: "SparkBar",
            dependencies: ["SparkBarCore"],
            path: "Sources/SparkBar"
        ),
        .executableTarget(
            name: "SparkBarSmoke",
            dependencies: ["SparkBarCore"],
            path: "Sources/SparkBarSmoke"
        ),
        .testTarget(
            name: "SparkBarCoreTests",
            dependencies: ["SparkBarCore"],
            path: "Tests/SparkBarCoreTests",
            resources: [.process("Fixtures")]
        )
    ]
)
