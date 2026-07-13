import AppKit
import ShotModel
import SwiftUI
import UniformTypeIdentifiers

/// The in-app report. Read the step guide, and (R1) edit its words in place:
/// captions, instructions/notes, text steps, callouts, and the overview intro
/// are all click-to-edit. Prefers the flattened render (annotations baked +
/// redaction) over the raw screenshot. Rendering rules live in
/// ShotModel.ReportPresentation, ported from Report.tsx.
struct ReportView: View {
    let opened: ProjectStore.OpenedProject
    /// Open the annotation editor for a shot step (Phase C).
    var onEdit: (ProjectStep) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @Environment(CaptureCoordinator.self) private var capture
    /// True while composing a not-yet-saved overview (an all-empty intro can't
    /// persist — the manifest decoder coerces it to nil — so the placeholder box
    /// is UI-local until the user types something).
    @State private var addingIntro = false
    /// The id of the field currently being edited — a single shared focus across
    /// all inline fields so a background click can dismiss whichever is active.
    @FocusState private var focus: String?
    /// The step pending a delete confirmation, if any.
    @State private var deleteStepTarget: ProjectStep?
    /// A pending immediate window/screen capture — drives the target-picker sheet.
    @State private var immediatePick: ImmediatePick?
    /// A pending "Capture steps here" recording — drives the record sheet.
    @State private var captureStepsAt: InsertIndex?
    /// Drives edge auto-scroll while a step is being dragged.
    @State private var autoScroller = AutoScroller()
    /// Tab-between-fields state + the installed key-down monitor token.
    @State private var tabNav = TabNavigator()
    @State private var tabMonitor: Any?

    private var steps: [ProjectStep] { opened.manifest.steps }
    private var numbers: [String: Int] { ReportPresentation.displayNumbers(for: steps) }

