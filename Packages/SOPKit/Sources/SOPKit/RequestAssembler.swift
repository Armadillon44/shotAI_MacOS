import Foundation
import ShotModel

/// The system + user-message content for a project, ready to serialize. Built
/// once and shared by the estimate (count_tokens) and generate paths.
struct AssembledRequest {
    let system: [[String: Any]]
    let messages: [[String: Any]]
}

/// Build the Claude request from a project: a system prompt + one user message
/// interleaving each step's image (the redaction-baked render) and its metadata,
/// with author text steps as prose. REDACTION-ENFORCED: a shot step with an
/// unbaked blur/crop throws (via resolveSendableRender) rather than sending raw
/// pixels. Ported from claude-service.ts assembleRequest.
func assembleRequest(dir: String, manifest: ProjectManifest, settings: SopSettings) throws -> AssembledRequest {
    // Exclude a prior run's inserted text steps — Claude never sees its own
    // inserts, so regeneration doesn't compound and numbering matches applySopEdits.
    let source = manifest.steps.filter { $0.aiInserted != true }
    let shotCount = source.filter { $0.kind != .text }.count
    guard shotCount > 0 else { throw ClaudeError.noScreenshots }

    // Original (pre-AI) caption/note per id — so regeneration always feeds Claude
    // the ground-truth captured text, never its own prior rewrites.
    var originalById: [String: ProjectStep] = [:]
    if let backup = manifest.sopBackup {
        for s in backup.steps { originalById[s.id] = s }
    }

    let system: [[String: Any]] = [["type": "text", "text": buildSystemPrompt(settings: settings)]]

    var content: [[String: Any]] = [[
        "type": "text",
        "text":
            "Current project name (usually an auto-generated placeholder such as a date/time "
            + "stamp): \(manifest.title)\n"
            + "You MUST set `title` to a clear, specific name for the overall procedure, derived "
            + "from what the steps accomplish. Only keep the current name if it already reads as a "
            + "real, descriptive procedure title (it usually does not).\n"
            + "The \(source.count) steps below are in order. Write one edit-plan entry "
            + "per SCREENSHOT step, setting its stepNumber to that step's number. Keep the "
            + "screenshots in this order. Redactions are already baked into the images — never "
            + "describe or guess at blurred/obscured areas.",
    ]]

    for (idx, step) in source.enumerated() {
        let n = idx + 1
        if step.kind == .text {
            var parts = ["--- Text step \(n) (author-written — leave this content alone) ---"]
            if let h = step.heading, !h.isEmpty { parts.append("Heading: \(h)") }
            if let b = step.body, !b.isEmpty { parts.append("Body: \(b)") }
            content.append(["type": "text", "text": parts.joined(separator: "\n")])
            continue
        }

        // Fail-closed redaction gate (shared with the export path).
        let render: SendableRender
        do {
            render = try resolveSendableRender(dir: dir, step: step, stepLabel: "Step \(n)", verb: "send")
        } catch let e as RenderGateError {
            throw ClaudeError.unbakedRedaction(e.localizedDescription)
        }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: render.abs)) else {
            throw ClaudeError.api(status: 0, message: "Step \(n)'s image could not be read.")
        }
        content.append([
            "type": "image",
            "source": ["type": "base64", "media_type": render.mediaType.rawValue, "data": bytes.base64EncodedString()],
        ])

        let orig = originalById[step.id]
        let caption = orig?.caption ?? step.caption
        let note = orig?.note ?? step.note
        var meta = ["--- Screenshot step \(n) ---"]
        if let app = step.window?.app, !app.isEmpty { meta.append("App: \(app)") }
        if let title = step.window?.title, !title.isEmpty { meta.append("Window: \(title)") }
        if step.element.available, let name = step.element.name, !name.isEmpty {
            meta.append("UI element: \(name)" + (step.element.controlType.map { " (\($0))" } ?? ""))
        }
        if let click = step.click {
            meta.append("Action: \(click.button.rawValue)-click (the colored ring marks where the user clicked)")
        }
        if !caption.isEmpty { meta.append("Auto-caption: \(caption)") }
        if !note.isEmpty { meta.append("User note: \(note)") }
        content.append(["type": "text", "text": meta.joined(separator: "\n")])
    }

    // Cache breakpoint on the last block → caches system + all images + metadata
    // so a regenerate within the TTL reads that large, stable prefix cheaply.
    content.append([
        "type": "text",
        "text": "Now return the inline edit plan as the structured JSON output.",
        "cache_control": ["type": "ephemeral"],
    ])

    return AssembledRequest(system: system, messages: [["role": "user", "content": content]])
}
