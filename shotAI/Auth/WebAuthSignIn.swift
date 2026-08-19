import AppKit
import AuthenticationServices
import EntraKit
import Foundation

/// The browser hop — the ONLY place in the repo that imports
/// AuthenticationServices.
///
/// `ASWebAuthenticationSession` is what makes a hand-rolled OAuth flow safe on
/// macOS: the credentials are typed into a real system browser that shotAI
/// cannot read, and the callback is delivered back by URL scheme. Microsoft
/// explicitly discourages embedding a WKWebView for sign-in — it breaks Windows
/// Hello and FIDO keys, and Conditional Access policies can refuse it outright.
@MainActor
final class WebAuthSignIn: NSObject, InteractiveSignIn, ASWebAuthenticationPresentationContextProviding {
    /// Held for the duration of one authorization. `ASWebAuthenticationSession`
    /// is documented to be deallocated-cancelled, so losing this reference
    /// mid-flight closes the browser out from under the user.
    private var session: ASWebAuthenticationSession?

    nonisolated func authorize(url: URL, callbackScheme: String, ephemeral: Bool) async throws -> URL {
        try await MainActor.run { () -> Void in
            // Presented from a window; if the app has none there is nothing to
            // anchor to and the session would fail opaquely.
            guard NSApp.keyWindow != nil || NSApp.windows.contains(where: { $0.isVisible }) else {
                throw WebAuthError.noPresentationAnchor
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let s = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                    // Clear first: the completion handler is the end of this
                    // session's life either way.
                    self.session = nil
                    if let error {
                        let e = error as NSError
                        if e.domain == ASWebAuthenticationSessionErrorDomain,
                           e.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            continuation.resume(throwing: WebAuthError.canceled)
                        } else {
                            continuation.resume(throwing: WebAuthError.failed(error.localizedDescription))
                        }
                        return
                    }
                    guard let callback else {
                        continuation.resume(throwing: WebAuthError.failed("Sign-in returned no result."))
                        return
                    }
                    continuation.resume(returning: callback)
                }
                s.presentationContextProvider = self
                // false: reuse the browser's existing session, so a user already
                // signed in to Microsoft often gets through in one click.
                // `true` is only a REQUEST the browser may ignore, so it is never
                // relied on for account switching — `prompt=` handles that.
                s.prefersEphemeralWebBrowserSession = ephemeral
                self.session = s
                if !s.start() {
                    self.session = nil
                    continuation.resume(throwing: WebAuthError.failed("macOS would not open the sign-in window."))
                }
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        }
    }
}
