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
        ),
        // M9/QA: wraps the in-source `runAll()` harnesses (no XCTest rewrite).
        .testTarget(
            name: "netmax-desktopTests",
            dependencies: ["netmax-desktop"],
            path: "Tests/netmax-desktopTests"
        )
    ]
)
