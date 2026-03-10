// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RailwayHUD",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RailwayHUD",
            path: "Sources/RailwayHUD"
        )
    ]
)
