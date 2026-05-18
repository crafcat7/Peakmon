// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PeakmonUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PeakmonUI", targets: ["PeakmonUI"]),
    ],
    dependencies: [
        .package(path: "../PeakmonCore"),
    ],
    targets: [
        .target(
            name: "PeakmonUI",
            dependencies: ["PeakmonCore"],
        ),
        .testTarget(
            name: "PeakmonUITests",
            dependencies: ["PeakmonUI"],
        ),
    ],
)
