// swift-tools-version: 6.1
// EditorKit — the annotation flatten path, redaction bake, and OCR pre-scan.
// The flatten path is the security-critical core (redaction destroyed into the
// pixels before anything is exported or sent to Claude); it is UI-free and
// runs headless under `swift test`. The editor UI lives in the app target.
import PackageDescription

let package = Package(
    name: "EditorKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EditorKit", targets: ["EditorKit"])
    ],
    dependencies: [
        .package(path: "../ShotModel")
    ],
    targets: [
        .target(name: "EditorKit", dependencies: ["ShotModel"]),
        .testTarget(name: "EditorKitTests", dependencies: ["EditorKit"]),
    ]
)
