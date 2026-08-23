// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "netmax-desktop",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "netmax-desktop",
            path: "Sources/netmax-desktop"
        )
    ]
)
