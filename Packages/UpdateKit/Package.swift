// swift-tools-version: 6.1
// UpdateKit — the notify-only update checker (#62 Phase 1). UI-free and
// headless-testable: a semver comparator, a raw-URLSession GitHub Releases
// client pinned to api.github.com, and a persisted throttle so the app checks at
// most once a day and backs off correctly when offline or rate-limited.
//
// SCOPE BOUNDARY (see issue #62): this package NOTIFIES and nothing else. It
// never downloads an asset and never touches the app bundle. Self-installing
// updates are blocked on Developer ID signing + notarization — on the current
// ad-hoc pipeline every update orphans all three TCC grants (Screen Recording,
// Accessibility, Input Monitoring), because macOS keys those to the designated
// requirement (a bare cdhash here), not the bundle id. Do not add a downloader
// to this package before that lands.
import PackageDescription

let package = Package(
    name: "UpdateKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UpdateKit", targets: ["UpdateKit"])
    ],
    dependencies: [
        .package(path: "../ShotModel")
    ],
    targets: [
        .target(name: "UpdateKit", dependencies: ["ShotModel"]),
        .testTarget(name: "UpdateKitTests", dependencies: ["UpdateKit"]),
        // Live smoke test against the REAL GitHub Releases API — proves the
        // pinned URL, the User-Agent GitHub requires, TLS, and that the parser
        // still matches the shape GitHub actually returns (which unit tests,
        // running off a fixture, cannot):
        //   swift run --package-path Packages/UpdateKit UpdateSelfTest
        .executableTarget(name: "UpdateSelfTest", dependencies: ["UpdateKit"]),
    ]
)
