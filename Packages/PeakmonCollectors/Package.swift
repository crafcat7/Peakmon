// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PeakmonCollectors",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PeakmonCollectors", targets: ["PeakmonCollectors"]),
    ],
    dependencies: [
        .package(path: "../PeakmonCore"),
    ],
    targets: [
        .target(
            name: "PeakmonCollectors",
            dependencies: ["PeakmonCore"],
        ),
        .testTarget(
            name: "PeakmonCollectorsTests",
            dependencies: ["PeakmonCollectors"],
        ),
    ],
)
