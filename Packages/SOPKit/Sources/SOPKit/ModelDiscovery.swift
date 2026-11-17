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

/// A model the user can switch to: one built into shotAI, or one from Anthropic's
/// model list, carrying what a request for it needs.
public enum ModelChoice: Sendable, Equatable {
    case builtIn(SopModelId)
    case discovered(SopModelProfile)

    /// A model from the list that this build has since learned in code is taken as
    /// built in, so its known price and request shape win.
    public init(_ profile: SopModelProfile) {
        let id = SopModelId(rawValue: profile.id)
        self = id.isBuiltIn ? .builtIn(id) : .discovered(profile)
    }

    public var id: SopModelId {
        switch self {
        case .builtIn(let id): id
        case .discovered(let p): SopModelId(rawValue: p.id)
        }
    }
}

extension ListedModel {
    /// A model shotAI would offer: a Sonnet that is active, not on its way out,
    /// and that accepts everything a generation request uses.
    var isSopCandidate: Bool { line == SOP_MODEL_LINE && isActive && !isRetiring && sopGaps.isEmpty }

    /// A compatible Sonnet that can still be used now: active, or deprecated with
    /// its retirement date still ahead (or not given).
    func stillWorks(at now: Date) -> Bool {
        guard line == SOP_MODEL_LINE, sopGaps.isEmpty, isActive || isRetiring else { return false }
        if let r = retiresAt, r <= now { return false }
        return true
    }
}

/// Newest first by release date; a model with no date ranks oldest, so it can
/// never hide a dated one.
private func newest(_ ms: [ListedModel]) -> ListedModel? {
    ms.max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
}

