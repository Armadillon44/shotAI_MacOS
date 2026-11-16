import Foundation

// Model discovery. Once a day the app reads Anthropic's model list and, when a
// newer Sonnet appears that supports everything shotAI's generation request uses,
// offers it with one click. Nothing changes until someone chooses it.
//
// Everything here is pure except `ClaudeClient.listModels`. The offer and the
// throttle are decided from data, so both are tested without a network.

/// The model line shotAI generates with. An offer is only ever another Sonnet: the
/// prompt, the effort default and users' cost expectations were all set for it.
public let SOP_MODEL_LINE = "sonnet"

/// The output ceiling a generation asks for. Thinking draws from it as well as the
/// plan; streamed, and only what is generated is billed.
public let SOP_GENERATION_MAX_TOKENS = 64000

/// A model whose own output ceiling is below this could not hold a long SOP and
/// its thinking, so it is not offered.
public let SOP_MIN_OUTPUT_TOKENS = 32000

/// Nor is one whose context could not hold a large project's screenshots.
public let SOP_MIN_INPUT_TOKENS = 200_000

/// Shape check for a model id read from the network, before it can reach a URL
/// path (`checkModel` puts it in one) or a request body: lowercase letters,
/// digits, '-' and '.', starting with a letter, no "..", at most 100 characters.
public func isValidModelId(_ id: String) -> Bool {
    guard let first = id.unicodeScalars.first, ("a"..."z").contains(first),
          id.unicodeScalars.count <= 100, !id.contains("..") else { return false }
    return id.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "."
    }
}

/// A model the user chose from Anthropic's list that this build does not know in
/// code. It carries what a request for the model needs that the list cannot
/// promise stays the same: the output ceiling, and whether there is a fallback.
public struct SopModelProfile: Codable, Sendable, Equatable {
    public let id: String
    /// Shown in Settings and the AI SOP panel. Sanitized when parsed.
    public let displayName: String
    /// The model's own output ceiling (`max_tokens` in the Models API).
    public let maxOutputTokens: Int
    /// `allowed_fallback_models`. Non-empty means the API can rerun a request the
    /// model's safeguards declined, so generation asks for that.
    public let fallbackModels: [String]

    public init(id: String, displayName: String, maxOutputTokens: Int, fallbackModels: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.maxOutputTokens = maxOutputTokens
        self.fallbackModels = fallbackModels
    }

    /// Whether a request can be built from this profile at all. Checked again when
    /// settings are read back, so a hand-edited or truncated profile falls back to
    /// the default model instead of reaching the API.
    public var isUsable: Bool {
        isValidModelId(id) && maxOutputTokens >= SOP_MIN_OUTPUT_TOKENS
    }
}

/// One entry of `GET /v1/models`, reduced to what discovery decides on. Cached
/// between launches, so an offer survives a restart inside the daily window.
public struct ListedModel: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let createdAt: Date?
    /// "sonnet", "opus", "haiku", ...
    public let line: String?
    /// "active" or "deprecated"; nil when the list did not say.
    public let lifecycle: String?
    public let retiresAt: Date?
    public let maxInputTokens: Int?
    public let maxOutputTokens: Int?
    public let fallbackModels: [String]
    // The capabilities a generation request depends on. Each one missing is a
    // parameter the request sends that the model would reject.
    public let imageInput: Bool
    public let structuredOutputs: Bool
    public let adaptiveThinking: Bool
    /// Supported `output_config.effort` levels.
    public let effortLevels: [String]

    public init(id: String, displayName: String, createdAt: Date?, line: String?, lifecycle: String?,
                retiresAt: Date? = nil, maxInputTokens: Int?, maxOutputTokens: Int?,
                fallbackModels: [String] = [], imageInput: Bool, structuredOutputs: Bool,
                adaptiveThinking: Bool, effortLevels: [String]) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.line = line
        self.lifecycle = lifecycle
        self.retiresAt = retiresAt
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.fallbackModels = fallbackModels
        self.imageInput = imageInput
        self.structuredOutputs = structuredOutputs
        self.adaptiveThinking = adaptiveThinking
        self.effortLevels = effortLevels
    }

    /// What this model lacks for shotAI's generation request; empty when it can
    /// serve one. A capability the list does not mention counts as missing.
    public var sopGaps: [String] {
        var gaps: [String] = []
        if !imageInput { gaps.append("image input") }
        if !structuredOutputs { gaps.append("structured output") }
        if !adaptiveThinking { gaps.append("adaptive thinking") }
        let levels = Set(effortLevels)
        for e in SopEffort.allCases where !levels.contains(e.rawValue) { gaps.append("\(e.rawValue) effort") }
        if (maxOutputTokens ?? 0) < SOP_MIN_OUTPUT_TOKENS { gaps.append("output length") }
        if (maxInputTokens ?? 0) < SOP_MIN_INPUT_TOKENS { gaps.append("context length") }
        return gaps
    }

    /// Not deprecated. A list that stops saying is read as active: discovery
    /// should not go quiet because a field went missing.
    public var isActive: Bool { lifecycle == nil || lifecycle == "active" }

    /// Deprecated, or given a date after which it stops working.
    public var isRetiring: Bool { lifecycle == "deprecated" || retiresAt != nil }

    public var profile: SopModelProfile {
        SopModelProfile(id: id, displayName: displayName,
                        maxOutputTokens: maxOutputTokens ?? 0, fallbackModels: fallbackModels)
    }
}

