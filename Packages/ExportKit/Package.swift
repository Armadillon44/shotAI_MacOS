// swift-tools-version: 6.1
// ExportKit — renders a project into shareable documents (HTML / html-plain /
// Markdown / PDF / …). UI-free and headless-testable. Every shot image is read
// through ShotModel.resolveSendableRender (the fail-closed redaction gate), so an
// export can only ever embed a redaction/crop/marker-baked render, never a raw
// screenshot. Ported from shotAI-original/src/main/export*.ts.
import PackageDescription

let package = Package(
    name: "ExportKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExportKit", targets: ["ExportKit"])
    ],
    dependencies: [
        .package(path: "../ShotModel")
    ],
    targets: [
        .target(name: "ExportKit", dependencies: ["ShotModel"]),
        .testTarget(name: "ExportKitTests", dependencies: ["ExportKit"]),
    ]
)
