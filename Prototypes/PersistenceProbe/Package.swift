// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersistenceProbe",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PersistenceProbe", targets: ["PersistenceProbe"])],
    targets: [
        .target(name: "PersistenceProbe"),
        .testTarget(name: "PersistenceProbeTests", dependencies: ["PersistenceProbe"])
    ]
)
