// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PeakmonCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PeakmonCore", targets: ["PeakmonCore"]),
    ],
    targets: [
        .target(name: "PeakmonCore"),
        .testTarget(name: "PeakmonCoreTests", dependencies: ["PeakmonCore"]),
    ],
)
