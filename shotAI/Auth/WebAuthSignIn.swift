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
        // Released once the flow ends, however it ends. Doing it here rather than
        // in the completion handler keeps that handler free of any actor-isolated
        // state — see the @Sendable note below.
        defer { Task { @MainActor [weak self] in self?.session = nil } }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            Task { @MainActor in
                guard NSApp.windows.contains(where: { $0.isVisible }) else {
                    continuation.resume(throwing: WebAuthError.noPresentationAnchor)
                    return
                }

                // ⚠️ THE @Sendable IS LOAD-BEARING. AuthenticationServices imports
                // this completion handler as a plain (non-Sendable) block, so a
                // closure literal written inside this @MainActor Task would
                // INHERIT main-actor isolation. AuthenticationServices then calls
                // it from an XPC queue
                // (com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent),
                // Swift 6's runtime isolation check fires ON ENTRY to the closure,
                // and the process traps with SIGTRAP in
                // _swift_task_checkIsolatedSwift.
                //
                // That check runs before any statement in the body, which is why
                // removing the actor-isolated line inside it does NOT help — the
                // isolation of the closure itself is the bug. @Sendable opts out
                // of inheritance, which is the actual fix.
                let onFinish: @Sendable (URL?, Error?) -> Void = { callback, error in
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
                }

                let s = ASWebAuthenticationSession(url: url,
                                                   callbackURLScheme: callbackScheme,
                                                   completionHandler: onFinish)
                s.presentationContextProvider = self
                // false: reuse the browser's existing session, so someone already
                // signed in to Microsoft often gets through in one click. `true`
                // is only a REQUEST the browser may ignore, so it is never relied
                // on for account switching — `prompt=` handles that.
                s.prefersEphemeralWebBrowserSession = ephemeral
                self.session = s

                if !s.start() {
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
