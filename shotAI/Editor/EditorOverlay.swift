import AppKit
import EditorKit
import ShotModel
import SwiftUI

/// Full-window annotation editor. Presented as an in-window overlay (not a
/// sheet). Tools: Select (move/resize/delete any shape), Box, Arrow, Redact
/// (drag to obscure), Crop. A contextual properties bar exposes color + stroke
/// width for the active tool / selection. Save re-flattens from the raw
/// screenshot with redaction baked into the pixels.
struct EditorOverlay: View {
    @State var model: EditorModel
    var onCancel: () -> Void
    var onSaved: () -> Void

    // Drag state (image-px space).
    private struct Drag {
        enum Mode { case createRect, createArrow, createRedact, createCrop, move, resize, none }
        var mode: Mode
        var startImg: CGPoint
        var origRect: CGRect          // selection bounds at drag start (move/resize)
        var original: Annotation?     // selection snapshot, for arrow scaling
    }
    @State private var drag: Drag?
    @State private var draftRect: CGRect?               // box/redact/crop draft (image px)
    @State private var draftArrow: (CGPoint, CGPoint)?  // arrow draft (image px)

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
        .alert("Couldn't save this step", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(model.step.caption.isEmpty ? "Edit step" : model.step.caption)
                .font(.headline).lineLimit(1)

            Picker("Tool", selection: $model.tool) {
                Image(systemName: "cursorarrow").tag(EditorModel.Tool.select)
                Image(systemName: "rectangle").tag(EditorModel.Tool.box)
                Image(systemName: "arrow.up.right").tag(EditorModel.Tool.arrow)
                Image(systemName: "eye.slash").tag(EditorModel.Tool.redact)
                Image(systemName: "crop").tag(EditorModel.Tool.crop)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Select · Box · Arrow · Redact · Crop")

            propertiesBar

            Button {
                Task { await model.autoRedact() }
            } label: {
                if model.scanning { ProgressView().controlSize(.small) }
                else { Label("Auto-redact", systemImage: "sparkles") }
            }
            .disabled(model.scanning || model.saving)
            .help("Scan for SSNs, card numbers, and API keys and redact them")

            if model.selectedID != nil {
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
                .disabled(model.saving) // don't cancel out from under an in-flight save
            Button {
                Task { if await model.save() { onSaved() } }
            } label: {
                if model.saving { ProgressView().controlSize(.small) } else { Text("Save") }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            // Block save mid-scan — it would bake without the OCR redactions and
            // then lose them when the scan appends after the flatten.
            .disabled(model.saving || model.scanning)
        }
        .padding(12)
    }

    /// Controls contextual to the active tool / selection, matching the Windows
    /// editor's properties bar (color + stroke width for shapes; blur mode for
    /// redactions).
    @ViewBuilder private var propertiesBar: some View {
        if showsShapeStyle {
            ColorPicker("", selection: strokeColorBinding, supportsOpacity: false)
                .labelsHidden()
                .help("Color")
            HStack(spacing: 4) {
                Image(systemName: "lineweight").foregroundStyle(.secondary)
                Slider(value: strokeWidthBinding, in: 1 ... 80).frame(width: 110)
            }
            .help("Line width")
        }
        if model.tool == .redact || model.selectedIsBlur {
            Picker("Style", selection: $model.redactMode) {
                Text("Blur").tag(BlurAnnotation.Mode.pixelate)
                Text("Black box").tag(BlurAnnotation.Mode.solid)
            }
            .pickerStyle(.segmented).fixedSize()
            .onChange(of: model.redactMode) { model.applyStyleToSelected() }
        }
    }

    /// Show the color/width controls when a shape tool is active or a colorable
    /// (box/arrow) shape is selected.
    private var showsShapeStyle: Bool {
        model.tool == .box || model.tool == .arrow || model.selectedIsColorable
    }

    private var strokeColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: model.strokeColor) },
            set: { c in
                let hex = hexString(from: c)
                model.strokeColor = hex
                model.setSelectedColor(hex)
            })
    }

    private var strokeWidthBinding: Binding<Double> {
        Binding(
            get: { model.strokeWidth },
            set: { w in
                model.strokeWidth = w
                model.setSelectedStrokeWidth(w)
            })
    }

    private func hexString(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let f = fit(geo.size)
            Canvas { ctx, _ in draw(ctx, f) }
                .contentShape(Rectangle())
                .focusable() // so the canvas can receive key presses
                .gesture(dragGesture(f))
                .onKeyPress(.escape) {
                    model.selectedID = nil
                    model.tool = .select
                    return .handled
                }
                .onKeyPress(.delete) {
                    if model.selectedID != nil { model.deleteSelected(); return .handled }
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
    private func toDisplay(_ p: CGPoint, _ f: Fit) -> CGPoint {
        CGPoint(x: f.ox + p.x * f.s, y: f.oy + p.y * f.s)
    }

    private func draw(_ ctx: GraphicsContext, _ f: Fit) {
        let imageRect = CGRect(x: f.ox, y: f.oy, width: f.dw, height: f.dh)
        ctx.draw(ctx.resolve(Image(decorative: model.rawImage, scale: 1)), in: imageRect)

        // Vector annotation previews (rect/arrow/stamp/text/marker). Rect/arrow
        // are now authorable+editable; stamp/text/marker are still preview-only
        // (E2). Baked on save.
        for a in model.annotations { drawAnnotationPreview(ctx, a, f) }

        // Redaction previews (blur) — solid gray placeholder; the real mosaic is
        // baked at flatten. Unselected ones get a faint dashed border.
        for a in model.annotations {
            guard case .blur(let b) = a else { continue }
            let r = toDisplay(CGRect(x: b.x, y: b.y, width: b.width, height: b.height), f)
            ctx.fill(Path(r), with: .color(.black.opacity(b.mode == .solid ? 0.85 : 0.55)))
            if b.id != model.selectedID {
                ctx.stroke(Path(r), with: .color(.white.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }

        // Selection chrome (Select tool only, matching Windows): accent bounding
        // box + a bottom-right resize handle around whatever editable shape is
        // selected (rect/arrow/blur).
        if model.tool == .select, model.selectedID != nil, let b = model.boundsOfSelected() {
            let r = toDisplay(b, f)
            ctx.stroke(Path(r), with: .color(accent), lineWidth: 2)
            let h = CGRect(x: r.maxX - 6, y: r.maxY - 6, width: 12, height: 12)
            ctx.fill(Path(roundedRect: h, cornerRadius: 2), with: .color(accent))
            ctx.stroke(Path(roundedRect: h, cornerRadius: 2), with: .color(.white), lineWidth: 1)
        }

        // Click-register marker preview — baked on save, so show it here too
        // (WYSIWYG). Drawn before the crop dim so a crop that excludes it dims it.
        if let click = model.step.click {
            let radius = (click.radius ?? Double(AnnotationStyle.clickMarkerRadius(
                width: model.imageSize.width, height: model.imageSize.height))) * f.s
            let c = toDisplay(CGPoint(x: click.image.x, y: click.image.y), f)
            let box = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            let color = Color(hex: AnnotationStyle.markerColor(for: model.step))
            ctx.fill(Path(ellipseIn: box), with: .color(color.opacity(0.18)))
            ctx.stroke(Path(ellipseIn: box), with: .color(color), lineWidth: max(2, radius * 0.22))
        }

        // Crop: dim everything outside the crop rect.
        if let crop = model.crop {
            let cr = toDisplay(CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height), f)
            var outside = Path(imageRect)
            outside.addRect(cr)
            ctx.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
            ctx.stroke(Path(cr), with: .color(accent), lineWidth: 2)
        }

        // Draft while dragging a new shape.
        if let d = draftRect {
            let r = toDisplay(d, f)
            ctx.stroke(Path(r), with: .color(accent), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
        if let (a, b) = draftArrow {
            drawArrow(ctx, imgA: a, imgB: b, imgStroke: model.strokeWidth,
                      color: Color(hex: model.strokeColor), f)
        }
    }

    private func drawAnnotationPreview(_ ctx: GraphicsContext, _ a: Annotation, _ f: Fit) {
        switch a {
        case .rect(let r):
            let d = toDisplay(CGRect(x: r.x, y: r.y, width: r.width, height: r.height), f)
            if let fill = r.fill {
                ctx.fill(Path(roundedRect: d, cornerRadius: r.cornerRadius * f.s), with: .color(Color(hex: fill)))
            }
            ctx.stroke(Path(roundedRect: d, cornerRadius: r.cornerRadius * f.s),
                       with: .color(Color(hex: r.stroke)), lineWidth: max(1, r.strokeWidth * f.s))
        case .arrow(let ar) where ar.points.count == 4:
            drawArrow(ctx,
                      imgA: CGPoint(x: ar.points[0], y: ar.points[1]),
                      imgB: CGPoint(x: ar.points[2], y: ar.points[3]),
                      imgStroke: ar.strokeWidth, color: Color(hex: ar.stroke), f)
        case .marker(let m):
            let radius = (m.radius ?? Double(AnnotationStyle.clickMarkerRadius(width: model.imageSize.width, height: model.imageSize.height))) * f.s
            let c = toDisplay(CGPoint(x: m.x, y: m.y), f)
            let box = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: box), with: .color(Color(hex: m.color).opacity(0.18)))
            ctx.stroke(Path(ellipseIn: box), with: .color(Color(hex: m.color)), lineWidth: max(2, radius * 0.22))
        case .stamp(let s):
            let radius = s.radius * f.s
            let c = toDisplay(CGPoint(x: s.x, y: s.y), f)
            let box = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: box), with: .color(Color(hex: s.fill)))
            ctx.draw(ctx.resolve(Text(String(s.n)).font(.system(size: radius * 1.15, weight: .bold)).foregroundColor(Color(hex: s.textColor))), at: c)
        case .text(let t):
            let at = toDisplay(CGPoint(x: t.x, y: t.y), f)
            ctx.draw(ctx.resolve(Text(t.text).font(.system(size: t.fontSize * f.s)).foregroundColor(Color(hex: t.fill))), at: at, anchor: .topLeading)
        default:
            break // blur handled separately; unknown not rendered
        }
    }

    /// Shaft + filled/stroked arrowhead, mirroring Flatten's baked geometry
    /// (pointer length/width = max(12, strokeWidth*3), butt cap, miter head).
    private func drawArrow(_ ctx: GraphicsContext, imgA: CGPoint, imgB: CGPoint,
                           imgStroke: Double, color: Color, _ f: Fit) {
        let a = toDisplay(imgA, f), b = toDisplay(imgB, f)
        let width = max(1, imgStroke * f.s)
        let head = max(12, imgStroke * 3) * f.s
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(0.0001, hypot(dx, dy))
        let ux = dx / len, uy = dy / len
        var shaft = Path(); shaft.move(to: a); shaft.addLine(to: b)
        ctx.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .butt))
        let baseC = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        let px = -uy, py = ux, half = head / 2
        var tri = Path()
        tri.move(to: b)
        tri.addLine(to: CGPoint(x: baseC.x + px * half, y: baseC.y + py * half))
        tri.addLine(to: CGPoint(x: baseC.x - px * half, y: baseC.y - py * half))
        tri.closeSubpath()
        ctx.fill(tri, with: .color(color))
        ctx.stroke(tri, with: .color(color), style: StrokeStyle(lineWidth: width, lineJoin: .miter))
    }

    // MARK: - Gesture

    private func dragGesture(_ f: Fit) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startImg = toImage(value.startLocation, f)
                let curImg = toImage(value.location, f)
                if drag == nil { drag = beginDrag(startImg: startImg, f: f) }
                guard let d = drag else { return }
                switch d.mode {
                case .createRect, .createRedact, .createCrop:
                    draftRect = normalized(d.startImg, curImg)
                case .createArrow:
                    draftArrow = (d.startImg, curImg)
                case .move:
                    if let orig = d.original {
                        model.moveSelected(orig, dx: curImg.x - d.startImg.x, dy: curImg.y - d.startImg.y)
                    }
                case .resize:
                    if let orig = d.original {
                        model.resizeSelected(orig, to: normalized(CGPoint(x: d.origRect.minX, y: d.origRect.minY), curImg))
                    }
                case .none:
                    break
                }
            }
            .onEnded { _ in
                if let d = drag {
                    switch d.mode {
                    case .createRect:
                        if let r = draftRect, r.width >= 5, r.height >= 5 { model.addRect(r) }
                    case .createRedact:
                        if let r = draftRect, r.width >= 5, r.height >= 5 { model.addRedaction(r) }
                    case .createCrop:
                        if let r = draftRect, r.width >= 5, r.height >= 5 { model.setCrop(r) }
                    case .createArrow:
                        if let (a, b) = draftArrow, hypot(b.x - a.x, b.y - a.y) >= 5 { model.addArrow(from: a, to: b) }
                    default:
                        break
                    }
                }
                drag = nil
                draftRect = nil
                draftArrow = nil
            }
    }

    private func beginDrag(startImg: CGPoint, f: Fit) -> Drag {
        switch model.tool {
        case .box:
            return Drag(mode: .createRect, startImg: startImg, origRect: .zero, original: nil)
        case .arrow:
            return Drag(mode: .createArrow, startImg: startImg, origRect: .zero, original: nil)
        case .redact:
            return Drag(mode: .createRedact, startImg: startImg, origRect: .zero, original: nil)
        case .crop:
            return Drag(mode: .createCrop, startImg: startImg, origRect: .zero, original: nil)
        case .select:
            // Resize if the drag started on the selected shape's bottom-right
            // handle (±~8 pt tolerance so it doesn't hijack nearby empty space).
            if let sel = model.boundsOfSelected() {
                let handleImg = 8 / f.s
                let corner = CGPoint(x: sel.maxX, y: sel.maxY)
                if abs(startImg.x - corner.x) <= handleImg, abs(startImg.y - corner.y) <= handleImg {
                    return Drag(mode: .resize, startImg: startImg, origRect: sel, original: model.selected)
                }
            }
            // Otherwise select the shape under the point and move it.
            model.selectAnnotation(at: startImg)
            if let sel = model.boundsOfSelected() {
                return Drag(mode: .move, startImg: startImg, origRect: sel, original: model.selected)
            }
            return Drag(mode: .none, startImg: startImg, origRect: .zero, original: nil)
        }
    }

    private func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
