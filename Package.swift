// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UniversalTunnelManager",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TunnelUI"),
        .executableTarget(name: "UniversalTunnelManager", dependencies: ["TunnelUI"],
                          path: "Sources", exclude: ["TunnelUI"])
    ]
)
