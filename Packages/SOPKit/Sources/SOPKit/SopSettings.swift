import Foundation
import ShotModel

// The SOP (Standard Operating Procedure) generation domain — ported from
// shotAI-original/src/shared/sop.ts. The user-facing SETTINGS (model/tone/effort/
// custom instructions) plus the inline edit-plan Claude returns. Per-model pricing
// + request shaping live in ClaudeModels.swift. `SopTone`/`SopIntro` are reused
// from ShotModel (they're part of the project.json contract); the settings here
// live in app preferences, not the manifest.

/// Models offered for SOP generation — a curated allowlist so a bad id can't reach
/// the API. Parity with the Windows app: Sonnet 5 only.
public enum SopModelId: String, Codable, Sendable, CaseIterable {
    case sonnet5 = "claude-sonnet-5"
}

public struct SopModelOption: Sendable {
    public let id: SopModelId
    public let label: String
    public let blurb: String
}

public let SOP_MODELS: [SopModelOption] = [
    SopModelOption(
        id: .sonnet5,
        label: "Sonnet 5 — latest (recommended)",
        blurb: "Anthropic’s latest Sonnet: capable, fast, and cost-effective."),
]

public let DEFAULT_SOP_MODEL: SopModelId = .sonnet5

/// Generation effort — maps to `output_config.effort`. Higher = more deliberation,
/// slower, pricier.
public enum SopEffort: String, Codable, Sendable, CaseIterable {
    case low, medium, high
}

public struct SopEffortOption: Sendable {
    public let id: SopEffort
    public let label: String
    public let blurb: String
}

public let SOP_EFFORTS: [SopEffortOption] = [
    SopEffortOption(id: .low, label: "Low", blurb: "Fastest and cheapest; least deliberation."),
    SopEffortOption(id: .medium, label: "Medium", blurb: "Balanced quality, speed, and cost (recommended)."),
    SopEffortOption(id: .high, label: "High", blurb: "Most thorough; slower and pricier."),
]

public let DEFAULT_SOP_EFFORT: SopEffort = .medium

/// UI copy for the tone picker (the `SopTone` enum itself lives in ShotModel).
public struct SopToneOption: Sendable {
    public let id: SopTone
    public let label: String
    public let blurb: String
}

public let SOP_TONES: [SopToneOption] = [
    SopToneOption(id: .professional, label: "Professional", blurb: "Formal, third-person, SOP-standard phrasing."),
    SopToneOption(id: .friendly, label: "Friendly", blurb: "Warm, second-person, approachable."),
    SopToneOption(id: .concise, label: "Concise", blurb: "Minimal words, action-first."),
    SopToneOption(id: .detailed, label: "Detailed", blurb: "Thorough; explains the \"why\" and adds context."),
]

public let DEFAULT_SOP_TONE: SopTone = .professional

/// Cap on the optional free-text custom instructions appended to the system prompt.
public let SOP_CUSTOM_INSTRUCTIONS_MAX = 2000

/// User-facing SOP generation settings (NON-SECRET — persisted in app prefs). The
/// API key is NOT here; it lives in the Keychain (see ApiKeyStore).
public struct SopSettings: Codable, Equatable, Sendable {
    /// Master switch for all Claude SOP features. Off ⇒ no Claude UI, no network.
    public var enabled: Bool
    public var model: SopModelId
    public var tone: SopTone
    public var effort: SopEffort
    /// Optional extra system-prompt guidance, appended verbatim (length-capped).
    public var customInstructions: String

    public init(
        enabled: Bool = true,
        model: SopModelId = DEFAULT_SOP_MODEL,
        tone: SopTone = DEFAULT_SOP_TONE,
        effort: SopEffort = DEFAULT_SOP_EFFORT,
        customInstructions: String = ""
    ) {
        self.enabled = enabled
        self.model = model
        self.tone = tone
        self.effort = effort
        self.customInstructions = customInstructions
    }
}

public let DEFAULT_SOP_SETTINGS = SopSettings()

/// Validate/coerce possibly-partial settings from an untrusted source (persisted
/// JSON) onto a known-good base. Unknown model/tone/effort fall back to the base;
/// customInstructions is length-capped. Mirrors `coerceSopSettings`.
public func coerceSopSettings(_ raw: [String: Any]?, base: SopSettings = DEFAULT_SOP_SETTINGS) -> SopSettings {
    let r = raw ?? [:]
    var out = base
    if let v = r["enabled"] as? Bool { out.enabled = v }
    if let s = r["model"] as? String, let m = SopModelId(rawValue: s) { out.model = m }
    if let s = r["tone"] as? String, let t = SopTone(rawValue: s) { out.tone = t }
    if let s = r["effort"] as? String, let e = SopEffort(rawValue: s) { out.effort = e }
    if let s = r["customInstructions"] as? String { out.customInstructions = String(s.prefix(SOP_CUSTOM_INSTRUCTIONS_MAX)) }
    return out
}

// MARK: - Inline SOP edit plan (what Claude returns)

/// An edit Claude proposes for one screenshot step (referenced by its 1-based
/// number as shown in the prompt).
public struct SopStepEdit: Sendable, Equatable {
    /// 1-based number of the screenshot step this applies to.
    public let stepNumber: Int
    /// Short, action-oriented step title shown above the screenshot.
    public let caption: String
    /// Instruction detail shown under the screenshot.
    public let body: String
    /// If set, insert a section-heading text step immediately BEFORE this step.
    public let sectionHeading: String?
    public let sectionBody: String?
    // NOTE: no `note` field — the SOP generator no longer writes the step's
    // legacy `note` (it has no editor in the report, so AI-written notes were
    // uneditable). The existing `note` is preserved as-is on apply.
}

/// The full inline edit plan Claude returns, applied transactionally by the store.
public struct SopEditPlan: Sendable, Equatable {
    /// Refined project title, or nil to keep the current one.
    public let title: String?
    /// Optional leading intro rendered as a preamble above the steps.
    public let intro: SopIntro?
    public let steps: [SopStepEdit]
}