    /// Inline text fields in the order they appear, so Tab / Shift+Tab can walk
    /// them field→field. Must mirror the ids each block assigns (intro heading/body,
    /// then per step: shot = caption/instructions, text = heading/body, callout =
    /// heading/body).
    private var orderedFieldIDs: [String] {
        var ids: [String] = []
        if opened.manifest.intro != nil || addingIntro { ids += ["intro:h", "intro:b"] }
        for step in steps {
            if step.kind == .text {
                ids += step.callout != nil ? ["ch:\(step.id)", "cb:\(step.id)"]
                                           : ["th:\(step.id)", "tb:\(step.id)"]
            } else {
                ids += ["cap:\(step.id)", "body:\(step.id)"]
            }
        }
        return ids
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                sopPanel
                if model.canUndoMerge { undoMergeBanner }
                intro
                ForEach(Array(steps.enumerated()), id: \.element.id) { pair in
                    InsertZone { choice in handleInsert(choice, at: pair.offset) }
                    StepRow(
                        step: pair.element, number: numbers[pair.element.id], projectDir: opened.dir,
                        focus: $focus, index: pair.offset, total: steps.count,
                        canMergeNext: canMergeNext(at: pair.offset), autoScroller: autoScroller,
                        onEdit: onEdit, onRequestDelete: { deleteStepTarget = pair.element }
                    )
                }
                if steps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 29))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 78, height: 78)
                            .background(Circle().fill(Palette.accentTint))
                            .accessibilityHidden(true)
                        Text("No steps yet").font(.system(size: 15, weight: .semibold))
                        Text("Record a process, or add a text block below to start building this guide.")
                            .font(.callout)
                            .foregroundStyle(Palette.ink2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 44)
                }
                InsertZone { choice in handleInsert(choice, at: steps.count) } // append
                    .dropDestination(for: String.self) { ids, _ in
                        guard let dragged = ids.first else { return false }
                        autoScroller.reset()
                        Task { await model.dropStep(dragged, before: nil) } // to the end
                        return true
                    } isTargeted: { autoScroller.noteHover($0) }
            }
            .padding(24)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
            // A click anywhere off a field commits the active edit (macOS text
            // fields don't resign on a dead-space click). Field buttons/fields
            // take gesture priority, so this only fires on empty space + labels.
            // Must live on the content (not the ScrollView's background, which
            // sits behind the content and never receives these taps).
            .contentShape(Rectangle())
            .onTapGesture { focus = nil }
            // Tab-between-fields: keep the navigator in sync with the field order
            // and the active field, and apply its focus-move requests.
            .onChange(of: orderedFieldIDs) { _, v in tabNav.order = v }
            .onChange(of: focus) { _, v in tabNav.focused = v }
            .onChange(of: tabNav.move) { _, m in if let m { focus = m.id } }
            // Resolve the backing NSScrollView so a step drag near the top/bottom
            // edge can auto-scroll (driven per-row via autoScroller.noteHover).
            .background(ScrollProbe { autoScroller.scrollView = $0 })
            // Learn our window so the Tab monitor can ignore sheets / other windows.
            .background(WindowAccessor { tabNav.window = $0 })
            .onAppear {
                tabNav.order = orderedFieldIDs
                tabNav.focused = focus
                if tabMonitor == nil {
                    tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        guard event.keyCode == 48 else { return event }  // 48 = Tab
                        let handled = tabNav.handleTab(
                            backward: event.modifierFlags.contains(.shift), eventWindow: event.window)
                        return handled ? nil : event
                    }
                }
            }
            .onDisappear {
                if let m = tabMonitor { NSEvent.removeMonitor(m); tabMonitor = nil }
            }
        }
        .background(Palette.surface)
        .confirmationDialog(
            "Delete this step?",
            isPresented: Binding(get: { deleteStepTarget != nil }, set: { if !$0 { deleteStepTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let t = deleteStepTarget { Task { await model.deleteStep(id: t.id) } }
                deleteStepTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteStepTarget = nil }
        } message: {
            Text("This removes the step and its screenshot. This can't be undone.")
        }
        .sheet(item: $immediatePick) { pick in
            ImmediateCaptureSheet(
                projectPath: opened.dir, insertAt: pick.index, mode: pick.mode,
                coordinator: capture
            ) { Task { await model.refresh() } } // updatedAt changed → resort list
        }
        .sheet(item: $captureStepsAt) { at in
            RecordSheet(projectPath: opened.dir, coordinator: capture, insertAt: at.value)
        }
        .confirmationDialog(
            "Generate this SOP with Claude?",
            isPresented: Binding(get: { model.sopEstimate != nil }, set: { if !$0 { model.dismissSopEstimate() } }),
            titleVisibility: .visible
        ) {
            Button("Generate") { model.confirmGenerateSop() }
            Button("Cancel", role: .cancel) { model.dismissSopEstimate() }
        } message: {
            if let est = model.sopEstimate {
                Text("Sends your redaction-baked screenshots + text (\(est.inputTokens) input tokens) to Anthropic. Estimated cost ≈ \(Self.usd(est.estCostUsd)). This rewrites every step's caption and instructions — you can revert.")
            }
        }
        .alert(
            "SOP generation failed",
            isPresented: Binding(get: { model.sopError != nil }, set: { if !$0 { model.sopError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.sopError ?? "")
        }
    }

    /// The AI SOP panel at the top of the report: generate / regenerate / revert,
    /// with inline progress. Hidden entirely when AI is disabled in Settings.
    @ViewBuilder private var sopPanel: some View {
        if model.sopSettings.enabled {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Palette.accent)
                    Text("AI SOP").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if model.sopBusy {
                        if let p = model.sopProgress {
                            Text(p).font(.caption).foregroundStyle(Palette.ink2)
                        }
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancelSop() }
                    } else {
                        if model.canRevertSop {
                            Button("Revert AI edits") { Task { await model.revertSop() } }
                        }
                        if model.apiKeyPresent {
                            Button {
                                model.prepareSop()
                            } label: {
                                Label(model.canRevertSop ? "Regenerate" : "Generate SOP", systemImage: "sparkles")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canGenerateSop)
                        } else {
                            SettingsLink { Text("Add API key…") }
                        }
                    }
                }
                if !model.apiKeyPresent {
                    Text("Add your Anthropic API key in Settings ▸ AI, then Claude can turn these screenshots into a step-by-step SOP.")
                        .font(.caption).foregroundStyle(Palette.ink3)
                }
            }
            .padding(14)
            .background(Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .cardElevation()
        }
    }

    /// "$0.04" style — the estimate is small; two decimals is enough.
    private static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }

    /// Merge is offered only for a shot step followed by another shot step (the
    /// click of this step is carried onto the next step's screenshot).
    private func canMergeNext(at index: Int) -> Bool {
        guard index + 1 < steps.count else { return false }
        let cur = steps[index], next = steps[index + 1]
        return cur.kind != .text && next.kind != .text && !next.screenshot.isEmpty
    }

    /// Route an insert-zone choice. Text/callout add immediately. Image opens a
    /// modal open panel (SwiftUI's .fileImporter is unreliable from inside a Menu
    /// action — the menu's event loop swallows it). Area captures right away;
    /// window/screen open a target picker; "Capture steps" starts a recording.
    private func handleInsert(_ choice: InsertChoice, at index: Int) {
        switch choice {
        case .text: Task { await model.addTextStep(atIndex: index) }
        case .callout(let kind): Task { await model.addTextStep(callout: kind, atIndex: index) }
        case .image:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.prompt = "Insert"
            panel.message = "Choose a PNG or JPEG image to insert as a step."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            Task { await model.importImageStep(data: data, atIndex: index) }
        case .captureArea:
            // Classic screenshot: drag out a region and capture it immediately.
            Task {
                _ = await capture.captureAreaNow(projectPath: opened.dir, insertAt: index)
                await model.refresh() // updatedAt changed → resort the Home list
            }
        case .captureWindow:
            immediatePick = ImmediatePick(index: index, mode: .window)
        case .captureScreen:
            immediatePick = ImmediatePick(index: index, mode: .screen)
        case .captureSteps:
            captureStepsAt = InsertIndex(value: index)
        }
    }

    /// One-tap undo shown right after a merge (until the next edit).
    private var undoMergeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward").foregroundStyle(Palette.ink2)
            Text("Steps merged.").font(.callout).foregroundStyle(Palette.ink2)
            Spacer(minLength: 8)
            Button("Undo merge") { Task { await model.undoLastMerge() } }
        }
        .padding(10)
        .background(Palette.surface2)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hair))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(opened.manifest.title)
                .font(.title.bold())
            HStack(spacing: 6) {
                if let created = ContentView.formatDate(opened.manifest.createdAt) {
                    Text("Created \(created)")
                }
                if let updated = ContentView.formatDate(opened.manifest.updatedAt) {
                    Text("· Updated \(updated)")
                }
                Text("· \(numbers.count) numbered step\(numbers.count == 1 ? "" : "s")")
            }
            .font(.callout)
            .foregroundStyle(Palette.ink2)
        }
    }

    /// The overview preamble — editable when present, an "add" affordance when not.
    @ViewBuilder private var intro: some View {
        if let intro = opened.manifest.intro {
            IntroBox(intro: intro, focus: $focus, onRemove: { addingIntro = false; Task { await model.removeIntro() } })
        } else if addingIntro {
            IntroBox(intro: SopIntro(heading: "", body: ""), focus: $focus, onRemove: { addingIntro = false })
        } else {
            Button { addingIntro = true } label: {
                Label("Add overview", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

}

/// An "insert a step here" affordance rendered between steps: a centered ＋
/// flanked by hairlines (-----+-----). Faded but visible at rest; brightens to
/// the accent on hover to signal it's clickable. Clicking opens a menu to insert
/// a text block or a note/caution/warning callout at this position.
/// What an insert zone can add at its position.
private enum InsertChoice {
    case text, image
    case captureArea          // classic drag-a-region screenshot, captured now
    case captureWindow        // pick a window → captured now
    case captureScreen        // pick a screen → captured now
    case captureSteps         // start a recording that inserts here
    case callout(CalloutKind)
}

/// Identifiable wrapper so a manifest insert index can drive a `.sheet(item:)`
/// (0 is a valid index, so a bare `Int?` can't distinguish "insert at 0" from
/// "no sheet").
private struct InsertIndex: Identifiable {
    let value: Int
    var id: Int { value }
}

/// A pending immediate capture that needs a target picker (window or screen).
private struct ImmediatePick: Identifiable {
    let index: Int
    let mode: CaptureMode
    var id: String { "\(mode.rawValue)#\(index)" }
}

private struct InsertZone: View {
    let onInsert: (InsertChoice) -> Void
    @State private var hovering = false

    var body: some View {
        // Full-width row so the flanking lines expand and CENTER the ＋. The
        // lines live outside the Menu (a borderless Menu sizes its label to its
        // content, which would collapse flexible lines to nothing).
        HStack(spacing: 10) {
            line
            Menu {
                Menu("Screenshot") {
                    Button("Capture area…") { onInsert(.captureArea) }
                    Button("Capture a window…") { onInsert(.captureWindow) }
                    Button("Capture the screen…") { onInsert(.captureScreen) }
                }
                Button("Capture steps…") { onInsert(.captureSteps) }
                Button("Image…") { onInsert(.image) }
                Divider()
                Button("Text block") { onInsert(.text) }
                Button("Note") { onInsert(.callout(.note)) }
                Button("Caution") { onInsert(.callout(.caution)) }
                Button("Warning") { onInsert(.callout(.warning)) }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18)) // ~20% larger than before
                    .foregroundStyle(hovering ? Palette.accent : Palette.ink3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            line
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .contentShape(Rectangle())
        .opacity(hovering ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .help("Insert a step here")
    }

    private var line: some View {
        Rectangle()
            .fill(hovering ? Palette.accent.opacity(0.55) : Palette.hair)
            .frame(height: 1)
    }
}

/// SOP overview preamble — a lead-in above the steps, editable in place.
private struct IntroBox: View {
    let intro: SopIntro
    var focus: FocusState<String?>.Binding
    let onRemove: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("OVERVIEW")
                    .font(.system(size: 11, weight: .bold)).kerning(0.6)
                    .foregroundStyle(Palette.ink3)
                Spacer()
                Button("Remove") { onRemove() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            InlineEditable(text: intro.heading, placeholder: "Overview heading…", font: .title3.bold(), id: "intro:h", focus: focus) { new in
                Task { await model.setIntro(heading: new, body: intro.body) }
            }
            InlineEditable(text: intro.body, placeholder: "Describe the overall goal of this guide…", multiline: true, id: "intro:b", focus: focus) { new in
                Task { await model.setIntro(heading: intro.heading, body: new) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.surface2)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.accent).frame(width: 4) }
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Palette.hair) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct StepRow: View {
    let step: ProjectStep
    let number: Int?
    let projectDir: String
    var focus: FocusState<String?>.Binding
    let index: Int
    let total: Int
    let canMergeNext: Bool
    let autoScroller: AutoScroller
    let onEdit: (ProjectStep) -> Void
    let onRequestDelete: () -> Void
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            rail
            VStack(alignment: .leading, spacing: 8) {
                if step.kind == .text {
                    if let callout = step.callout {
                        CalloutBox(step: step, kind: callout, focus: focus)
                    } else {
                        textBlock
                    }
                } else {
                    shotBlock
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            stepMenu
        }
        .padding(.vertical, 6)
        // A dragged step dropped on this row lands just before it; the accent
        // line shows where it will go.
        .overlay(alignment: .top) {
            if dropTargeted { Rectangle().fill(Palette.accent).frame(height: 2) }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let dragged = ids.first, dragged != step.id else { return false }
            autoScroller.reset()
            Task { await model.dropStep(dragged, before: step.id) }
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
            autoScroller.noteHover(targeted) // runs edge auto-scroll while a drag is active
        }
    }

    /// Per-step actions: reorder (move up/down) and delete.
    private var stepMenu: some View {
        Menu {
            Button("Move up") { Task { await model.moveStep(id: step.id, by: -1) } }
                .disabled(index == 0)
            Button("Move down") { Task { await model.moveStep(id: step.id, by: 1) } }
                .disabled(index >= total - 1)
            if canMergeNext {
                Button("Merge into next step") { Task { await model.mergeIntoNext(id: step.id) } }
            }
            // Convert a text step to/from a callout. Callouts aren't numbered, so
            // the remaining steps renumber automatically after the change.
            if step.kind == .text {
                Divider()
                if step.callout == nil {
                    Menu("Convert to callout") {
                        ForEach(CalloutKind.allCases, id: \.self) { kind in
                            Button(kind.rawValue.capitalized) {
                                Task { await model.setStepCallout(stepId: step.id, to: kind) }
                            }
                        }
                    }
                } else {
                    Button("Convert to plain text") {
                        Task { await model.setStepCallout(stepId: step.id, to: nil) }
                    }
                }
            }
            Divider()
            Button("Delete step", role: .destructive) { onRequestDelete() }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Palette.ink3)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Step actions")
    }

    /// Left rail: a drag grip (reorder any step, callouts included) over the
    /// step number for numbered steps, or a type glyph for callouts.
    private var rail: some View {
        VStack(spacing: 6) {
            badge // number/glyph on top, aligned with the step's first line
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink3)
                .help("Drag to reorder")
                .draggable(step.id) {
                    Text(dragPreview)
                        .font(.callout)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.accentTint)
                        .foregroundStyle(Palette.accentInk)
                        .clipShape(Capsule())
                }
        }
    }

    /// A short label for the drag preview.
    private var dragPreview: String {
        if ReportPresentation.isCalloutStep(step) { return step.callout?.rawValue.capitalized ?? "Callout" }
        return number.map { "Step \($0)" } ?? "Step"
    }

    /// The "App — Title" context line under a screenshot. Tolerates either half
    /// being empty (immediate window captures carry a title but no app name) and
    /// collapses to nil when both are blank, so no stray "—" ever shows.
    private func windowLine(_ window: CapturedWindow) -> String? {
        switch (window.app.isEmpty, window.title.isEmpty) {
        case (true, true): return nil
        case (false, true): return window.app
        case (true, false): return window.title
        case (false, false): return "\(window.app) — \(window.title)"
        }
    }

    @ViewBuilder private var badge: some View {
        if let callout = step.callout, ReportPresentation.isCalloutStep(step) {
            Text(ReportPresentation.calloutGlyph(callout))
                .font(.system(size: 15))
                .frame(width: 32, height: 32)
                .background(CalloutBox.palette(callout).background)
                .clipShape(Circle())
                .overlay(Circle().stroke(CalloutBox.palette(callout).border))
        } else if let number {
            NumberBadge(number: number, stepId: step.id, focus: focus) { pos in
                Task { await model.moveStep(id: step.id, toPosition: pos) }
            }
        } else {
            // Defensive: a non-callout step should always have a number.
            Circle().fill(Palette.hair2).frame(width: 32, height: 32)
        }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            InlineEditable(text: step.heading ?? "", placeholder: "Heading (optional)", font: .title3.bold(), id: "th:\(step.id)", focus: focus) { new in
                Task { await model.editStepText(stepId: step.id, heading: new) }
            }
            InlineEditable(text: step.body ?? "", placeholder: "Empty — click to add text.", multiline: true, id: "tb:\(step.id)", focus: focus) { new in
                Task { await model.editStepText(stepId: step.id, body: new) }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var shotBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            InlineEditable(text: step.caption, placeholder: "Add a caption…", font: .headline, id: "cap:\(step.id)", focus: focus) { new in
                Task { await model.editStepText(stepId: step.id, caption: new) }
            }
            Button("Edit", systemImage: "pencil") { onEdit(step) }
                .buttonStyle(.borderless)
                .help("Annotate, redact, or crop this step")
                .fixedSize()
        }
        if let rel = ReportPresentation.displayImagePath(for: step) {
            // Force a fresh figure (new @State → reload) whenever the render
            // revision or path changes, so a re-saved redaction refreshes in
            // place instead of showing the cached image until reopen.
            StepFigure(
                step: step, projectDir: projectDir, relPath: rel,
                onZoom: { z in Task { await model.setReportZoom(stepId: step.id, z) } },
                onReframe: { px, py in Task { await model.setReportPan(stepId: step.id, panX: px, panY: py) } }
            )
            .id("\(step.id)#\(step.renderRev ?? 0)#\(rel)")
        }
        InlineEditable(text: step.body ?? "", placeholder: "+ Add instructions", multiline: true, id: "body:\(step.id)", focus: focus) { new in
            Task { await model.editStepText(stepId: step.id, body: new) }
        }
        // Capture steps show only caption + instruction now — the legacy `note`
        // section was removed (parity with the Windows app). The `note` field
        // still round-trips in the manifest; it's just no longer displayed.
        if let window = step.window, let line = windowLine(window) {
            Text(line)
                .font(.caption)
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
        }
        // Auto-suggest merging a right-click (which likely opened a menu) into
        // the next step (which captured the menu + selection).
        if step.click?.button == .right, canMergeNext {
            mergeSuggestBanner
        }
    }

    private var mergeSuggestBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(Palette.accentInk)
            Text("This right-click likely opened a menu — merge it into the next step.")
                .font(.callout)
                .foregroundStyle(Palette.accentInk)
            Spacer(minLength: 8)
            Button("Merge ↓") { Task { await model.mergeIntoNext(id: step.id) } }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(Palette.accentTint)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.accent.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A text step styled as a tinted note/caution/warning box, editable in place.
private struct CalloutBox: View {
    let step: ProjectStep
    let kind: CalloutKind
    var focus: FocusState<String?>.Binding
    @Environment(AppModel.self) private var model

    struct Colors {
        let background: Color
        let border: Color
        let text: Color
    }

    static func palette(_ kind: CalloutKind) -> Colors {
        switch kind {
        case .note:
            Colors(background: Palette.noteBg, border: Palette.noteBd, text: Palette.noteFg)
        case .caution:
            Colors(background: Palette.cautBg, border: Palette.cautBd, text: Palette.cautFg)
        case .warning:
            Colors(background: Palette.warnBg, border: Palette.warnBd, text: Palette.warnFg)
        }
    }

    var body: some View {
        let palette = Self.palette(kind)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                InlineEditable(text: step.heading ?? "", placeholder: "Heading (optional)", font: .headline, color: palette.text, id: "ch:\(step.id)", focus: focus) { new in
                    Task { await model.editStepText(stepId: step.id, heading: new) }
                }
                Spacer(minLength: 8)
                Menu {
                    ForEach(CalloutKind.allCases, id: \.self) { k in
                        Button(k.rawValue.capitalized) { Task { await model.editStepText(stepId: step.id, callout: k) } }
                    }
                } label: {
                    Text(ReportPresentation.calloutGlyph(kind)).foregroundStyle(palette.text)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change callout type")
            }
            InlineEditable(text: step.body ?? "", placeholder: "Callout text…", color: palette.text, multiline: true, id: "cb:\(step.id)", focus: focus) { new in
                Task { await model.editStepText(stepId: step.id, body: new) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(palette.background)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A click-to-edit text field: shows the value (or an italic placeholder) until
/// clicked, then an inline text field. Commits automatically **on losing focus**
/// (and on Enter for single-line); Esc discards. No Save/Cancel buttons; only
/// writes when the value changed.
///
/// Drives Tab / Shift+Tab between the report's inline text fields. A key-down
/// monitor (installed by ReportView) intercepts Tab reliably regardless of how
/// the current field was focused (mouse click OR keyboard) — SwiftUI's
/// `.onKeyPress(.tab)` only fires for keyboard-reached fields, so it can't be
/// used here. The monitor is scoped to the report's own window and only acts
/// while an inline field is being edited; it publishes the requested target into
/// `move`, which ReportView applies to the shared FocusState.
@Observable final class TabNavigator {
    /// Inline field ids in visual order (kept in sync by ReportView).
    var order: [String] = []
    /// The id of the field currently being edited, or nil.
    var focused: String?
    /// The report's window — the monitor ignores Tab in any other window/sheet.
    weak var window: NSWindow?
    /// Set by the monitor; observed by ReportView to move focus. The token makes
    /// each request a distinct value even when the target id repeats.
    var move: Move?
    struct Move: Equatable { var id: String?; var token: Int }
    private var token = 0

    /// Handle a Tab key-down. Returns true (consume the event) only when an inline
    /// field in this report's window is being edited; otherwise the event passes
    /// through so Tab keeps working everywhere else.
    func handleTab(backward: Bool, eventWindow: NSWindow?) -> Bool {
        guard let window, eventWindow === window else { return false }
        guard let current = focused, let i = order.firstIndex(of: current) else { return false }
        let j = backward ? i - 1 : i + 1
        token += 1
        move = Move(id: order.indices.contains(j) ? order[j] : nil, token: token)
        return true
    }
}

/// Reports the hosting NSWindow up to SwiftUI (so the Tab monitor can scope
/// itself to the report window and ignore sheets / the Settings window).
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onResolve(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

/// Focus is driven by a SHARED `FocusState` (`focus`) keyed by this field's `id`
/// so a background click in the report can dismiss whichever field is active
/// (a plain macOS text field doesn't resign first responder on a dead-space
/// click). Focus is taken on the next runloop tick — setting it synchronously as
/// the field first appears misses (the view isn't in the responder chain yet),
/// which is why a first click previously needed a second click to activate.
///
/// Tab / Shift+Tab move to the next / previous inline text field (in `reportFieldOrder`)
/// rather than to the next macOS control, so editing flows field-to-field like a
/// form. The target enters edit mode via the focus watcher below.
struct InlineEditable: View {
    let text: String
    var placeholder: String
    var font: Font = .body
    var color: Color = Palette.ink
    var multiline: Bool = false
    let id: String
    var focus: FocusState<String?>.Binding
    var onCommit: (String) -> Void

    @State private var draft = ""

    private var active: Bool { focus.wrappedValue == id }

    var body: some View {
        Group {
            if multiline {
                TextField(placeholder, text: $draft, axis: .vertical).lineLimit(1...12)
            } else {
                TextField(placeholder, text: $draft)
            }
        }
        // Plain style so an unfocused field reads as ordinary text; the active one
        // gets a subtle tint + accent ring. The field is ALWAYS a real TextField
        // (never a Button) so it always claims `id` in the shared FocusState — which
        // is what lets Tab move focus into it (a click OR the key monitor).
        .textFieldStyle(.plain)
        .font(font)
        .foregroundStyle(color)
        .focused(focus, equals: id)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(active ? Palette.surface2 : .clear)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(active ? Palette.accent.opacity(0.5) : .clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // Return commits; Shift+Return inserts a newline in multi-line fields.
        .onKeyPress(.return, phases: .down) { key in
            if multiline && key.modifiers.contains(.shift) { return .ignored }
            focus.wrappedValue = nil
            return .handled
        }
        .onExitCommand { draft = text; focus.wrappedValue = nil }  // Esc discards edits
        .onChange(of: focus.wrappedValue) { _, current in
            if current != id { commit() }  // lost focus (blur / another field / Tab / Esc) → save
        }
        .onChange(of: text) { _, newText in
            if !active { draft = newText }  // reflect store updates while not being edited
        }
        .onAppear { draft = text }
    }

    private func commit() {
        if draft != text { onCommit(draft) } // skip a write when nothing changed
    }
}

/// The step-number badge. Click it to type a new position; on commit the step
/// moves there and every step renumbers in turn. Uses the report's shared focus
/// (like the inline text fields) so a click elsewhere commits it. Esc cancels.
private struct NumberBadge: View {
    let number: Int
    let stepId: String
    var focus: FocusState<String?>.Binding
    let onCommit: (Int) -> Void

    @State private var editing = false
    @State private var draft = ""
    private var fieldID: String { "num:\(stepId)" }

    var body: some View {
        ZStack {
            Circle().fill(Palette.accent)
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(width: 26)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.onAccent)
                    .focused(focus, equals: fieldID)
                    .onKeyPress(.return, phases: .down) { _ in focus.wrappedValue = nil; return .handled }
                    .onExitCommand { draft = String(number); focus.wrappedValue = nil }
                    .onChange(of: focus.wrappedValue) { _, current in if current != fieldID { commit() } }
                    .onAppear { draft = String(number); DispatchQueue.main.async { focus.wrappedValue = fieldID } }
            } else {
                Text(String(number))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.onAccent)
                    .contentShape(Rectangle())
                    .onTapGesture { draft = String(number); editing = true }
            }
        }
        .frame(width: 32, height: 32)
        .help("Click to change this step's position")
    }

    private func commit() {
        editing = false
        if let n = Int(draft.trimmingCharacters(in: .whitespaces)), n != number { onCommit(n) }
    }
}

/// The step image inside its report viewport: fitted to 820x600 at zoom 1,
/// magnified + panned per the persisted reportZoom/reportPan*, with the CSS
/// click-marker overlay when the ring isn't already baked into the pixels.
private struct StepFigure: View {
    let step: ProjectStep
    let projectDir: String
    let relPath: String
    /// Set an absolute report zoom (AppModel clamps to 1…max).
    var onZoom: (Double) -> Void = { _ in }
    /// Persist the pan as fractions (0…1) of the scrollable range.
    var onReframe: (Double, Double) -> Void = { _, _ in }

    @State private var loaded: (image: NSImage, pixelSize: (width: Double, height: Double))?
    @State private var failed = false
    /// Live image offset while dragging (and until the persisted pan catches up),
    /// so the pan doesn't flash back to the old value during the async save.
    @State private var liveOffset: CGSize?
    /// The shown offset captured at drag start, so a drag composes against what's
    /// on screen (even if a prior drag's save is still in flight) and stays stable
    /// mid-drag. Nil except during a drag.
    @State private var dragStart: CGSize?
    /// Optimistic zoom applied instantly on a control tap (the persisted value
    /// lags behind an async save+reload); cleared once the save round-trips. Lets
    /// rapid clicks compound off the pending value instead of coalescing.
    @State private var pendingZoom: Double?
    @State private var hovering = false

    /// Effective zoom (optimistic pending, else persisted; never below fit).
    private var zoom: Double { pendingZoom ?? max(1, step.reportZoom ?? 1) }
    /// Key that changes when the persisted framing does — clears the live
    /// overrides once the save round-trips so they can't drift.
    private var frameKey: String { "\(step.reportZoom ?? 1)|\(step.reportPanX ?? 0.5)|\(step.reportPanY ?? 0.5)" }

    var body: some View {
        Group {
            if let loaded, let viewport = ReportPresentation.viewport(for: step, imagePixelSize: loaded.pixelSize, zoomOverride: pendingZoom) {
                figure(loaded.image, loaded.pixelSize, viewport)
            } else if failed {
                Label("Image missing: \(relPath)", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ProgressView()
                    .frame(height: 120)
            }
        }
        // Re-load when the bytes change even though the path is stable: a re-save
        // reuses export/.render/<id>.png and only bumps renderRev, so the render
        // revision must be part of the reload key or the old image stays cached.
        .task(id: "\(relPath)#\(step.renderRev ?? 0)") { load() }
        // Once the persisted framing round-trips, drop the live overrides so the
        // viewport geometry is the single source of truth again. Keep pendingZoom
        // until the persisted zoom actually matches it (so a slower save doesn't
        // flicker the zoom back mid-click-burst).
        .onChange(of: frameKey) {
            liveOffset = nil
            if let p = pendingZoom, abs((step.reportZoom ?? 1) - p) < 0.0001 { pendingZoom = nil }
        }
    }

    private func figure(_ image: NSImage, _ pixelSize: (width: Double, height: Double), _ v: ReportPresentation.Viewport) -> some View {
        let rangeX = v.imageWidth - v.boxWidth
        let rangeY = v.imageHeight - v.boxHeight
        let canPan = rangeX > 0.5 || rangeY > 0.5
        let base = CGSize(width: v.offsetX, height: v.offsetY)
        let shown = liveOffset ?? base
        return ZStack(alignment: .topTrailing) {
            // The clipped, pannable image box.
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: v.imageWidth, height: v.imageHeight)
                if let f = ReportPresentation.markerFraction(for: step, displayedImageSize: pixelSize) {
                    MarkerRing(colorHex: ReportPresentation.markerColorHex(for: step))
                        .position(x: f.x * v.imageWidth, y: f.y * v.imageHeight)
                }
            }
            .frame(width: v.imageWidth, height: v.imageHeight, alignment: .topLeading)
            .offset(x: shown.width, y: shown.height)
            .frame(width: v.boxWidth, height: v.boxHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hair))
            .contentShape(Rectangle())
            .gesture(canPan ? panGesture(shown: shown, rangeX: rangeX, rangeY: rangeY) : nil)

            // Floating zoom controls (top-right, outside the clipped box so they
            // don't pan). Faint until hover.
            zoomControls
                .padding(6)
                .opacity(hovering ? 1 : 0.35)
        }
        .frame(width: v.boxWidth, height: v.boxHeight, alignment: .topLeading)
        .onHover { hovering = $0 }
    }

    private var zoomControls: some View {
        VStack(spacing: 3) {
            CtlButton(icon: "plus.magnifyingglass", help: "Zoom in", disabled: zoom >= ReportPresentation.zoomMax) { applyZoom(zoom * 1.25) }
            CtlButton(icon: "minus.magnifyingglass", help: "Zoom out", disabled: zoom <= 1) { applyZoom(zoom / 1.25) }
            CtlButton(icon: "arrow.counterclockwise", help: "Reset zoom", disabled: zoom == 1) { applyZoom(1) }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Palette.hair))
    }

    /// Apply a zoom optimistically (instant feedback + rapid clicks compound off
    /// the pending value), then persist. A zoom change re-frames the pan, so drop
    /// the live pan override.
    private func applyZoom(_ target: Double) {
        let z = min(max(target, 1), ReportPresentation.zoomMax)
        pendingZoom = z
        liveOffset = nil
        onZoom(z)
    }


    private func panGesture(shown: CGSize, rangeX: Double, rangeY: Double) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // Anchor to the offset shown when the drag began (captured once),
                // so consecutive drags compose against what's on screen — not a
                // still-persisting base — and the anchor stays stable mid-drag.
                if dragStart == nil { dragStart = shown }
                let start = dragStart ?? shown
                liveOffset = clampedOffset(base: start, translation: value.translation, rangeX: rangeX, rangeY: rangeY)
            }
            .onEnded { value in
                let start = dragStart ?? shown
                let off = clampedOffset(base: start, translation: value.translation, rangeX: rangeX, rangeY: rangeY)
                liveOffset = off
                dragStart = nil
                onReframe(rangeX > 0 ? -off.width / rangeX : 0.5,
                          rangeY > 0 ? -off.height / rangeY : 0.5)
            }
    }

    /// Offset is ≤ 0 and ≥ -range on each axis (0 = flush left/top, -range = flush
    /// right/bottom), so the image can't be dragged past its edges.
    private func clampedOffset(base: CGSize, translation: CGSize, rangeX: Double, rangeY: Double) -> CGSize {
        CGSize(width: min(0, max(-rangeX, base.width + translation.width)),
               height: min(0, max(-rangeY, base.height + translation.height)))
    }

    private func load() {
        // The manifest-supplied relative path is UNTRUSTED: confine it to the
        // project folder before touching the filesystem (same boundary the
        // Windows shot:// resolver enforces).
        guard let abs = confinePath(dir: projectDir, rel: relPath),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: abs) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            failed = true
            return
        }
        // Pixel dimensions, not NSImage points — annotations/clicks are in
        // stored-PNG pixel space.
        let size = (width: Double(cg.width), height: Double(cg.height))
        loaded = (NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), size)
    }
}

