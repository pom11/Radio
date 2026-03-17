// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Radio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Radio",
            path: "Sources",
            resources: [
                .process("Assets.xcassets")
            ]
        )
    ]
)
