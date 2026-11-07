// swift-tools-version:5.9
// Sample macOS project used to verify development inside claude-mac-sandbox.
import PackageDescription

let package = Package(
    name: "HelloMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "hello", targets: ["hello"]),
        .library(name: "HelloCore", targets: ["HelloCore"]),
    ],
    targets: [
        .target(name: "HelloCore"),
        .executableTarget(name: "hello", dependencies: ["HelloCore"]),
        .testTarget(name: "HelloCoreTests", dependencies: ["HelloCore"]),
    ]
)