/// A report zoom control button: highlights with the brand accent on hover when
/// enabled; stays dimmed and inert when disabled.
private struct CtlButton: View {
    let icon: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : (hover ? Palette.accent : Color.primary))
        .background(
            (hover && !disabled ? Palette.accent.opacity(0.16) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { hover = $0 }
        .help(help)
    }
}

/// The click-register ring (.rep__marker): 22px circle, 2.5px colored border,
/// 18% tinted fill, white halo.
private struct MarkerRing: View {
    let colorHex: String

    var body: some View {
        let color = Color(hex: colorHex)
        Circle()
            .fill(color.opacity(0.18))
            .stroke(color, lineWidth: 2.5)
            .background(Circle().stroke(Color.white.opacity(0.7), lineWidth: 7))
            .frame(width: 22, height: 22)
            .allowsHitTesting(false)
    }
}

extension Color {
    /// "#rrggbb" / "#rgb" hex colors, as used throughout the schema's
    /// annotation/marker fields. Falls back to the report accent on bad input.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = Color(red: 0xE1 / 255.0, green: 0x1D / 255.0, blue: 0x48 / 255.0)
            return
        }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

/// Auto-scrolls the report's `NSScrollView` while a step is dragged near the top
/// or bottom edge — SwiftUI's ScrollView doesn't auto-scroll during a drag. A
/// timer polls the mouse location (which stays valid throughout a drag session,
/// unlike drop-target callbacks, which don't report continuous position) and
/// nudges the clip view when the pointer is inside a hot band at either edge.
@MainActor private final class AutoScroller {
    // Strong: owned via ReportView's @State and released when the report goes
    // away. A weak ref could clear unexpectedly and strand auto-scroll.
    var scrollView: NSScrollView? {
        didSet { if scrollView != nil { Log.ui.debug("auto-scroll: scroll view resolved") } }
    }
    private var timer: DispatchSourceTimer?
    private var hoverCount = 0
    private var loggedTick = false
    private var loggedScroll = false