/// Decide the offer from a cached listing; nothing is fetched here.
///
/// `complete` is whether the listing covered every page. Only a complete listing
/// can say the model in use is missing from it. Models in `excluding` are never
/// the candidate: the app passes the ones that already failed this session.
public func modelOffer(listed: [ListedModel], complete: Bool, current: SopModelId,
                       excluding: Set<String> = []) -> ModelOffer? {
    // Never checked, or an empty answer: say nothing rather than call everything missing.
    guard !listed.isEmpty else { return nil }
    let usable = listed.filter { $0.isSopCandidate && !excluding.contains($0.id) }

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

/// Where the failure alert offers to go after a request for `failed` failed in a
/// way another model might avoid (`ClaudeError.isModelFault`). Never `failed`,
/// never a model in `excluding` (the ones that already failed this session, so the
/// alert cannot send the user back and forth between two failing models), and
/// never one the cached listing says is gone.
///
/// From a model off the list: back to the model this build was made for, unless
/// the listing says that one is gone too, then the newest compatible Sonnet the
/// listing has. From a built-in model: on to the replacement discovery found.
public func errorSwitchTarget(failed: SopModelId, listed: [ListedModel], complete: Bool,
                              excluding: Set<String> = [], now: Date) -> ModelChoice? {
    let skip = excluding.union([failed.rawValue])
    if failed.isBuiltIn {
        return modelOffer(listed: listed, complete: complete, current: failed, excluding: skip)?
            .candidate.map(ModelChoice.init)
    }
    let fallback = DEFAULT_SOP_MODEL
    if !skip.contains(fallback.rawValue), !listingSaysGone(fallback, listed: listed, complete: complete, now: now) {
        return .builtIn(fallback)
    }
    return newest(listed.filter { $0.isSopCandidate && !skip.contains($0.id) }).map { ModelChoice($0.profile) }
}

/// True when the listing shows `id` cannot be used: missing from a complete
/// listing, or past its retirement date. A model that is deprecated but not yet
/// retired still works.
private func listingSaysGone(_ id: SopModelId, listed: [ListedModel], complete: Bool, now: Date) -> Bool {
    guard !listed.isEmpty else { return false }
    guard let entry = listed.first(where: { $0.id == id.rawValue }) else { return complete }
    if let r = entry.retiresAt, r <= now { return true }
    return false
}

/// The Settings model picker: every built-in model, the discovered model in use,
/// each discovered model the user chose before that still works (newest first),
/// and the candidate on offer. A model the user switched away from stays
/// choosable until its retirement date, so "you can switch back" holds, also when
/// they switched because a retiring notice suggested it; one never chosen is not
/// added just because the list has it.
public func modelPickerChoices(inUse: SopModelProfile?, offered: SopModelProfile?,
                               chosen: [String], listed: [ListedModel], now: Date) -> [ModelChoice] {
    var out = SOP_MODELS.map { ModelChoice.builtIn($0.id) }
    func add(_ c: ModelChoice) { if !out.contains(where: { $0.id == c.id }) { out.append(c) } }
    if let inUse { add(.discovered(inUse)) }
    let earlier = listed.filter { chosen.contains($0.id) && $0.stillWorks(at: now) && $0.profile.isUsable }
        .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    for m in earlier { add(ModelChoice(m.profile)) }
    if let offered { add(ModelChoice(offered)) }
    return out
}

/// The cached listing plus the daily throttle, persisted by the app between launches.
public struct ModelDiscoveryState: Codable, Sendable, Equatable {
    public var listed: [ListedModel] = []
    /// Whether `listed` covered every page of the last listing.
    public var complete = false
    public var checkedAt: Date?
    public var nextCheckAt: Date?
    /// The built-in models of the build that fetched `listed` (`builtInSignature`).
    /// A listing taken before this build's default model existed would call that
    /// model missing, so a listing from another set of built-ins is not used.
    public var listedFor: String?
    /// Offers hidden from the AI SOP panel with "Not now", by `ModelOffer.dismissKey`.
    public var dismissed: [String] = []
    /// Discovered models the user has chosen, oldest first, at most `chosenLimit`.
    /// Each stays in the picker while the listing still shows it as compatible.
    public var chosen: [String] = []

    public static let successInterval: TimeInterval = 24 * 3600
    /// A failed check is retried sooner, but not on every launch.
    public static let failureInterval: TimeInterval = 6 * 3600
    public static let chosenLimit = 5
    public static var builtInSignature: String { SOP_MODELS.map(\.id.rawValue).joined(separator: ",") }

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
        listedFor = Self.builtInSignature
    }

    /// Drop the listing and its schedule, so the next trigger lists again. For a
    /// change of credential: another account can see other models. "Not now"
    /// choices and the models chosen before are kept.
    public mutating func forgetListing() {
        listed = []
        complete = false
        checkedAt = nil
        nextCheckAt = nil
        listedFor = nil
    }

    public mutating func noteChosen(_ id: String) {
        chosen.removeAll { $0 == id }
        chosen.append(id)
        if chosen.count > Self.chosenLimit { chosen.removeFirst(chosen.count - Self.chosenLimit) }
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
    /// at most one extra check. The listing and its schedule are one unit: a
    /// listing this build cannot read (a field added or renamed since it was
    /// stored), or one taken by a build with other built-in models, is read as
    /// never checked, so the next trigger lists again instead of the old schedule
    /// keeping it silent or the old listing calling this build's default missing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dismissed = (try? c.decode([String].self, forKey: .dismissed)) ?? []
        chosen = (try? c.decode([String].self, forKey: .chosen)) ?? []
        // No listing held (never succeeded, or forgotten): the schedule is a
        // failure backoff and nothing can be called missing, so it is kept. A
        // check that keeps failing must not run again on every launch.
        let empty = !c.contains(.listed) || ((try? c.decode([ListedModel].self, forKey: .listed))?.isEmpty ?? false)
        if empty {
            checkedAt = try? c.decodeIfPresent(Date.self, forKey: .checkedAt)
            nextCheckAt = try? c.decodeIfPresent(Date.self, forKey: .nextCheckAt)
            return
        }
        guard let models = try? c.decode([ListedModel].self, forKey: .listed),
              let signature = try? c.decode(String.self, forKey: .listedFor),
              signature == Self.builtInSignature else { return }
        listed = models
        listedFor = signature
        complete = (try? c.decode(Bool.self, forKey: .complete)) ?? false
        checkedAt = try? c.decodeIfPresent(Date.self, forKey: .checkedAt)
        nextCheckAt = try? c.decodeIfPresent(Date.self, forKey: .nextCheckAt)
    }
}
