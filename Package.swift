// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Upbar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Upbar"),
        .testTarget(name: "UpbarTests", dependencies: ["Upbar"]),
    ]
)