    /// A step-drag entered (+1) or left (-1) a report drop target. The timer runs
    /// while at least one drop target is being hovered (i.e. a drag is active).
    func noteHover(_ active: Bool) {
        let before = hoverCount
        hoverCount = max(0, hoverCount + (active ? 1 : -1))
        if hoverCount > 0, before == 0 {
            Log.ui.debug("auto-scroll: drag active — starting timer")
            start()
        } else if hoverCount == 0, before > 0 {
            stop()
        }
    }

    /// A drop landed — end the drag session cleanly.
    func reset() {
        hoverCount = 0
        stop()
    }

    private func start() {
        guard timer == nil else { return }
        loggedTick = false
        loggedScroll = false
        // GCD timer on the main queue: unlike a run-loop Timer it isn't gated by
        // the run-loop mode, so it fires during the drag's event-tracking loop.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(30))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume()
        timer = t
    }

    private func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let sv = scrollView, let win = sv.window else {
            if !loggedTick { loggedTick = true; Log.ui.debug("auto-scroll: tick but no scroll view/window") }
            return
        }
        let mouse = NSEvent.mouseLocation // screen coords, origin bottom-left
        let onScreen = win.convertToScreen(sv.convert(sv.bounds, to: nil))
        let edge: CGFloat = 64, maxSpeed: CGFloat = 26
        var dy: CGFloat = 0
        if mouse.x >= onScreen.minX, mouse.x <= onScreen.maxX {
            if mouse.y > onScreen.maxY - edge { // near the top → scroll up
                dy = -maxSpeed * min(1, (mouse.y - (onScreen.maxY - edge)) / edge)
            } else if mouse.y < onScreen.minY + edge { // near the bottom → scroll down
                dy = maxSpeed * min(1, ((onScreen.minY + edge) - mouse.y) / edge)
            }
        }
        if !loggedTick {
            loggedTick = true
            Log.ui.debug("auto-scroll: first tick mouseY=\(Int(mouse.y), privacy: .public) svMinY=\(Int(onScreen.minY), privacy: .public) svMaxY=\(Int(onScreen.maxY), privacy: .public) dy=\(Int(dy), privacy: .public)")
        }
        guard dy != 0 else { return }
        let clip = sv.contentView
        let docH = sv.documentView?.frame.height ?? 0
        let clipH = clip.bounds.height
        let maxY = max(0, docH - clipH)
        let oldY = clip.bounds.origin.y
        let newY = min(max(0, oldY + dy), maxY)
        if !loggedScroll {
            loggedScroll = true
            Log.ui.debug("auto-scroll: apply oldY=\(Int(oldY), privacy: .public) newY=\(Int(newY), privacy: .public) docH=\(Int(docH), privacy: .public) clipH=\(Int(clipH), privacy: .public)")
        }
        guard newY != oldY else { return }
        var origin = clip.bounds.origin
        origin.y = newY
        clip.scroll(to: origin)
        sv.reflectScrolledClipView(clip)
    }
}

