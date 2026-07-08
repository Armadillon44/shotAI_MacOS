import EditorKit
import ShotModel
import SwiftUI

/// Full-window redaction-first annotation editor (C4a). Presented as an in-window
/// overlay (not a sheet). Tools: Select (move/resize/delete redactions), Redact
/// (drag to obscure a region), Crop (drag to frame). Save re-flattens from the
/// raw screenshot with redaction baked into the pixels.
struct EditorOverlay: View {
    @State var model: EditorModel
    var onCancel: () -> Void
    var onSaved: () -> Void

    // Drag state (image-px space).
    private struct Drag {
        enum Mode { case create, createCrop, move, resize, none }
        var mode: Mode
        var startImg: CGPoint
        var origRect: CGRect
    }
    @State private var drag: Drag?
    @State private var draftRect: CGRect? // during create/createCrop, image px

    private let accent = Color(hex: AnnotationStyle.accent)

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
        }
        // Fill the window's CONTENT area (below the title bar). Extending under
        // the title bar collided the editor toolbar with the window's native
        // toolbar; only bleed to the sides/bottom.
        .background(.ultraThickMaterial)
        .ignoresSafeArea(edges: [.horizontal, .bottom])
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(model.step.caption.isEmpty ? "Edit step" : model.step.caption)
                .font(.headline).lineLimit(1)

            Picker("Tool", selection: $model.tool) {
                Image(systemName: "cursorarrow").tag(EditorModel.Tool.select)
                Image(systemName: "eye.slash").tag(EditorModel.Tool.redact)
                Image(systemName: "crop").tag(EditorModel.Tool.crop)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Select · Redact · Crop")

            if model.tool == .redact || isBlurSelected {
                Picker("Style", selection: $model.redactMode) {
                    Text("Pixelate").tag(BlurAnnotation.Mode.pixelate)
                    Text("Solid").tag(BlurAnnotation.Mode.solid)
                }
                .pickerStyle(.segmented).fixedSize()
                .onChange(of: model.redactMode) { model.applyStyleToSelected() }
            }

            Button {
                Task { await model.autoRedact() }
            } label: {
                if model.scanning { ProgressView().controlSize(.small) }
                else { Label("Auto-redact", systemImage: "sparkles") }
            }
            .disabled(model.scanning)
            .help("Scan for SSNs, card numbers, and API keys and redact them")

            if isBlurSelected {
                Button(role: .destructive) { model.deleteSelected() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if model.crop != nil {
                Button("Clear crop") { model.crop = nil }
            }

            Spacer()

            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { if await model.save() { onSaved() } }
            } label: {
                if model.saving { ProgressView().controlSize(.small) } else { Text("Save") }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.saving)
        }
        .padding(12)
    }

    private var isBlurSelected: Bool { model.rectOfSelected() != nil }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let f = fit(geo.size)
            Canvas { ctx, _ in draw(ctx, f) }
                .contentShape(Rectangle())
                .gesture(dragGesture(f))
                .onKeyPress(.delete) {
                    if isBlurSelected { model.deleteSelected(); return .handled }
                    return .ignored
                }
        }
        .background(Color.black.opacity(0.15))
        .clipped()
    }

    private struct Fit { var s: CGFloat; var ox: CGFloat; var oy: CGFloat; var dw: CGFloat; var dh: CGFloat }

    private func fit(_ size: CGSize) -> Fit {
        let s = min(size.width / model.imageSize.width, size.height / model.imageSize.height)
        let dw = model.imageSize.width * s, dh = model.imageSize.height * s
        return Fit(s: s, ox: (size.width - dw) / 2, oy: (size.height - dh) / 2, dw: dw, dh: dh)
    }

    private func toImage(_ p: CGPoint, _ f: Fit) -> CGPoint {
        CGPoint(x: (p.x - f.ox) / f.s, y: (p.y - f.oy) / f.s)
    }
    private func toDisplay(_ r: CGRect, _ f: Fit) -> CGRect {
        CGRect(x: f.ox + r.minX * f.s, y: f.oy + r.minY * f.s, width: r.width * f.s, height: r.height * f.s)
    }

    private func draw(_ ctx: GraphicsContext, _ f: Fit) {
        let imageRect = CGRect(x: f.ox, y: f.oy, width: f.dw, height: f.dh)
        ctx.draw(ctx.resolve(Image(decorative: model.rawImage, scale: 1)), in: imageRect)

        // Non-blur annotation previews (read-only in C4a; baked on save).
        for a in model.annotations { drawAnnotationPreview(ctx, a, f) }

        // Redaction previews (blur) — solid gray placeholder; the real mosaic is
        // baked at flatten. Selected one gets an accent border + resize handle.
        for a in model.annotations {
            guard case .blur(let b) = a else { continue }
            let r = toDisplay(CGRect(x: b.x, y: b.y, width: b.width, height: b.height), f)
            let selected = b.id == model.selectedID
            ctx.fill(Path(r), with: .color(.black.opacity(b.mode == .solid ? 0.85 : 0.55)))
            ctx.stroke(Path(r), with: .color(selected ? accent : .white.opacity(0.8)),
                       style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [4, 3]))
            if selected {
                let h = CGRect(x: r.maxX - 6, y: r.maxY - 6, width: 12, height: 12)
                ctx.fill(Path(roundedRect: h, cornerRadius: 2), with: .color(accent))
                ctx.stroke(Path(roundedRect: h, cornerRadius: 2), with: .color(.white), lineWidth: 1)
            }
        }

        // Crop: dim everything outside the crop rect.
        if let crop = model.crop {
            let cr = toDisplay(CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height), f)
            var outside = Path(imageRect)
            outside.addRect(cr)
            ctx.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
            ctx.stroke(Path(cr), with: .color(accent), lineWidth: 2)
        }

        // Draft rect while dragging a new redaction/crop.
        if let d = draftRect {
            let r = toDisplay(d, f)
            ctx.stroke(Path(r), with: .color(accent), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
    }

    private func drawAnnotationPreview(_ ctx: GraphicsContext, _ a: Annotation, _ f: Fit) {
        switch a {
        case .rect(let r):
            let d = toDisplay(CGRect(x: r.x, y: r.y, width: r.width, height: r.height), f)
            ctx.stroke(Path(roundedRect: d, cornerRadius: r.cornerRadius * f.s),
                       with: .color(Color(hex: r.stroke)), lineWidth: max(1, r.strokeWidth * f.s))
        case .arrow(let ar) where ar.points.count == 4:
            var p = Path()
            p.move(to: toDisplay(CGRect(x: ar.points[0], y: ar.points[1], width: 0, height: 0), f).origin)
            p.addLine(to: toDisplay(CGRect(x: ar.points[2], y: ar.points[3], width: 0, height: 0), f).origin)
            ctx.stroke(p, with: .color(Color(hex: ar.stroke)), lineWidth: max(1, ar.strokeWidth * f.s))
        case .marker(let m):
            let radius = (m.radius ?? Double(AnnotationStyle.clickMarkerRadius(width: model.imageSize.width, height: model.imageSize.height))) * f.s
            let c = toDisplay(CGRect(x: m.x, y: m.y, width: 0, height: 0), f).origin
            let box = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            ctx.stroke(Path(ellipseIn: box), with: .color(Color(hex: m.color)), lineWidth: 2)
        case .stamp(let s):
            let radius = s.radius * f.s
            let c = toDisplay(CGRect(x: s.x, y: s.y, width: 0, height: 0), f).origin
            let box = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: box), with: .color(Color(hex: s.fill)))
            ctx.draw(ctx.resolve(Text(String(s.n)).font(.system(size: radius, weight: .bold)).foregroundColor(Color(hex: s.textColor))), at: c)
        case .text(let t):
            let at = toDisplay(CGRect(x: t.x, y: t.y, width: 0, height: 0), f).origin
            ctx.draw(ctx.resolve(Text(t.text).font(.system(size: t.fontSize * f.s)).foregroundColor(Color(hex: t.fill))), at: at, anchor: .topLeading)
        default:
            break // blur handled separately; unknown not rendered
        }
    }

    // MARK: - Gesture

    private func dragGesture(_ f: Fit) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startImg = toImage(value.startLocation, f)
                let curImg = toImage(value.location, f)
                if drag == nil {
                    drag = beginDrag(startImg: startImg, f: f)
                }
                guard let d = drag else { return }
                switch d.mode {
                case .create, .createCrop:
                    draftRect = normalized(d.startImg, curImg)
                case .move:
                    let dx = curImg.x - d.startImg.x, dy = curImg.y - d.startImg.y
                    model.setSelectedRect(d.origRect.offsetBy(dx: dx, dy: dy))
                case .resize:
                    model.setSelectedRect(normalized(CGPoint(x: d.origRect.minX, y: d.origRect.minY), curImg))
                case .none:
                    break
                }
            }
            .onEnded { _ in
                if let d = drag {
                    if d.mode == .create, let r = draftRect, r.width >= 5, r.height >= 5 {
                        model.addRedaction(r)
                    } else if d.mode == .createCrop, let r = draftRect, r.width >= 5, r.height >= 5 {
                        model.crop = Rect(x: r.minX, y: r.minY, width: r.width, height: r.height)
                    }
                }
                drag = nil
                draftRect = nil
            }
    }

    private func beginDrag(startImg: CGPoint, f: Fit) -> Drag {
        switch model.tool {
        case .redact:
            return Drag(mode: .create, startImg: startImg, origRect: .zero)
        case .crop:
            return Drag(mode: .createCrop, startImg: startImg, origRect: .zero)
        case .select:
            // Resize if the drag started on the selected blur's handle.
            if let sel = model.rectOfSelected() {
                let handleImg = 12 / f.s
                let corner = CGPoint(x: sel.maxX, y: sel.maxY)
                if abs(startImg.x - corner.x) <= handleImg, abs(startImg.y - corner.y) <= handleImg {
                    return Drag(mode: .resize, startImg: startImg, origRect: sel)
                }
            }
            // Otherwise select the blur under the point and move it.
            model.selectBlur(at: startImg)
            if let sel = model.rectOfSelected() {
                return Drag(mode: .move, startImg: startImg, origRect: sel)
            }
            return Drag(mode: .none, startImg: startImg, origRect: .zero)
        }
    }

    private func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
