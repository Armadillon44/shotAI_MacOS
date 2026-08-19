import Foundation

// Anthropic Messages API wire details: the structured-output JSON schema Claude
// fills, the Codable shape we parse the result into, and the friendly error
// mapping. The schema stays within the structured-output subset (no length/range
// constraints; every object closed with additionalProperties:false and lists all
// keys in `required`; nullables via anyOf). Mirrors SopEditSchema in claude-service.ts.

private func nullable(_ inner: [String: Any]) -> [String: Any] {
    ["anyOf": [inner, ["type": "null"]]]
}

/// The `output_config.format.schema` for the inline SOP edit plan. A function
/// (not a global `let`) so it builds a fresh value — no shared mutable global.
func sopEditJSONSchema() -> [String: Any] { [
    "type": "object",
    "additionalProperties": false,
    "required": ["title", "intro", "steps"],
    "properties": [
        "title": ["type": "string"],
        "intro": nullable([
            "type": "object",
            "additionalProperties": false,
            "required": ["heading", "body"],
            "properties": [
                "heading": ["type": "string"],
                "body": ["type": "string"],
            ],
        ]),
        "steps": [
            "type": "array",
            "items": [
                "type": "object",
                "additionalProperties": false,
                "required": ["stepNumber", "caption", "body", "sectionHeading", "sectionBody"],
                "properties": [
                    "stepNumber": ["type": "integer"],
                    "caption": ["type": "string"],
                    "body": ["type": "string"],
                    "sectionHeading": nullable(["type": "string"]),
                    "sectionBody": nullable(["type": "string"]),
                ],
            ],
        ],
    ],
] }

/// Decoded structured output. Mapped to `SopEditPlan` after validation.
struct SopEditRaw: Decodable {
    let title: String
    let intro: IntroRaw?
    let steps: [StepRaw]

    struct IntroRaw: Decodable { let heading: String; let body: String }
    struct StepRaw: Decodable {
        let stepNumber: Int
        let caption: String
        let body: String
        let sectionHeading: String?
        let sectionBody: String?
    }
}

/// What the server said about a failure, beyond the status code. Kept as one
/// payload so every message-carrying case has the same shape.
public struct ApiFailure: Sendable, Equatable {
    public let message: String?
    public let requestId: String?
    public let retryAfter: TimeInterval?
    public let shouldRetry: Bool?

    public init(message: String? = nil, requestId: String? = nil,
                retryAfter: TimeInterval? = nil, shouldRetry: Bool? = nil) {
        self.message = message
        self.requestId = requestId
        self.retryAfter = retryAfter
        self.shouldRetry = shouldRetry
    }

    /// Longest `retry-after` still worth waiting out in-app.
    static let transientCeiling: TimeInterval = 300

    /// Is this a "slow down for a moment" or a "this will not succeed"?
    ///
    /// Anthropic publishes NO distinct error type for an exhausted spend cap, and
    /// the type string is believed identical to an ordinary throttle, so
    /// `error.type` cannot separate them. `retry-after` can: a real throttle says
    /// when to come back. Absent, implausibly long, or an explicit
    /// `x-should-retry: false` all mean stop.
    var isTransientThrottle: Bool {
        if shouldRetry == false { return false }
        guard let after = retryAfter else { return false }
        return after > 0 && after <= Self.transientCeiling
    }

    /// Appended to user-facing text — the only handle support can act on.
    var idSuffix: String { requestId.map { " (request ID: \($0))" } ?? "" }
}

/// Errors the Claude paths surface. Messages never leak the key. Mirrors the
/// friendlyError mapping in claude-service.ts, by HTTP status.
public enum ClaudeError: Error, LocalizedError, Equatable {
    case disabled
    case noKey
    case noScreenshots
    case unbakedRedaction(String)
    case invalidKey(ApiFailure)          // 401
    case billing(ApiFailure)             // 402
    case permissionDenied(ApiFailure)    // 403
    case modelUnavailable(ApiFailure)    // 404
    case rateLimited(ApiFailure)         // 429, retryable
    case limitReached(ApiFailure)        // 429 that will NOT succeed on retry
    case overloaded                      // 529 / mid-stream overloaded_error
    case connection                      // transport failure
    case cutoff                          // stop_reason == max_tokens
    case refusal                         // stop_reason == refusal
    case noContent
    case malformed
    case incomplete
    case api(status: Int, failure: ApiFailure)

