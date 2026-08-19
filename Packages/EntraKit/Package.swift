// swift-tools-version: 6.1
// EntraKit — hand-rolled Microsoft Entra ID sign-in (OAuth 2.0 authorization
// code + PKCE) plus the Anthropic Workload Identity Federation credential path
// (#69, docs/SSO-WIF.md).
//
// UI-free and headless-testable: the browser hop sits behind `InteractiveSignIn`,
// whose only production conformer lives in the app target
// (shotAI/Auth/WebAuthSignIn.swift), because ASWebAuthenticationSession is
// @MainActor-bound and AppKit-linked. Same shape CaptureKit uses for hardware.
//
// ZERO THIRD-PARTY DEPENDENCIES (README.md). Foundation + CryptoKit + Security
// only. Do not add MSAL or AppAuth: the flow is deliberately hand-rolled, and
// the AADSTS classification tables here are what make that tractable.
//
// NOT named AuthKit on purpose — /System/Library/PrivateFrameworks/AuthKit.framework
// exists, and a SwiftPM module of that name risks shadowing it.
import PackageDescription

let package = Package(
    name: "EntraKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "EntraKit", targets: ["EntraKit"])],
    dependencies: [
        .package(path: "../ShotModel"),
        .package(path: "../SOPKit"),
    ],
    targets: [
        .target(name: "EntraKit", dependencies: ["ShotModel", "SOPKit"]),
        .testTarget(name: "EntraKitTests", dependencies: ["EntraKit"]),
        .executableTarget(name: "EntraSelfTest", dependencies: ["EntraKit"]),
    ]
)
