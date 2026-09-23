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

        // Review before anything lands, then recover: at most one full retry for
        // a numbering fault and one repair turn for content faults, so a run is
        // never more than three requests. See SopValidation.swift.
        var plan = Self.plan(from: try await client.streamEditPlan(credential: cred, body: body, onProgress: onProgress))
        var review = reviewPlan(plan, against: manifest)
        var retried = false, repaired = false

        // 1. Numbering. An invalid or repeated number means none of the numbers
        //    can be trusted, so nothing is applied partially: run it again once.
        if review.misnumbered {
            Log.sop.error("""
                generation misnumbered — invalid \(review.invalidNumbers, privacy: .public), \
                duplicate \(review.duplicateNumbers, privacy: .public), expected \(review.shotNumbers, privacy: .public); retrying
                """)
            onProgress(.retrying)
            plan = Self.plan(from: try await client.streamEditPlan(credential: cred, body: body, onProgress: onProgress))
            review = reviewPlan(plan, against: manifest)
            retried = true
            if review.misnumbered {
                Log.sop.error("generation misnumbered twice — nothing applied")
                throw ClaudeError.incomplete(wroteNothing: false)
            }
        }

        // 2. Content. Ask again for ONLY the steps that came back missing, empty
        //    or as filler, showing the model its own previous answer so the new
        //    text fits the rest. The image prefix is prompt-cached, so this is
        //    cheap. A failed repair must not cost the steps that already came
        //    back good, so only a cancel propagates.
        let needRepair = review.faultedNumbers
        if !needRepair.isEmpty {
            onProgress(.repairing(steps: needRepair.count))
            do {
                let fixed = Self.plan(from: try await client.streamEditPlan(
                    credential: cred, body: Self.repairBody(body, previous: plan, steps: needRepair),
                    onProgress: onProgress))
                plan = mergeRepairs(into: plan, from: fixed, steps: needRepair)
                review = reviewPlan(plan, against: manifest)
                repaired = true
            } catch {
                if Task.isCancelled { throw error }
                Log.sop.error("repair failed [\(String(describing: (error as? ClaudeError)?.kind), privacy: .public)]; applying what passed")
            }
        }

        // 3. Nothing usable anywhere is still a failure, not an empty success.
        guard review.landsSomething else {
            Log.sop.error("generation unusable — no screenshot received usable text")
            throw ClaudeError.incomplete(wroteNothing: true)
        }

        let numbered = numberedBase(manifest)
        let idAt = Dictionary(numbered.map { ($0.number, $0.step.id) }, uniquingKeysWith: { a, _ in a })
        plan = sanitize(plan, review)
        plan.incompleteStepIds = review.faultedNumbers.compactMap { idAt[$0] }
        Log.sop.notice("""
            generation ok — shots \(review.shotNumbers.count, privacy: .public), \
            complete \(review.cleanCount, privacy: .public), retried \(retried, privacy: .public), \
            repaired \(repaired, privacy: .public), title \(review.titleUsable, privacy: .public), \
            intro \(review.introUsable, privacy: .public)
            """)
        onProgress(.done)
        // Bound against the same manifest the request was assembled from, so
        // apply can find each edit's step by id even if the project changed
        // while the request was in flight.
        plan.boundStepIds = stepNumberBinding(manifest)
        return plan
    }

    static func plan(from raw: SopEditRaw) -> SopEditPlan {
        SopEditPlan(
            title: raw.title,
            intro: raw.intro.map { SopIntro(heading: $0.heading, body: $0.body) },
            steps: raw.steps.map {
                SopStepEdit(stepNumber: $0.stepNumber, caption: $0.caption, body: $0.body,
                            sectionHeading: $0.sectionHeading, sectionBody: $0.sectionBody)
            })
    }

    /// The original request plus two turns: the model's own previous answer, and
    /// a request to rewrite only the listed steps.
    ///
    /// The ask names no bad values and says nothing about WHY these steps need
    /// another pass. Naming "placeholder" to the model is how it came back as a
    /// title and then as an overview (#113), and the model does not need the
    /// reason to write the step.
    static func repairBody(_ body: [String: Any], previous: SopEditPlan, steps: [Int]) -> [String: Any] {
        var out = body
        var messages = body["messages"] as? [[String: Any]] ?? []
        messages.append(["role": "assistant", "content": [["type": "text", "text": planJSON(previous)]]])
        let list = steps.map { "Screenshot step \($0)" }.joined(separator: ", ")
        messages.append(["role": "user", "content": [["type": "text", "text":
            "These screenshot steps still need their text: \(list). For each one, write the `caption` "
            + "and `body` from what its screenshot and metadata show, following all of the same "
            + "instructions as before. Return the edit plan with entries for ONLY those steps, each "
            + "`stepNumber` exactly as listed, and keep `title` and `intro` as they were in your previous answer."]]])
        out["messages"] = messages
        return out
    }

    /// The plan as the model wrote it, in the schema's own field order.
    static func planJSON(_ p: SopEditPlan) -> String {
        let steps: [Any] = p.steps.map {
            OrderedObject([
                "stepNumber": $0.stepNumber, "caption": $0.caption, "body": $0.body,
                "sectionHeading": $0.sectionHeading as Any? ?? NSNull(),
                "sectionBody": $0.sectionBody as Any? ?? NSNull(),
            ])
        }
        let intro: Any = p.intro.map { OrderedObject(["heading": $0.heading, "body": $0.body]) } ?? NSNull()
        let obj = OrderedObject(["title": p.title as Any? ?? "", "intro": intro, "steps": steps])
        return (try? RequestJSON.data(obj)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