    /// Payload-free discriminator, so callers and tests can compare a case
    /// without reconstructing the server's exact response.
    public enum Kind: Sendable, Equatable {
        case disabled, noKey, noScreenshots, unbakedRedaction, invalidKey, billing
        case permissionDenied, modelUnavailable, rateLimited, limitReached, overloaded
        case connection, cutoff, refusal, noContent, malformed, incomplete, api
    }

    public var kind: Kind {
        switch self {
        case .disabled: .disabled
        case .noKey: .noKey
        case .noScreenshots: .noScreenshots
        case .unbakedRedaction: .unbakedRedaction
        case .invalidKey: .invalidKey
        case .billing: .billing
        case .permissionDenied: .permissionDenied
        case .modelUnavailable: .modelUnavailable
        case .rateLimited: .rateLimited
        case .limitReached: .limitReached
        case .overloaded: .overloaded
        case .connection: .connection
        case .cutoff: .cutoff
        case .refusal: .refusal
        case .noContent: .noContent
        case .malformed: .malformed
        case .incomplete: .incomplete
        case .api: .api
        }
    }

    /// True when retrying the same request could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .connection: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .disabled: "AI SOP generation is turned off."
        case .noKey: "No API key set."
        case .noScreenshots: "This project has no captured screenshots to build an SOP from."
        case .unbakedRedaction(let m): m
        // The server's own text is kept on the mapped statuses: for the
        // ambiguous ones it is the only signal that distinguishes them.
        case .invalidKey(let f): (f.message ?? "Invalid API key.") + f.idSuffix
        case .billing(let f):
            (f.message ?? "Anthropic rejected the request for a billing reason — the organization may be out of credit.")
                + f.idSuffix
        case .permissionDenied(let f):
            (f.message ?? "This account lacks permission for the selected model.") + f.idSuffix
        case .modelUnavailable(let f):
            (f.message ?? "The selected model is unavailable for this account.") + f.idSuffix
        case .rateLimited(let f):
            "Rate limited — " + (f.retryAfter.map { "try again in about \(Int($0.rounded()))s." } ?? "wait a moment and try again.")
                + f.idSuffix
        // Deliberately does NOT assert which one it is. A spend cap and a
        // sustained rate limit are indistinguishable from the response, so
        // claiming "budget exhausted" would be a guess presented as fact.
        case .limitReached(let f):
            (f.message.map { $0 + " " } ?? "")
                + "Anthropic rejected the request: the workspace's rate limit or spending cap has been reached. "
                + "Retrying will not help — this needs whoever administers your Anthropic organization."
                + f.idSuffix
        case .overloaded: "Anthropic is temporarily overloaded — wait a moment and try again."
        case .connection: "Could not reach Anthropic — check your network connection."
        case .cutoff: "The SOP was cut off at the output limit. Try again, or split the project into fewer steps."
        case .refusal: "Claude declined to generate this SOP (the content was flagged)."
        case .noContent: "Claude returned no SOP content."
        case .malformed: "Claude returned malformed SOP data. Please try again."
        case .incomplete: "Claude returned an incomplete SOP — no step instructions were written. Try again, and consider raising Effort (Settings ▸ AI) — low effort sometimes under-produces."
        case .api(let status, let f): (f.message ?? "API error (\(status)).") + f.idSuffix
        }
    }

    /// Map a non-2xx response (status + headers + optional API message) to a
    /// friendly case. Takes the whole head, not just the status: 429 alone is
    /// not classifiable (see `ApiFailure.isTransientThrottle`).
    static func from(head: ResponseHead, message: String?) -> ClaudeError {
        let f = ApiFailure(message: message, requestId: head.requestId,
                           retryAfter: head.retryAfter, shouldRetry: head.shouldRetry)
        switch head.status {
        case 401: return .invalidKey(f)
        case 402: return .billing(f)
        case 403: return .permissionDenied(f)
        case 404: return .modelUnavailable(f)
        case 429: return f.isTransientThrottle ? .rateLimited(f) : .limitReached(f)
        case 529: return .overloaded
        default: return .api(status: head.status, failure: f)
        }
    }
}

