import Foundation
import ShotModel

// The SOP (Standard Operating Procedure) generation domain — ported from
// shotAI-original/src/shared/sop.ts. The user-facing SETTINGS (model/tone/effort/
// custom instructions) plus the inline edit-plan Claude returns. Per-model pricing
// + request shaping live in ClaudeModels.swift. `SopTone`/`SopIntro` are reused
// from ShotModel (they're part of the project.json contract); the settings here
// live in app preferences, not the manifest.

/// A Claude model id. Built-in models are constants here; a model found by
/// discovery (ModelDiscovery.swift) is whatever id Anthropic's model list named.
///
/// An open type, no longer an enum, so a newer model can be chosen without a code
/// change. The allowlist moved rather than went away: `SopSettings` only holds an
/// id that is either built in (`MODEL_PARAMS`) or the discovered model the user
/// chose, with the profile that shapes its request, so a bad id still can't reach
/// the API. The Windows app (v1.3.0) still offers Sonnet 5 only; this is a
/// deliberate divergence until it is updated.
public struct SopModelId: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let sonnet55 = SopModelId(rawValue: "claude-sonnet-5-5")

    /// Known in code, with its price and request shape in `MODEL_PARAMS`.
    public var isBuiltIn: Bool { MODEL_PARAMS[self] != nil }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct SopModelOption: Sendable {
    public let id: SopModelId
    /// Short name for sentences ("newer than Sonnet 5.5").
    public let name: String
    public let label: String
    public let blurb: String
}

/// Built-in models. Labels make no "latest" claim: with discovery, a newer model
/// can appear in the list without this build changing.
public let SOP_MODELS: [SopModelOption] = [
    SopModelOption(
        id: .sonnet55,
        name: "Sonnet 5.5",
        label: "Sonnet 5.5 — default",
        blurb: "The model this version of shotAI was built and tested with: capable, fast, and cost-effective."),
]

public let DEFAULT_SOP_MODEL: SopModelId = .sonnet55

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

/// UI copy for the wording picker (the `SopWording` enum itself lives in ShotModel,
/// because the Generate dialog's last choice is stored in project.json).
public struct SopWordingOption: Sendable {
    public let id: SopWording
    public let label: String
    public let blurb: String
}

public let SOP_WORDINGS: [SopWordingOption] = [
    SopWordingOption(id: .specific, label: "Specific",
                     blurb: "Names the apps, buttons and values shown in the screenshots."),
    SopWordingOption(id: .general, label: "General",
                     blurb: "Describes each action in general terms, like \u{201C}open the app\u{201D} or \u{201C}choose the appropriate setting\u{201D}. Text and callouts you wrote keep their specifics."),
]

public let DEFAULT_SOP_WORDING: SopWording = .specific

/// The Generate dialog's choices for one run: the wording, and instructions for this
/// SOP only. Remembered per project as `SopRunOptions` (project.json).
public struct SopRun: Sendable, Equatable {
    public var wording: SopWording
    public var instructions: String

    public init(wording: SopWording = DEFAULT_SOP_WORDING, instructions: String = "") {
        self.wording = wording
        self.instructions = String(instructions.prefix(SOP_RUN_INSTRUCTIONS_MAX))
    }

    /// No dialog choices: the Settings wording, no instructions.
    public init(settings: SopSettings) {
        self.init(wording: settings.wording)
    }

    /// Where the Generate dialog starts for a project: its remembered choices, with
    /// Settings filling in a wording that was never chosen (or that this build does
    /// not know).
    public init(remembered: SopRunOptions?, settings: SopSettings) {
        self.init(wording: remembered?.wordingChoice ?? settings.wording,
                  instructions: remembered?.instructions ?? "")
    }

    /// What to remember: the explicit wording (the default included) and the
    /// instructions, keeping any fields a newer build stored alongside them.
    public func remembered(over existing: SopRunOptions?) -> SopRunOptions {
        var o = existing ?? SopRunOptions()
        o.wording = wording.rawValue
        o.instructions = String(instructions.prefix(SOP_RUN_INSTRUCTIONS_MAX))
        return o
    }
}

/// Cap on the optional free-text custom instructions appended to the system prompt.
public let SOP_CUSTOM_INSTRUCTIONS_MAX = 2000

/// User-facing SOP generation settings (NON-SECRET — persisted in app prefs). The
/// API key is NOT here; it lives in the Keychain (see ApiKeyStore).
public struct SopSettings: Codable, Equatable, Sendable {
    /// Master switch for all Claude SOP features. Off ⇒ no Claude UI, no network.
    public var enabled: Bool
    /// The model requests are made with. Changed only through `selectModel`, which
    /// keeps it and `discoveredModel` consistent.
    public private(set) var model: SopModelId
    /// How to shape a request for `model` when it is not built in: captured from
    /// Anthropic's model list when the user chose it. nil whenever `model` is
    /// built in, so the two can never disagree.
    public private(set) var discoveredModel: SopModelProfile?
    public var tone: SopTone
    public var effort: SopEffort
    /// The wording the Generate dialog starts from for a project that has no
    /// remembered choice of its own.
    public var wording: SopWording
    /// Optional extra system-prompt guidance, appended verbatim (length-capped).
    public var customInstructions: String

