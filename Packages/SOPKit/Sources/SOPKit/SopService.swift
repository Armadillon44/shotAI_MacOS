import Foundation
import ShotModel

/// Pre-send cost estimate for the review screen.
public struct SopEstimate: Sendable, Equatable {
    public let inputTokens: Int
    public let model: SopModelId
    /// Estimated total USD (exact input + a rough output allowance).
    public let estCostUsd: Double
}

/// High-level SOP operations: validate access, estimate cost, and generate the
/// inline edit plan. Storage-agnostic — it returns a `SopEditPlan` that the app
/// applies via `ProjectStore.applySopEdits`.
///
/// The credential is resolved just-in-time per call and never returns to the
/// caller. Resolution is late on purpose: a federated token lives ~10 minutes,
/// so binding one at construction would hand every later call an expired token.
public struct SopService: Sendable {
    let client: ClaudeClient
    let credentials: CredentialProvider

    public init(client: ClaudeClient = ClaudeClient(), credentials: CredentialProvider) {
        self.client = client
        self.credentials = credentials
    }

    /// Bring-your-own-key construction. Kept so the API-key path (and every
    /// existing test) works unchanged when federation is not configured.
    public init(client: ClaudeClient = ClaudeClient(), keyStore: ApiKeyStore = KeychainApiKeyStore()) {
        self.init(client: client, credentials: StoredKeyCredentialProvider(keyStore: keyStore))
    }

    /// Resolve a credential, mapping "nothing available" to the right guidance.
    private func credential() async throws -> ClaudeCredential {
        try await credentials.credential()
    }

    /// UI-safe snapshot of how (or whether) requests can currently be made.
    public func credentialStatus() async -> CredentialStatus { await credentials.status() }

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
        try await client.checkModel(credential: try await credential(), model: settings.model)
        return settings.model
    }

    /// Estimate input tokens + cost for generating this project's SOP.
    public func estimate(dir: String, manifest: ProjectManifest, settings: SopSettings) async throws -> SopEstimate {
        guard settings.enabled else { throw ClaudeError.disabled }
        let cred = try await credential()
        let assembled = try assembleRequest(dir: dir, manifest: manifest, settings: settings)
        let inputTokens = try await client.countTokens(
            credential: cred, model: settings.model, system: assembled.system, messages: assembled.messages)
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
        // Resolved BEFORE the (slow) request assembly so an expired session
        // fails fast, instead of after flattening every screenshot.
        let cred = try await credential()
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

        let raw = try await client.streamEditPlan(credential: cred, body: body, onProgress: onProgress)
        let plan = SopEditPlan(
            title: raw.title,
            intro: raw.intro.map { SopIntro(heading: $0.heading, body: $0.body) },
            steps: raw.steps.map {
                SopStepEdit(stepNumber: $0.stepNumber, caption: $0.caption, body: $0.body,
                            sectionHeading: $0.sectionHeading, sectionBody: $0.sectionBody)
            })
        // A project always has shot steps here (the assembler throws otherwise),
        // so a plan that will not change a single one of them means the run
        // produced nothing usable. Fail loudly instead of silently applying only
        // an intro — the caller must NOT snapshot/apply a no-op result.
        //
        // This checks what will LAND, not merely what was written. Checking the
        // plan alone missed the case actually reported as "it returned only an
        // overview": a plan full of well-written steps whose `stepNumber`s match
        // no real step passes a content-only test, applies to nothing, and the
        // user gets a new title and overview with no error at all.
        //
        // The numbers must line up with `applySopEdits`, which indexes the
        // non-AI-inserted steps and counts author text blocks — so the only
        // screenshot in a two-item project is "Screenshot step 2", not 1.
        let base = manifest.steps.filter { $0.aiInserted != true }
        let shotNumbers = Set(base.enumerated().compactMap { i, s in s.kind == .text ? nil : i + 1 })
        let willEditAStep = plan.steps.contains {
            shotNumbers.contains($0.stepNumber)
                && (!$0.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if !willEditAStep {
            // Distinguish the two failures in the log: "wrote nothing" and "wrote
            // for steps that do not exist" have different causes and different
            // fixes, and the user-facing message cannot tell them apart.
            let wroteSomething = plan.steps.contains {
                !$0.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let got = plan.steps.map(\.stepNumber).sorted()
            Log.sop.error("""
                generation unusable — \(wroteSomething ? "stepNumbers matched no step" : "no step content", privacy: .public). \
                plan numbers \(String(describing: got), privacy: .public), \
                expected any of \(String(describing: shotNumbers.sorted()), privacy: .public)
                """)
            throw ClaudeError.incomplete(wroteNothing: !wroteSomething)
        }
        onProgress(.done)
        return plan
    }
}
