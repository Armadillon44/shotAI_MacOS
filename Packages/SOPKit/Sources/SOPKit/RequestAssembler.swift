import Foundation
import ShotModel

/// The system + user-message content for a project, ready to serialize. Built
/// once and shared by the estimate (count_tokens) and generate paths.
struct AssembledRequest {
    let system: [[String: Any]]
    let messages: [[String: Any]]
}

extension AssembledRequest {
    /// Human-readable label for an author-written text block, by callout kind.
    static func authorBlockLabel(_ callout: CalloutKind?) -> String {
        switch callout {
        case .note: "Note callout"
        case .caution: "Caution callout"
        case .warning: "Warning callout"
        case .section: "Section heading"
        case nil: "Text step"
        }
    }

    /// What Claude should DO about each kind, since "leave it alone" alone does
    /// not tell it how the block relates to the steps around it.
    static func authorBlockGuidance(_ callout: CalloutKind?) -> String? {
        switch callout {
        case .note, .caution, .warning:
            "(The author highlighted this, so it is something they know about the process that "
                + "the screenshots do not show. Let it inform the steps around it — reference or "
                + "account for it where a reader would need to. Do not restate it wholesale as "
                + "step text (it is already shown to the reader), and never contradict it.)"
        case .section:
            "(A NON-NUMBERED phase heading the author placed to group the steps that follow. It "
                + "tells you how they think the procedure divides up — use that structure rather "
                + "than inventing your own, keep step wording consistent with the phase it sits "
                + "in, and do not add a sectionHeading of your own where this already marks the "
                + "boundary.)"
        case nil: nil
        }
    }
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

    // The author's Overview, when they wrote one. `intro` is in the OUTPUT schema,
    // so Claude writes one every time — but it was never sent as INPUT, which
    // meant a user who described the goal of their procedure had it silently
    // replaced by a version written without ever seeing it. Their statement of
    // intent is the single most useful piece of context for every other step.
    let authorIntro: String? = {
        guard let i = manifest.intro else { return nil }
        let h = i.heading.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = i.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(h.isEmpty && b.isEmpty) else { return nil }
        return [h.isEmpty ? nil : "Heading: \(h)", b.isEmpty ? nil : "Body: \(b)"]
            .compactMap { $0 }.joined(separator: "\n")
    }()

    var header = ""
    // Built in pieces: as one expression this exceeded the type-checker's budget.
    // The current name is quoted and kept on its own line, away from any word
    // describing it. It previously read "(usually an auto-generated placeholder
    // such as a date/time stamp): <title>", which put "placeholder" directly
    // beside the value in the one sentence about what a title is — and Claude
    // returned "placeholder" as the title. Describe the name AFTER stating it,
    // and forbid generic answers outright.
    header += "Current project name: \"\(manifest.title)\"\n"
    header += "That name is almost always auto-generated (typically just a date and time) "
    header += "and is not part of the content. You MUST set `title` to a clear, specific "
    header += "name for the PROCEDURE ITSELF, derived from what the steps accomplish — for "
    header += "example \"Configuring VPN access in the admin console\". Keep the current name "
    header += "only if it already reads as a real, descriptive procedure title. Never return "
    header += "a generic or filler title such as \"placeholder\", \"untitled\", \"SOP\" or "
    header += "\"Project\"; if the steps are sparse, still name the specific task they show.\n"
    header += "The \(source.count) steps below are in order. Write one edit-plan entry per "
    header += "SCREENSHOT step, setting its stepNumber to that step's number. Keep the "
    header += "screenshots in this order. Redactions are already baked into the images — "
    header += "never describe or guess at blurred/obscured areas."
    if let authorIntro {
        header += "\n\n--- The author already wrote this overview ---\n"
        header += authorIntro
        header += "\n\nTreat this as AUTHORITATIVE CONTEXT, not as text to protect. It states "
        header += "intent, audience, scope or constraints that the screenshots cannot show you, "
        header += "and it is the author's own knowledge of the process. Let it inform the whole "
        header += "guide: your `intro` and the wording and emphasis of every step. You may "
        header += "rewrite it freely for clarity, structure and tone — write the best overview "
        header += "you can. What you must not do is CONTRADICT or SILENTLY DROP the facts and "
        header += "constraints it states; those are things the author knows and you do not."
    }

    var content: [[String: Any]] = [["type": "text", "text": header]]

    for (idx, step) in source.enumerated() {
        let n = idx + 1
        if step.kind == .text {
            // The KIND matters. note/caution/warning/section are all text steps
            // distinguished by `callout`, and sending them identically meant a red
            // warning, a phase divider and an ordinary paragraph reached Claude as
            // the same thing. It was told to leave them alone but had no idea what
            // role each played — so it could not avoid duplicating a warning it
            // could not see was a warning, or place its own section headings
            // around a structure it could not see existed.
            var parts = ["--- \(AssembledRequest.authorBlockLabel(step.callout)) \(n) (author-written — leave this content alone) ---"]
            if let h = step.heading, !h.isEmpty { parts.append("Heading: \(h)") }
            if let b = step.body, !b.isEmpty { parts.append("Body: \(b)") }
            if let guidance = AssembledRequest.authorBlockGuidance(step.callout) { parts.append(guidance) }
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
            throw ClaudeError.api(status: 0, failure: ApiFailure(message: "Step \(n)'s image could not be read."))
        }
        content.append([
            "type": "image",
            "source": ["type": "base64", "media_type": render.mediaType.rawValue, "data": bytes.base64EncodedString()],
        ])

        let orig = originalById[step.id]
        // Prefer the pre-AI original so Claude is never fed its own prior
        // rewrites (successive regenerations would compound). The exception is a
        // caption the AUTHOR edited after a generation: that is a deliberate
        // human correction and is exactly what should be rewritten from (#73).
        let caption = step.captionEditedByUser == true ? step.caption : (orig?.caption ?? step.caption)
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
