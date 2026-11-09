// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FakturaCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "FakturaCore", targets: ["FakturaCore"])],
    targets: [
        .target(name: "FakturaCore"),
        .testTarget(name: "FakturaCoreTests", dependencies: ["FakturaCore"]),
    ]
)
