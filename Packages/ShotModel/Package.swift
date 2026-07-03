// swift-tools-version: 6.1
// ShotModel — the on-disk project model shared contract with the Windows app.
// Keep this target UI-free (Foundation only) so `swift test` runs it headless.
import PackageDescription

let package = Package(
    name: "ShotModel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ShotModel", targets: ["ShotModel"])
    ],
    targets: [
        .target(name: "ShotModel"),
        .testTarget(name: "ShotModelTests", dependencies: ["ShotModel"]),
    ]
)