/// Resolves the enclosing `NSScrollView` of the SwiftUI ScrollView so it can be
/// auto-scrolled programmatically during a drag. RETRIES until found — on the
/// first render the view may not be inside the scroll view / window yet, and if
/// that single attempt misses, auto-scroll silently never works (a race that
/// made it work only intermittently). Falls back to a window search.
private struct ScrollProbe: NSViewRepresentable {
    let onFound: (NSScrollView) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var found = false }

    func makeNSView(context: Context) -> NSView { let v = NSView(); attempt(v, context.coordinator, 0); return v }
    func updateNSView(_ nsView: NSView, context: Context) { attempt(nsView, context.coordinator, 0) }

    private func attempt(_ v: NSView, _ coord: Coordinator, _ tries: Int) {
        guard !coord.found else { return }
        DispatchQueue.main.async {
            if coord.found { return }
            if let sv = v.enclosingScrollView ?? (v.window?.contentView).flatMap(firstScrollView(in:)) {
                coord.found = true
                onFound(sv)
            } else if tries < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attempt(v, coord, tries + 1) }
            }
        }
    }
}

/// First `NSScrollView` anywhere under `view` (depth-first).
private func firstScrollView(in view: NSView) -> NSScrollView? {
    if let sv = view as? NSScrollView { return sv }
    for sub in view.subviews { if let sv = firstScrollView(in: sub) { return sv } }
    return nil
}
