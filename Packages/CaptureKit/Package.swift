// swift-tools-version: 6.1
// CaptureKit — the recording engine: global click tap, hotkey, ScreenCaptureKit
// grabs, region/window resolution, AX element-at-point, auto-captions, and the
// TCC permissions surface. Hardware-facing pieces sit behind protocols so the
// pipeline logic stays unit-testable headless (see CaptureKitTests).
import PackageDescription

let package = Package(
    name: "CaptureKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CaptureKit", targets: ["CaptureKit"])
    ],
    dependencies: [
        .package(path: "../ShotModel")
    ],
    targets: [
        .target(name: "CaptureKit", dependencies: ["ShotModel"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
    ]
)
