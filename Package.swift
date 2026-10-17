// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "keywatch",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "keywatch", path: "Sources/keywatch")
    ]
)
