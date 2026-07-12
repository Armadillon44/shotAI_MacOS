import Foundation
import ShotModel

/// Pre-send cost estimate for the review screen.
public struct SopEstimate: Sendable, Equatable {
    public let inputTokens: Int
    public let model: SopModelId
    /// Estimated total USD (exact input + a rough output allowance).
    public let estCostUsd: Double
}

/// High-level SOP operations: validate the key, estimate cost, and generate the
/// inline edit plan. Storage-agnostic — it returns a `SopEditPlan` that the app
/// applies via `ProjectStore.applySopEdits`. The API key is read from the store
/// just-in-time and passed to the client; it never returns to the caller.
public struct SopService: Sendable {
    let client: ClaudeClient
    let keyStore: ApiKeyStore

    public init(client: ClaudeClient = ClaudeClient(), keyStore: ApiKeyStore = KeychainApiKeyStore()) {
        self.client = client
        self.keyStore = keyStore
    }

    /// Rough output-token allowance for the estimate (input dominates anyway).
    static let estOutputTokens = 2500

    private func params(_ model: SopModelId) -> ModelParams {
        MODEL_PARAMS[model] ?? ModelParams(adaptiveThinking: true, supportsEffort: true, inputPerMTok: 3, outputPerMTok: 15, maxTokens: 32000)
    }

    /// Validate the configured key + model with a cheap Models API call. Returns
    /// the validated model. Does nothing (throws `.disabled`) when SOP is off.
    @discardableResult
    public func testKey(settings: SopSettings) async throws -> SopModelId {
        guard settings.enabled else { throw ClaudeError.disabled }
        guard let key = keyStore.key() else { throw ClaudeError.noKey }
        try await client.checkModel(apiKey: key, model: settings.model)
        return settings.model
    }

    /// Estimate input tokens + cost for generating this project's SOP.
    public func estimate(dir: String, manifest: ProjectManifest, settings: SopSettings) async throws -> SopEstimate {
        guard settings.enabled else { throw ClaudeError.disabled }
        guard let key = keyStore.key() else { throw ClaudeError.noKey }
        let assembled = try assembleRequest(dir: dir, manifest: manifest, settings: settings)
        let inputTokens = try await client.countTokens(
            apiKey: key, model: settings.model, system: assembled.system, messages: assembled.messages)
        let p = params(settings.model)
        let cost = Double(inputTokens) / 1e6 * p.inputPerMTok
            + Double(Self.estOutputTokens) / 1e6 * p.outputPerMTok
        return SopEstimate(inputTokens: inputTokens, model: settings.model, estCostUsd: cost)
    }

    /// Generate the SOP: stream a vision + structured-output request and return the
    /// validated inline edit plan (the caller applies it via the store). Progress
    /// arrives via `onProgress`.
    public func generate(
        dir: String, manifest: ProjectManifest, settings: SopSettings,
        onProgress: @Sendable (SopProgress) -> Void = { _ in }
    ) async throws -> SopEditPlan {
        guard settings.enabled else { throw ClaudeError.disabled }
        guard let key = keyStore.key() else { throw ClaudeError.noKey }
        onProgress(.preparing)
        let assembled = try assembleRequest(dir: dir, manifest: manifest, settings: settings)
        let p = params(settings.model)

        var outputConfig: [String: Any] = [
            "format": ["type": "json_schema", "schema": sopEditJSONSchema()],
        ]
        if p.supportsEffort { outputConfig["effort"] = settings.effort.rawValue }
        var body: [String: Any] = [
            "model": settings.model.rawValue,
            "max_tokens": p.maxTokens,
            "system": assembled.system,
            "messages": assembled.messages,
            "output_config": outputConfig,
            "stream": true,
        ]
        if p.adaptiveThinking { body["thinking"] = ["type": "adaptive"] }

        let raw = try await client.streamEditPlan(apiKey: key, body: body, onProgress: onProgress)
        let plan = SopEditPlan(
            title: raw.title,
            intro: raw.intro.map { SopIntro(heading: $0.heading, body: $0.body) },
            steps: raw.steps.map {
                SopStepEdit(stepNumber: $0.stepNumber, caption: $0.caption, body: $0.body,
                            note: $0.note, sectionHeading: $0.sectionHeading, sectionBody: $0.sectionBody)
            })
        // A project always has shot steps here (the assembler throws otherwise),
        // so a plan with no actual step instruction means the model under-produced
        // (common at low effort). Fail loudly instead of silently applying only an
        // intro — the caller must NOT snapshot/apply a no-op result.
        let wroteAnyStep = plan.steps.contains {
            !$0.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard wroteAnyStep else { throw ClaudeError.incomplete }
        onProgress(.done)
        return plan
    }
}
