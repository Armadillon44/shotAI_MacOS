// swift-tools-version: 6.1
// SOPKit — the Claude SOP-generation client (Phase D). UI-free and
// headless-testable: a raw-URLSession Anthropic client (no official Swift SDK)
// pinned to api.anthropic.com, the system-prompt + request assembler (every step
// image routed through ShotModel.resolveSendableRender — the fail-closed
// redaction gate, so a screenshot with unbaked redaction is refused, never sent),
// the structured-output schema, streaming, cost estimate, and the Keychain-backed
// API-key store (the key lives only here — never surfaced to UI). Ported from
// shotAI-original/src/main/{claude-service,claude-models,secrets}.ts + sop.ts.
import PackageDescription

let package = Package(
    name: "SOPKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SOPKit", targets: ["SOPKit"])
    ],
    dependencies: [
        .package(path: "../ShotModel")
    ],
    targets: [
        .target(name: "SOPKit", dependencies: ["ShotModel"]),
        .testTarget(name: "SOPKitTests", dependencies: ["SOPKit"]),
    ]
)
