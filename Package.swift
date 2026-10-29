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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "SparkBarCore",
            path: "Sources/SparkBarCore"
        ),
        .executableTarget(
            name: "SparkBar",
            dependencies: ["SparkBarCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/SparkBar",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
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
        ),
        .testTarget(
            name: "SparkBarAppTests",
            dependencies: ["SparkBar", "SparkBarCore"],
            path: "Tests/SparkBarAppTests",
            linkerSettings: [
                // SwiftPM can put binary frameworks beside the .xctest bundle
                // instead of in PackageFrameworks. Anchor to the test image,
                // not the external xctest host or a machine-specific build path.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])
            ]
        )
    ]
)