/// Parsing for `GET /v1/models`. Tolerant per entry — one odd entry is dropped,
/// not the page — and strict about the page itself.
enum ModelList {
    struct Page {
        let models: [ListedModel]
        let hasMore: Bool
        let lastId: String?
    }

    static func parsePage(_ data: Data) throws -> Page {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["data"] as? [Any] else { throw ClaudeError.malformed }
        return Page(
            models: entries.compactMap { ($0 as? [String: Any]).flatMap(model(from:)) },
            hasMore: obj["has_more"] as? Bool ?? false,
            lastId: obj["last_id"] as? String)
    }

    static func model(from o: [String: Any]) -> ListedModel? {
        guard let id = o["id"] as? String, isValidModelId(id) else { return nil }
        let caps = o["capabilities"] as? [String: Any] ?? [:]
        let effort = caps["effort"] as? [String: Any] ?? [:]
        let levels = effort.keys.filter { supported(effort, [$0]) }.sorted()
        return ListedModel(
            id: id,
            displayName: displayName(o["display_name"] as? String, fallback: id),
            createdAt: date(o["created_at"]),
            line: o["line"] as? String,
            lifecycle: o["lifecycle"] as? String,
            retiresAt: date(o["retires_at"]),
            maxInputTokens: o["max_input_tokens"] as? Int,
            maxOutputTokens: o["max_tokens"] as? Int,
            fallbackModels: ((o["allowed_fallback_models"] as? [Any]) ?? []).compactMap { $0 as? String },
            imageInput: supported(caps, ["image_input"]),
            structuredOutputs: supported(caps, ["structured_outputs"]),
            adaptiveThinking: supported(caps, ["thinking", "types", "adaptive"]),
            effortLevels: supported(caps, ["effort"]) ? levels : [])
    }

    /// `{"a": {"b": {"supported": true}}}` for path ["a", "b"]. Anything else is false.
    private static func supported(_ root: [String: Any], _ path: [String]) -> Bool {
        var node: Any? = root
        for key in path { node = (node as? [String: Any])?[key] }
        return ((node as? [String: Any])?["supported"] as? Bool) == true
    }

