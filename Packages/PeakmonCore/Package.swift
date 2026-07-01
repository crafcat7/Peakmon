// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PeakmonCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PeakmonCore", targets: ["PeakmonCore"]),
    ],
    targets: [
        .target(
            name: "PeakmonCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ],
        ),
        .testTarget(name: "PeakmonCoreTests", dependencies: ["PeakmonCore"]),
    ],
)
