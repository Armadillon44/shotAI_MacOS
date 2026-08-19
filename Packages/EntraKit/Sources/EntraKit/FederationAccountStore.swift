import Foundation
import Security

/// What persists between launches for a signed-in user.
///
/// The refresh token is the only long-lived secret in the whole design, which is
/// why it is the only thing written to the Keychain. The access token and the
/// minted Anthropic token are deliberately NOT here: both live minutes, both are
/// cheap to re-mint from the refresh token, and persisting them would widen the
/// at-rest attack surface for no benefit.
public struct FederationAccount: Sendable, Equatable, Codable {
    /// Entra refresh token. Rotates on every use — always overwrite.
    public let refreshToken: String
    /// Display label from the id_token. PERSONAL DATA: shown in Settings, kept in
    /// the Keychain, never logged.
    public let accountLabel: String?
    /// Whether the last observed access token carried the required app role.
    /// Advisory only, used to explain a denial before making the user wait for one.
    public let hadRequiredRole: Bool?
    /// Which tenant this account belongs to, so a config change to a different
    /// tenant invalidates it rather than failing confusingly.
    public let tenantId: String?

    public init(refreshToken: String, accountLabel: String?,
                hadRequiredRole: Bool?, tenantId: String?) {
        self.refreshToken = refreshToken
        self.accountLabel = accountLabel
        self.hadRequiredRole = hadRequiredRole
        self.tenantId = tenantId
    }
}

public protocol FederationAccountStore: Sendable {
    func load() -> FederationAccount?
    func save(_ account: FederationAccount) throws
    func clear() throws
}

public enum FederationStoreError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .keychain(let s): "Could not update the Keychain (error \(s))."
        }
    }
}

/// Login-Keychain-backed account store, matching `SOPKit.KeychainApiKeyStore`.
public struct KeychainFederationAccountStore: FederationAccountStore {
    private let service: String
    private let account: String

    public init(service: String = "com.armadillon44.shotai",
                account: String = "entra-federation-account") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> FederationAccount? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(FederationAccount.self, from: data)
    }

    public func save(_ acct: FederationAccount) throws {
        let data = try JSONEncoder().encode(acct)
        // AfterFirstUnlock, not WhenUnlocked: a silent refresh may run while the
        // screen is locked (the user left a generation running), and failing then
        // would surface as a spurious "sign in again".
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add.merge(attrs) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw FederationStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw FederationStoreError.keychain(status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FederationStoreError.keychain(status)
        }
    }
}

/// In-memory store for tests.
public final class InMemoryFederationAccountStore: FederationAccountStore, @unchecked Sendable {
    private let lock = NSLock()
    private var account: FederationAccount?
    public init(_ initial: FederationAccount? = nil) { self.account = initial }

    public func load() -> FederationAccount? { lock.withLock { account } }
    public func save(_ a: FederationAccount) throws { lock.withLock { account = a } }
    public func clear() throws { lock.withLock { account = nil } }
}
