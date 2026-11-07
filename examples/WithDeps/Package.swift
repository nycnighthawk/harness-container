// swift-tools-version:5.9
// Sample project with a remote dependency: verifies SwiftPM fetching through
// the sandbox's allowlist proxy (--net restricted --allow dev).
import PackageDescription

let package = Package(
    name: "WithDeps",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "greet",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
    ]
)
