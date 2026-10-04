// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Radio",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure, testable logic (QR deep-link building + QR image generation).
        // Lives separately from the executable so it can be unit-tested.
        .target(
            name: "RadioCore",
            path: "Sources/RadioCore"
        ),
        .executableTarget(
            name: "Radio",
            dependencies: ["RadioCore"],
            path: "Sources",
            exclude: ["RadioCore"],
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "RadioTests",
            dependencies: ["RadioCore"],
            path: "Tests/RadioTests"
        )
    ]
)
