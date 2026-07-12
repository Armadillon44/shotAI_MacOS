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
    /// USD per 1M input/output tokens — feeds the pre-send cost estimate.
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    /// Output cap for the (streamed) generation request (thinking draws from it too).
    public let maxTokens: Int
}

public let MODEL_PARAMS: [SopModelId: ModelParams] = [
    .sonnet5: ModelParams(
        adaptiveThinking: true,
        supportsEffort: true,
        inputPerMTok: 3,
        outputPerMTok: 15,
        // Generous cap (streamed) so long SOPs don't truncate.
        maxTokens: 32000),
]

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
