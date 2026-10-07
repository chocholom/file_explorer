// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FileExplorer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FileExplorer",
            path: "Sources/FileExplorer"
        ),
        .testTarget(
            name: "FileExplorerTests",
            dependencies: ["FileExplorer"],
            path: "Tests/FileExplorerTests"
        ),
    ]
)
