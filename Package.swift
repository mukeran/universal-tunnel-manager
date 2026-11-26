// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MobileTunnelManager",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "MobileTunnelManager")]
)
