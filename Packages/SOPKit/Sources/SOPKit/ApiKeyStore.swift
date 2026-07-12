import Foundation
import Security

// Encrypted storage for the Anthropic API key. On macOS the right home is the
// login Keychain (Security framework) rather than the Windows app's safeStorage +
// secrets.json file — the OS encrypts it at rest and scopes it to this app's
// signed identity. The key is read ONLY by the Claude client; UI code calls
// set/clear/status and never reads the key back (mirrors the Windows
// main-only invariant). A read-only ANTHROPIC_API_KEY env var is a dev/CI fallback.
// Ported from shotAI-original/src/main/secrets.ts.

public enum ApiKeySource: String, Sendable { case stored, env, none }

public struct ApiKeyStatus: Sendable, Equatable {
    public let hasKey: Bool
    public let source: ApiKeySource
    public init(hasKey: Bool, source: ApiKeySource) {
        self.hasKey = hasKey
        self.source = source
    }
}

public enum ApiKeyError: Error, LocalizedError, Equatable {
    case empty
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .empty: "API key is empty."
        case .keychain(let s): "Could not save the API key to the Keychain (error \(s))."
        }
    }
}

/// Read/write the API key. The concrete Keychain implementation is the default;
/// tests use an in-memory stub.
public protocol ApiKeyStore: Sendable {
    /// The usable key — stored (Keychain) if present, else the env var, else nil.
    /// FOR THE CLAUDE CLIENT ONLY — never surface the return value to UI.
    func key() -> String?
    /// UI-safe status: whether a key exists and how — never the key itself.
    func status() -> ApiKeyStatus
    /// Store the key (Keychain). Throws on empty or a Keychain failure.
    func set(_ key: String) throws
    /// Remove the stored key (the env-var fallback, if any, still applies).
    func clear() throws
}

/// Login-Keychain-backed key store.
public struct KeychainApiKeyStore: ApiKeyStore {
    private let service: String
    private let account: String

    public init(service: String = "com.armadillon44.shotai", account: String = "anthropic-api-key") {
        self.service = service
        self.account = account
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func stored() -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty
        else { return nil }
        return s
    }

    private func envKey() -> String? {
        guard let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return nil }
        return k
    }

    public func key() -> String? { stored() ?? envKey() }

    public func status() -> ApiKeyStatus {
        if stored() != nil { return ApiKeyStatus(hasKey: true, source: .stored) }
        if envKey() != nil { return ApiKeyStatus(hasKey: true, source: .env) }
        return ApiKeyStatus(hasKey: false, source: .none)
    }

    public func set(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ApiKeyError.empty }
        let data = Data(trimmed.utf8)
        // Update if present, else add. kSecAttrAccessibleAfterFirstUnlock: usable
        // by the (background-capable) app after the user first unlocks post-boot.
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ApiKeyError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw ApiKeyError.keychain(status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ApiKeyError.keychain(status)
        }
    }
}
