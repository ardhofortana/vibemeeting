// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VibeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VibeCore", targets: ["VibeCore"]),
        .executable(name: "vibe-latency", targets: ["vibe-latency"]),
    ],
    targets: [
        .target(name: "VibeCore"),
        .executableTarget(name: "vibe-latency", dependencies: ["VibeCore"]),
        .testTarget(name: "VibeCoreTests", dependencies: ["VibeCore"]),
    ]
)
