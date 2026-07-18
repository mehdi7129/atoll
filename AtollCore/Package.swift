// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AtollCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AtollCore", targets: ["AtollCore"])
    ],
    targets: [
        .target(name: "AtollCore"),
        .testTarget(name: "AtollCoreTests", dependencies: ["AtollCore"])
    ]
)
