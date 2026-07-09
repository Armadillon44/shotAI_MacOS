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
    /// Drives edge auto-scroll while a step is being dragged.
    @State private var autoScroller = AutoScroller()

    private var steps: [ProjectStep] { opened.manifest.steps }
    private var numbers: [String: Int] { ReportPresentation.displayNumbers(for: steps) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
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
                    Text("No steps yet — record a process, or add a text block below.")
                        .foregroundStyle(Palette.ink3)
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
            // Resolve the backing NSScrollView so a step drag near the top/bottom
            // edge can auto-scroll (driven per-row via autoScroller.noteHover).
            .background(ScrollProbe { autoScroller.scrollView = $0 })
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
    }

    /// Merge is offered only for a shot step followed by another shot step (the
    /// click of this step is carried onto the next step's screenshot).
    private func canMergeNext(at index: Int) -> Bool {
        guard index + 1 < steps.count else { return false }
        let cur = steps[index], next = steps[index + 1]
        return cur.kind != .text && next.kind != .text && !next.screenshot.isEmpty
    }

    /// Route an insert-zone choice: text/callout add immediately; image opens a
    /// modal open panel (SwiftUI's .fileImporter is unreliable when triggered
    /// from inside a Menu action — the menu's event loop swallows it).
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
        case .screenshot:
            // Arm a single in-place capture: the window hides, the pill shows,
            // and the next click records one screenshot inserted here.
            Task { await capture.captureSingle(projectPath: opened.dir, insertAt: index) }
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
private enum InsertChoice { case text, image, screenshot, callout(CalloutKind) }

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
                Button("Text block") { onInsert(.text) }
                Button("Image…") { onInsert(.image) }
                Button("Screenshot…") { onInsert(.screenshot) }
                Divider()
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
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Palette.hair) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
            StepFigure(step: step, projectDir: projectDir, relPath: rel)
                .id("\(step.id)#\(step.renderRev ?? 0)#\(rel)")
        }
        InlineEditable(text: step.body ?? "", placeholder: "+ Add instructions", multiline: true, id: "body:\(step.id)", focus: focus) { new in
            Task { await model.editStepText(stepId: step.id, body: new) }
        }
        // `note` is a legacy read-only field (Windows shows it if present but
        // offers no editor); surfaced only when something populated it.
        if !step.note.isEmpty {
            Text(step.note)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink2)
        }
        if let window = step.window {
            Text(window.title.isEmpty ? window.app : "\(window.app) — \(window.title)")
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
/// Focus is driven by a SHARED `FocusState` (`focus`) keyed by this field's `id`
/// so a background click in the report can dismiss whichever field is active
/// (a plain macOS text field doesn't resign first responder on a dead-space
/// click). Focus is taken on the next runloop tick — setting it synchronously as
/// the field first appears misses (the view isn't in the responder chain yet),
/// which is why a first click previously needed a second click to activate.
struct InlineEditable: View {
    let text: String
    var placeholder: String
    var font: Font = .body
    var color: Color = Palette.ink
    var multiline: Bool = false
    let id: String
    var focus: FocusState<String?>.Binding
    var onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        if editing {
            Group {
                if multiline {
                    TextField(placeholder, text: $draft, axis: .vertical).lineLimit(1...12)
                } else {
                    TextField(placeholder, text: $draft).onSubmit { focus.wrappedValue = nil }
                }
            }
            .font(font)
            .textFieldStyle(.roundedBorder)
            .focused(focus, equals: id)
            // Return finishes editing; Shift+Return inserts a newline in
            // multi-line fields.
            .onKeyPress(.return, phases: .down) { key in
                if multiline && key.modifiers.contains(.shift) { return .ignored }
                focus.wrappedValue = nil
                return .handled
            }
            .onExitCommand { draft = text; focus.wrappedValue = nil } // Esc discards
            .onChange(of: focus.wrappedValue) { _, current in
                if current != id { commit() } // lost focus: another field, background, or Esc
            }
            .onAppear { draft = text; DispatchQueue.main.async { focus.wrappedValue = id } }
        } else {
            Button {
                draft = text
                editing = true
            } label: {
                Text(text.isEmpty ? placeholder : text)
                    .font(font)
                    .foregroundStyle(text.isEmpty ? Palette.ink3 : color)
                    .italic(text.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to edit")
        }
    }

    private func commit() {
        editing = false
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

    @State private var loaded: (image: NSImage, pixelSize: (width: Double, height: Double))?
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded, let viewport = ReportPresentation.viewport(for: step, imagePixelSize: loaded.pixelSize) {
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
    }

    private func figure(_ image: NSImage, _ pixelSize: (width: Double, height: Double), _ v: ReportPresentation.Viewport) -> some View {
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
        .offset(x: v.offsetX, y: v.offsetY)
        .frame(width: v.boxWidth, height: v.boxHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hair))
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
