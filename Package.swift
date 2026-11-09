// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Faktura",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "Packages/FakturaCore")],
    targets: [
        .executableTarget(name: "Faktura", dependencies: ["FakturaCore"], path: "Faktura", resources: [.process("Resources")]),
        .testTarget(name: "FakturaAppTests", dependencies: ["Faktura"], path: "Tests/FakturaAppTests")
    ]
)
