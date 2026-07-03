import AppKit
import ShotModel
import SwiftUI

/// The in-app report, read-only for Phase A: each step rendered as its
/// screenshot with an overlaid click-register marker + caption + note; text
/// steps as heading/body blocks; callouts as tinted boxes. Prefers the
/// flattened render (annotations baked + redaction) over the raw screenshot.
/// Rendering rules live in ShotModel.ReportPresentation, ported from Report.tsx.
struct ReportView: View {
    let opened: ProjectStore.OpenedProject

    private var steps: [ProjectStep] { opened.manifest.steps }
    private var numbers: [String: Int] { ReportPresentation.displayNumbers(for: steps) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let intro = opened.manifest.intro {
                    IntroBox(intro: intro)
                }
                ForEach(steps) { step in
                    StepRow(step: step, number: numbers[step.id], projectDir: opened.dir)
                }
                if steps.isEmpty {
                    Text("No steps in this project.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
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
            .foregroundStyle(.secondary)
        }
    }
}

/// SOP overview preamble — a lead-in above the steps, NOT a numbered step.
private struct IntroBox: View {
    let intro: SopIntro

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !intro.heading.isEmpty {
                Text(intro.heading).font(.title3.bold())
            }
            if !intro.body.isEmpty {
                Text(intro.body).foregroundStyle(.primary.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(hex: "#f8f9fc"))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(hex: "#4f46e5")).frame(width: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct StepRow: View {
    let step: ProjectStep
    let number: Int?
    let projectDir: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            rail
            VStack(alignment: .leading, spacing: 8) {
                if step.kind == .text {
                    if let callout = step.callout {
                        CalloutBox(step: step, kind: callout)
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
                    .background(Color(hex: "#eef2ff"))
                    .foregroundStyle(Color(hex: "#4f46e5"))
                    .clipShape(Circle())
            }
        }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let heading = step.heading, !heading.isEmpty {
                Text(heading).font(.title3.bold())
            }
            if let body = step.body, !body.isEmpty {
                Text(body).foregroundStyle(.primary.opacity(0.85))
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var shotBlock: some View {
        Text(step.caption.isEmpty ? "Untitled step" : step.caption)
            .font(.headline)
        if let rel = ReportPresentation.displayImagePath(for: step) {
            StepFigure(step: step, projectDir: projectDir, relPath: rel)
        }
        if let body = step.body, !body.isEmpty {
            Text(body)
        }
        if !step.note.isEmpty {
            Text(step.note)
                .font(.system(size: 12.5))
                .foregroundStyle(Color(hex: "#374151"))
        }
        if let window = step.window {
            Text(window.title.isEmpty ? window.app : "\(window.app) — \(window.title)")
                .font(.caption)
                .foregroundStyle(Color(hex: "#9097a1"))
                .lineLimit(1)
        }
    }
}

/// A text step styled as a tinted note/caution/warning box.
private struct CalloutBox: View {
    let step: ProjectStep
    let kind: CalloutKind

    struct Palette {
        let background: Color
        let border: Color
        let text: Color
    }

    static func palette(_ kind: CalloutKind) -> Palette {
        switch kind {
        case .note:
            Palette(background: Color(hex: "#ecfdf5"), border: Color(hex: "#6ee7b7"), text: Color(hex: "#065f46"))
        case .caution:
            Palette(background: Color(hex: "#fffbeb"), border: Color(hex: "#fcd34d"), text: Color(hex: "#92400e"))
        case .warning:
            Palette(background: Color(hex: "#fef2f2"), border: Color(hex: "#fca5a5"), text: Color(hex: "#991b1b"))
        }
    }

    var body: some View {
        let palette = Self.palette(kind)
        VStack(alignment: .leading, spacing: 4) {
            if let heading = step.heading, !heading.isEmpty {
                Text(heading).bold()
            }
            if let body = step.body, !body.isEmpty {
                Text(body)
            }
        }
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(palette.background)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        .task(id: relPath) { load() }
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
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
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
