import EntraKit
import Foundation
import Observation
import ShotModel
import SOPKit

/// Sign-in state for the UI.
///
/// Owns the federation config and the federated provider, and is the only thing
/// the views talk to about auth. It never sees a token: `FederatedCredentialProvider`
/// keeps those, and `ClaudeCredential` has no accessor, so a secret cannot reach
/// a view even by accident.
@MainActor
@Observable
final class AuthModel {
    /// What the account section should show.
    enum State: Equatable {
        /// No federation config on this Mac — normal for anyone outside the org.
        case unavailable
        /// Config was delivered but is unusable. Names the fields, never values.
        case misconfigured(fields: [String])
        case signedOut
        case signedIn(account: String?, entitled: Bool?)
    }

    private(set) var state: State = .unavailable
    private(set) var busy = false
    /// Last sign-in failure, already phrased for a human.
    private(set) var error: String?

    @ObservationIgnored private let configState: FederationConfigState
    /// Handed to CompositeCredentialProvider so it can distinguish
    /// "no SSO here" from "SSO configured wrongly".
    var configStateForProvider: FederationConfigState { configState }
    @ObservationIgnored let federated: FederatedCredentialProvider?
    @ObservationIgnored private let browser = WebAuthSignIn()

    init(configSource: any FederationConfigSource = ManagedFederationConfigStore()) {
        let state = configSource.load()
        self.configState = state
        self.federated = state.config.map { FederatedCredentialProvider(config: $0) }
        switch state {
        case .absent: self.state = .unavailable
        case .invalid(let missing): self.state = .misconfigured(fields: missing)
        case .ready: self.state = .signedOut   // corrected by the first refresh()
        }
    }

    /// Whether this build/Mac offers SSO at all. Drives whether the Account
    /// section appears.
    var federationAvailable: Bool {
        if case .unavailable = state { return false }
        return true
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    /// Signed in, but known to lack the app role — the case worth explaining
    /// before the user waits for a denial.
    var signedInWithoutAccess: Bool {
        if case .signedIn(_, let entitled) = state { return entitled == false }
        return false
    }

    /// Re-read the stored account. Cheap; safe to call on appear.
    func refresh() async {
        guard let federated else { return }
        let s = await federated.status()
        state = s.signedIn ? .signedIn(account: s.accountLabel, entitled: s.entitled) : .signedOut
    }

    /// Interactive sign-in. `forceLogin` skips any existing browser session,
    /// which is what "Sign in as a different user" needs.
    func signIn(forceLogin: Bool = false) async {
        guard let federated else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let account = try await federated.signIn(using: browser,
                                                     promptSelectAccount: forceLogin,
                                                     forceLogin: forceLogin)
            state = .signedIn(account: account.accountLabel, entitled: account.hadRequiredRole)
            Log.app.notice("Federated sign-in succeeded (entitled: \(account.hadRequiredRole == true, privacy: .public))")
        } catch let e as EntraAuthError {
            // A cancel is a choice, not a failure — saying nothing is right.
            if case .web(.canceled) = e { return }
            error = e.errorDescription
            Log.app.error("Federated sign-in failed: \(String(describing: e), privacy: .private)")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() async {
        guard let federated else { return }
        do {
            try await federated.signOut()
            state = .signedOut
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearError() { error = nil }
}
