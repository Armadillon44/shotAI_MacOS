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
                "required": ["stepNumber", "caption", "body", "note", "sectionHeading", "sectionBody"],
                "properties": [
                    "stepNumber": ["type": "integer"],
                    "caption": ["type": "string"],
                    "body": ["type": "string"],
                    "note": nullable(["type": "string"]),
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
        let note: String?
        let sectionHeading: String?
        let sectionBody: String?
    }
}

/// Errors the Claude paths surface. Messages never leak the key. Mirrors the
/// friendlyError mapping in claude-service.ts, by HTTP status.
public enum ClaudeError: Error, LocalizedError, Equatable {
    case disabled
    case noKey
    case noScreenshots
    case unbakedRedaction(String)
    case invalidKey            // 401
    case permissionDenied      // 403
    case modelUnavailable      // 404
    case rateLimited           // 429
    case overloaded            // 529 / mid-stream overloaded_error
    case connection            // transport failure
    case cutoff                // stop_reason == max_tokens
    case refusal               // stop_reason == refusal
    case noContent
    case malformed
    case incomplete
    case api(status: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .disabled: "AI SOP generation is turned off."
        case .noKey: "No API key set."
        case .noScreenshots: "This project has no captured screenshots to build an SOP from."
        case .unbakedRedaction(let m): m
        case .invalidKey: "Invalid API key."
        case .permissionDenied: "This key lacks permission for the selected model."
        case .modelUnavailable: "The selected model is unavailable for this key."
        case .rateLimited: "Rate limited — wait a moment and try again."
        case .overloaded: "Anthropic is temporarily overloaded — wait a moment and try again."
        case .connection: "Could not reach Anthropic — check your network connection."
        case .cutoff: "The SOP was cut off at the output limit. Try again, or split the project into fewer steps."
        case .refusal: "Claude declined to generate this SOP (the content was flagged)."
        case .noContent: "Claude returned no SOP content."
        case .malformed: "Claude returned malformed SOP data. Please try again."
        case .incomplete: "Claude returned an incomplete SOP — no step instructions were written. Try again, and consider raising Effort (Settings ▸ AI) — low effort sometimes under-produces."
        case .api(let status, let message): message ?? "API error (\(status))."
        }
    }

    /// Map a non-2xx HTTP status (+ optional API error message) to a friendly case.
    static func from(status: Int, message: String?) -> ClaudeError {
        switch status {
        case 401: .invalidKey
        case 403: .permissionDenied
        case 404: .modelUnavailable
        case 429: .rateLimited
        case 529: .overloaded
        default: .api(status: status, message: message)
        }
    }
}
