import Foundation

/// The browser hop, behind a protocol.
///
/// The only production conformer is `shotAI/Auth/WebAuthSignIn.swift` in the app
/// target, because `ASWebAuthenticationSession` is `@MainActor`-bound and
/// AppKit-linked. Keeping it abstract here is what lets
/// `swift test --package-path Packages/EntraKit` run headless — the same shape
/// CaptureKit uses to keep its pipeline tests off real hardware.
public protocol InteractiveSignIn: Sendable {
    /// Open the system web-auth browser at `url`, resolve with the callback URL.
    ///
    /// - Parameter ephemeral: normally `false`, so the user's existing browser
    ///   session is reused and sign-in is often a single click. `true` is only a
    ///   REQUEST that the browser may ignore, so never rely on it to force
    ///   account switching — use `prompt=select_account` / `prompt=login`.
    func authorize(url: URL, callbackScheme: String, ephemeral: Bool) async throws -> URL
}

/// Why an interactive sign-in ended without a callback.
public enum WebAuthError: Error, LocalizedError, Sendable, Equatable {
    /// The user closed the window or hit Cancel. Not an error to report loudly.
    case canceled
    /// No presentation anchor (no window). A programming error, not a user one.
    case noPresentationAnchor
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .canceled: "Sign-in was canceled."
        case .noPresentationAnchor: "shotAI had no window to present sign-in from."
        case .failed(let m): m
        }
    }
}
