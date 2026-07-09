import AppKit
import ShotModel
import SwiftUI

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
    /// True while composing a not-yet-saved overview (an all-empty intro can't
    /// persist — the manifest decoder coerces it to nil — so the placeholder box
    /// is UI-local until the user types something).
    @State private var addingIntro = false
    /// The id of the field currently being edited — a single shared focus across
    /// all inline fields so a background click can dismiss whichever is active.
    @FocusState private var focus: String?

    private var steps: [ProjectStep] { opened.manifest.steps }
    private var numbers: [String: Int] { ReportPresentation.displayNumbers(for: steps) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                intro
                ForEach(Array(steps.enumerated()), id: \.element.id) { pair in
                    InsertZone { callout in Task { await model.addTextStep(callout: callout, atIndex: pair.offset) } }
                    StepRow(step: pair.element, number: numbers[pair.element.id], projectDir: opened.dir, focus: $focus, onEdit: onEdit)
                }
                if steps.isEmpty {
                    Text("No steps yet — record a process, or add a text block below.")
                        .foregroundStyle(Palette.ink3)
                }
                InsertZone { callout in Task { await model.addTextStep(callout: callout, atIndex: steps.count) } } // append
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
        }
        .background(Palette.surface)
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
private struct InsertZone: View {
    /// nil = plain text block; otherwise the callout kind.
    let onInsert: (CalloutKind?) -> Void
    @State private var hovering = false

    var body: some View {
        // Full-width row so the flanking lines expand and CENTER the ＋. The
        // lines live outside the Menu (a borderless Menu sizes its label to its
        // content, which would collapse flexible lines to nothing).
        HStack(spacing: 10) {
            line
            Menu {
                Button("Text block") { onInsert(nil) }
                Divider()
                Button("Note") { onInsert(.note) }
                Button("Caution") { onInsert(.caution) }
                Button("Warning") { onInsert(.warning) }
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
    let onEdit: (ProjectStep) -> Void
    @Environment(AppModel.self) private var model

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
        }
        .padding(.vertical, 6)
    }

    /// Left rail: the step number for numbered steps, a type glyph for callouts.
    private var rail: some View {
        Group {
            if let callout = step.callout, ReportPresentation.isCalloutStep(step) {
                Text(ReportPresentation.calloutGlyph(callout))
                    .font(.system(size: 15))
                    .frame(width: 32, height: 32)
                    .background(CalloutBox.palette(callout).background)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(CalloutBox.palette(callout).border))
            } else {
                Text(number.map(String.init) ?? "")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .frame(width: 32, height: 32)
                    .background(number != nil ? Palette.accent : Palette.hair2)
                    .foregroundStyle(Palette.onAccent)
                    .clipShape(Circle())
            }
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
