// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CCCXUsageMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CCCXUsageMonitor",
            path: "Sources/CCCXUsageMonitor"
        )
    ]
)
