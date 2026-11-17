import Foundation
import ShotModel

// Per-model request shaping + pricing, and the per-tone system-prompt modifier.
// Ported from shotAI-original/src/main/claude-models.ts. Single source for what
// shapes the API request, so a bad/unsupported id can never reach the wire.

public struct ModelParams: Sendable {
    /// Whether to send `thinking: {type:"adaptive"}` (nil = omit the param).
    public let adaptiveThinking: Bool
    /// Whether this model accepts `output_config.effort` (level comes from settings).
    public let supportsEffort: Bool
    /// USD per 1M input/output tokens — feeds the pre-send cost estimate. nil for a
    /// model found by discovery: the Models API publishes no prices, so its
    /// estimate shows tokens only rather than a figure shotAI would be guessing.
    public let inputPerMTok: Double?
    public let outputPerMTok: Double?
    /// Output cap for the (streamed) generation request (thinking draws from it too).
    public let maxTokens: Int
    /// Ask the API to rerun a policy-declined request on the model's fallback
    /// (`fallbacks: "default"`, beta `server-side-fallback-2026-07-01`).
    public let serverSideFallback: Bool
}

public let MODEL_PARAMS: [SopModelId: ModelParams] = [
    .sonnet55: ModelParams(
        // Claude Sonnet 5.5 (Anthropic API reference, 2026-11): adaptive thinking,
        // effort low…max (levels recalibrated from Sonnet 5), same tokenizer.
        adaptiveThinking: true,
        supportsEffort: true,
        // Same list price as Sonnet 5; only cache reads are cheaper ($0.10), and
        // the estimate does not model caching.
        inputPerMTok: 2,
        outputPerMTok: 10,
        // Thinking counts against this as well as the plan. 64K is the migration
        // guide's starting point for Sonnet 5.5 (up from 32K); streamed, and only
        // what is actually generated is billed.
        maxTokens: SOP_GENERATION_MAX_TOKENS,
        // A `cyber` or `frontier_llm` decline is rerun on Sonnet 5 on the same
        // stream. IT procedures — firewalls, MFA resets, admin consoles — are exactly
        // the benign work that can trip the cyber classifier. `bio`,
        // `reasoning_extraction` and `general_harms` declines are not rerun and
        // still surface as a refusal.
        serverSideFallback: true),
]

extension SopModelProfile {
    /// The request shape for a discovered model. Adaptive thinking, effort,
    /// structured output and image input are not stored: a model is only offered
    /// when the model list says it supports all four (`ListedModel.sopGaps`).
    public var params: ModelParams {
        ModelParams(
            adaptiveThinking: true,
            supportsEffort: true,
            inputPerMTok: nil,
            outputPerMTok: nil,
            maxTokens: min(SOP_GENERATION_MAX_TOKENS, maxOutputTokens),
            // Asked for only when the list names a model to fall back to; the
            // parameter on a model without one is a request the API may refuse.
            serverSideFallback: !fallbackModels.isEmpty)
    }
}

/// System-prompt modifier per tone (appended to the base SOP instructions).
public let TONE_PROMPT: [SopTone: String] = [
    .professional:
        "Write in a formal, professional register suitable for a corporate Standard Operating Procedure. Use clear, third-person imperative instructions.",
    .friendly:
        "Write in a warm, approachable, second-person voice (\"you\") as if guiding a colleague through the task, while staying clear and accurate.",
    .concise:
        "Write as concisely as possible. Use short, action-first instructions and omit unnecessary words and background.",
    .detailed:
        "Write thoroughly. Explain the purpose behind each step and include the context, prerequisites, and cautions a newcomer would need.",
]
