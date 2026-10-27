// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Satsuma",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Satsuma", path: "Sources/Satsuma")
    ]
)
