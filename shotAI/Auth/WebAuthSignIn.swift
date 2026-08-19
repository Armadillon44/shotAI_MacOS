import AppKit
import AuthenticationServices
import EntraKit
import Foundation

/// The browser hop — the ONLY place in the repo that imports
/// AuthenticationServices.
///
/// `ASWebAuthenticationSession` is what makes a hand-rolled OAuth flow safe on
/// macOS: credentials are typed into a real system browser that shotAI cannot
/// read, and the callback comes back by URL scheme. Microsoft explicitly
/// discourages embedding a WKWebView for sign-in — it breaks Windows Hello and
/// FIDO keys, and Conditional Access policies can refuse it outright.
@MainActor
final class WebAuthSignIn: NSObject, InteractiveSignIn, ASWebAuthenticationPresentationContextProviding {
    /// Held for the duration of one authorization. `ASWebAuthenticationSession`
    /// is deallocated-cancelled, so losing this reference mid-flight closes the
    /// browser out from under the user.
    private var session: ASWebAuthenticationSession?

    nonisolated func authorize(url: URL, callbackScheme: String, ephemeral: Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            Task { @MainActor in
                guard NSApp.windows.contains(where: { $0.isVisible }) else {
                    continuation.resume(throwing: WebAuthError.noPresentationAnchor)
                    return
                }

                let s = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                    // ⚠️ THIS RUNS ON AN XPC QUEUE, NOT THE MAIN ACTOR.
                    // (com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent)
                    //
                    // Nothing @MainActor-isolated may be touched here. Doing so
                    // trips Swift 6's runtime isolation check and traps the
                    // process with SIGTRAP in _swift_task_checkIsolatedSwift —
                    // which is exactly how this crashed the first time it was
                    // driven by hand, because every test stubs the browser and
                    // never reaches this closure.
                    //
                    // So: resume the continuation (Sendable, safe from any
                    // queue), and hop to the main actor for the cleanup.
                    if let error {
                        let e = error as NSError
                        let canceled = e.domain == ASWebAuthenticationSessionErrorDomain
                            && e.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                        continuation.resume(throwing: canceled
                            ? WebAuthError.canceled
                            : WebAuthError.failed(error.localizedDescription))
                    } else if let callback {
                        continuation.resume(returning: callback)
                    } else {
                        continuation.resume(throwing: WebAuthError.failed("Sign-in returned no result."))
                    }
                    Task { @MainActor [weak self] in self?.session = nil }
                }

                s.presentationContextProvider = self
                // false: reuse the browser's existing session, so someone already
                // signed in to Microsoft often gets through in one click. `true`
                // is only a REQUEST the browser may ignore, so it is never relied
                // on for account switching — `prompt=` handles that.
                s.prefersEphemeralWebBrowserSession = ephemeral
                self.session = s

                if !s.start() {
                    self.session = nil
                    continuation.resume(throwing: WebAuthError.failed("macOS would not open the sign-in window."))
                }
            }
        }
    }

    /// Called by AppKit on the main thread while presenting.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        }
    }
}