    /// The name is shown in the UI, so it is cleaned: no control characters,
    /// trimmed, and capped. An empty result falls back to the id.
    private static func displayName(_ raw: String?, fallback: String) -> String {
        let cleaned = String(String.UnicodeScalarView(
            (raw ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(60))
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

/// What the AI settings and the AI SOP panel offer, if anything.
public struct ModelOffer: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// A compatible Sonnet newer than the model in use.
        case newer
        /// The model in use is deprecated, and stops working on `retiresAt` when
        /// the list gives a date.
        case retiring(retiresAt: Date?)
        /// The model in use is not in this account's model list, so a request
        /// for it will fail.
        case unavailable
    }

    public let reason: Reason
    /// The model in use when the offer was made.
    public let current: SopModelId
    /// The model to switch to: the newest compatible Sonnet. nil when the model in
    /// use is retiring or unavailable and the list has no replacement.
    public let candidate: SopModelProfile?

    /// Key under which "Not now" hides the offer from the AI SOP panel. An
    /// unavailable model is not dismissible: generation would fail anyway.
    public var dismissKey: String? {
        switch reason {
        case .newer: candidate.map { "newer:\($0.id)" }
        // Per model in use AND replacement: a newer replacement appearing later is
        // news worth showing again.
        case .retiring: "retiring:\(current.rawValue):\(candidate?.id ?? "-")"
        case .unavailable: nil
        }
    }
}

/// Decide the offer from a cached listing; nothing is fetched here.
///
/// `complete` is whether the listing covered every page. Only a complete listing
/// can say the model in use is missing from it.
public func modelOffer(listed: [ListedModel], complete: Bool, current: SopModelId) -> ModelOffer? {
    // Never checked, or an empty answer: say nothing rather than call everything missing.
    guard !listed.isEmpty else { return nil }
    let usable = listed.filter { $0.line == SOP_MODEL_LINE && $0.isActive && !$0.isRetiring && $0.sopGaps.isEmpty }
    func newest(_ ms: [ListedModel]) -> ListedModel? {
        ms.max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    guard let mine = listed.first(where: { $0.id == current.rawValue }) else {
        guard complete else { return nil }
        return ModelOffer(reason: .unavailable, current: current, candidate: newest(usable)?.profile)
    }
    if mine.isRetiring {
        return ModelOffer(reason: .retiring(retiresAt: mine.retiresAt), current: current,
                          candidate: newest(usable.filter { $0.id != mine.id })?.profile)
    }
    // Newer means released later. Without both dates there is nothing to compare,
    // and an offer that could be a downgrade is worse than none.
    guard let best = newest(usable), best.id != mine.id,
          let bestDate = best.createdAt, let mineDate = mine.createdAt, bestDate > mineDate else { return nil }
    return ModelOffer(reason: .newer, current: current, candidate: best.profile)
}

/// The cached listing plus the daily throttle, persisted by the app between launches.
public struct ModelDiscoveryState: Codable, Sendable, Equatable {
    public var listed: [ListedModel] = []
    /// Whether `listed` covered every page of the last listing.
    public var complete = false
    public var checkedAt: Date?
    public var nextCheckAt: Date?
    /// Offers hidden from the AI SOP panel with "Not now", by `ModelOffer.dismissKey`.
    public var dismissed: [String] = []

    public static let successInterval: TimeInterval = 24 * 3600
    /// A failed check is retried sooner, but not on every launch.
    public static let failureInterval: TimeInterval = 6 * 3600

    public init() {}

    /// Due when no check is scheduled, when the scheduled time has passed, or when
    /// it lies further ahead than any schedule could set — a clock that moved
    /// backwards must not silence discovery for months.
    public func isDue(at now: Date) -> Bool {
        guard let next = nextCheckAt else { return true }
        return now >= next || next.timeIntervalSince(now) > Self.successInterval
    }

    public mutating func recordSuccess(_ models: [ListedModel], complete: Bool, at now: Date) {
        listed = models
        self.complete = complete
        checkedAt = now
        nextCheckAt = now.addingTimeInterval(Self.successInterval)
    }

    /// The cached listing is kept: a failed check says nothing new about the models.
    public mutating func recordFailure(at now: Date) {
        nextCheckAt = now.addingTimeInterval(Self.failureInterval)
    }

    public mutating func dismiss(_ offer: ModelOffer) {
        guard let key = offer.dismissKey, !dismissed.contains(key) else { return }
        dismissed.append(key)
    }

    public func isDismissed(_ offer: ModelOffer) -> Bool {
        offer.dismissKey.map(dismissed.contains) ?? false
    }

    /// Tolerant: a stored state this build cannot read is a fresh one, which costs
    /// at most one extra check.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        listed = (try? c.decode([ListedModel].self, forKey: .listed)) ?? []
        complete = (try? c.decode(Bool.self, forKey: .complete)) ?? false
        checkedAt = try? c.decodeIfPresent(Date.self, forKey: .checkedAt)
        nextCheckAt = try? c.decodeIfPresent(Date.self, forKey: .nextCheckAt)
        dismissed = (try? c.decode([String].self, forKey: .dismissed)) ?? []
    }
}
