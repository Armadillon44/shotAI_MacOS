import CryptoKit
import Foundation
import Security

/// base64url (RFC 4648 §5), no padding — what OAuth uses everywhere.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a base64url segment, re-padding as needed. Returns nil on garbage.
    static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t)
    }
}

enum CryptoRandom {
    /// CSPRNG bytes from the Security framework. Never `Int.random` or
    /// `arc4random` — a predictable verifier defeats the point of PKCE.
    static func bytes(_ count: Int) -> Data {
        var d = Data(count: count)
        let status = d.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return d
    }
}

/// One PKCE + CSRF triple. Created per interactive sign-in, used once, dropped.
public struct PkceParameters: Sendable {
    /// 43 chars, unreserved-only. RFC 7636 §4.1 allows 43...128.
    public let codeVerifier: String
    /// BASE64URL(SHA256(ASCII(code_verifier))) — RFC 7636 §4.2.
    public let codeChallenge: String
    public let codeChallengeMethod = "S256"
    /// CSRF token echoed back by /authorize. RFC 6749 §10.12.
    public let state: String

    public init() {
        // 32 random bytes -> 43 base64url chars: maximum entropy per character
        // while staying inside the unreserved set, so no filtering is needed.
        let verifier = Base64URL.encode(CryptoRandom.bytes(32))
        self.codeVerifier = verifier
        self.codeChallenge = Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
        self.state = Base64URL.encode(CryptoRandom.bytes(32))
    }
}

/// Length-independent compare, so the `state` check cannot be timed.
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff = UInt8(x.count == y.count ? 0 : 1)
    for i in 0..<max(x.count, y.count) {
        diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
    }
    return diff == 0
}

/// Pull the numeric AADSTS code out of a human-readable error_description.
func aadstsCode(in s: String) -> Int? {
    guard let r = s.range(of: #"AADSTS(\d+)"#, options: .regularExpression) else { return nil }
    return Int(s[r].dropFirst(6))
}