    public init(
        enabled: Bool = true,
        model: SopModelId = DEFAULT_SOP_MODEL,
        discoveredModel: SopModelProfile? = nil,
        tone: SopTone = DEFAULT_SOP_TONE,
        effort: SopEffort = DEFAULT_SOP_EFFORT,
        wording: SopWording = DEFAULT_SOP_WORDING,
        customInstructions: String = ""
    ) {
        self.enabled = enabled
        (self.model, self.discoveredModel) = Self.resolve(model: model, profile: discoveredModel)
        self.tone = tone
        self.effort = effort
        self.wording = wording
        self.customInstructions = customInstructions
    }

    /// Switch to a built-in model.
    public mutating func selectModel(_ id: SopModelId) {
        (model, discoveredModel) = Self.resolve(model: id, profile: nil)
    }

    /// Switch to a model from Anthropic's list. A model this build has since learned
    /// in code is taken as built in, so its known price and shape win.
    public mutating func selectModel(_ profile: SopModelProfile) {
        (model, discoveredModel) = Self.resolve(model: SopModelId(rawValue: profile.id), profile: profile)
    }

    /// The single rule for which model a settings value may hold: a built-in id, or
    /// the id of a usable discovered profile. Anything else is the default — which
    /// is how an id from an old settings file, a retired model, or a profile that
    /// no longer validates can never reach a request.
    static func resolve(model: SopModelId, profile: SopModelProfile?) -> (SopModelId, SopModelProfile?) {
        if model.isBuiltIn { return (model, nil) }
        if let profile, profile.id == model.rawValue, profile.isUsable { return (model, profile) }
        return (DEFAULT_SOP_MODEL, nil)
    }

    /// Tolerant, field by field: a value this build does not recognise falls back to
    /// its default and every other setting is kept.
    ///
    /// The synthesized decoder failed the WHOLE struct on one unknown value, and the
    /// app treated that as "no saved settings" — so retiring a model reset every
    /// user's tone, effort, enabled switch and custom instructions to defaults. With
    /// Sonnet 5 replaced by Sonnet 5.5, every saved settings file names a model this
    /// build no longer has; this is what moves those users to the new default
    /// without losing anything else. Same rules as `coerceSopSettings` (and the
    /// Windows coercion it mirrors), including the length cap.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SopSettings()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        (model, discoveredModel) = Self.resolve(
            model: (try? c.decode(String.self, forKey: .model)).map(SopModelId.init(rawValue:)) ?? d.model,
            profile: (try? c.decodeIfPresent(SopModelProfile.self, forKey: .discoveredModel)) ?? nil)
        tone = (try? c.decode(String.self, forKey: .tone)).flatMap(SopTone.init(rawValue:)) ?? d.tone
        effort = (try? c.decode(String.self, forKey: .effort)).flatMap(SopEffort.init(rawValue:)) ?? d.effort
        wording = (try? c.decode(String.self, forKey: .wording)).flatMap(SopWording.init(rawValue:)) ?? d.wording
        customInstructions = String(
            ((try? c.decode(String.self, forKey: .customInstructions)) ?? d.customInstructions)
                .prefix(SOP_CUSTOM_INSTRUCTIONS_MAX))
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
    // Built-in models only: this mirrors the Windows coercion, which has no
    // discovered models. Discovered ones round-trip through the Codable path.
    if let s = r["model"] as? String, SopModelId(rawValue: s).isBuiltIn { out.selectModel(SopModelId(rawValue: s)) }
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
    /// The kind of block the model declared it was writing for: "screenshot" or
    /// "text". Checked against the block's real kind, which is what keeps
    /// renumbering detectable now that every block's number is writable. For a text
    /// block, `caption` carries the block's heading.
    public var kind: String? = nil
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
    /// `stepNumber` → step id, captured from the SAME manifest the request was
    /// assembled from. `applySopEdits` looks edits up by id through this.
    ///
    /// Without it, apply matched edits by POSITION on a manifest it re-reads from
    /// disk, while the numbers were assigned against the in-memory snapshot the
    /// request was built from. Any structural edit made while the request was in
    /// flight — a drag, a delete, an inserted note, a recording appended mid-project
    /// — shifted every later step's text onto its neighbour, with no error. Binding
    /// by identity makes a moved step keep its own text and a deleted step simply
    /// receive nothing.
    ///
    /// nil means "match by position", which is only correct when nothing can have
    /// changed in between. `SopService.generate` always sets it; it is nil for plans
    /// built directly (tests) and for a manifest whose step ids are not unique, where
    /// an id cannot name one step.
    public var boundStepIds: [Int: String]? = nil
    /// Screenshot steps (by id) that did not come back fully usable even after a
    /// repair turn. Whatever could not be used was withheld, so those fields keep
    /// their previous text; the caller tells the user which steps they are.
    public var incompleteStepIds: [String] = []
}
