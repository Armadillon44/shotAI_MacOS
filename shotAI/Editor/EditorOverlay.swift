import AppKit
import EditorKit
import ShotModel
import SwiftUI

/// Full-window annotation editor. Presented as an in-window overlay (not a
/// sheet). Windows-style layout: a vertical TOOL RAIL on the left (Select · Box
/// · Arrow · Redact · Crop), a top bar with the contextual properties + Save /
/// Cancel, and the canvas filling the rest. Save re-flattens from the raw
/// screenshot with redaction baked into the pixels.
struct EditorOverlay: View {
    @State var model: EditorModel
    var onCancel: () -> Void
    var onSaved: () -> Void

    // Drag state (image-px space).
    private struct Drag {
        enum Mode { case createRect, createArrow, createRedact, createCrop, move, resize, moveCrop, resizeCrop, none }
        var mode: Mode
        var startImg: CGPoint
        var origRect: CGRect              // selection/crop bounds at drag start
        var original: Annotation? = nil   // selection snapshot, for arrow scaling
        var fixedCorner: CGPoint? = nil   // resizeCrop: the corner held fixed
    }
    @State private var drag: Drag?
    @State private var draftRect: CGRect?               // box/redact/crop draft (image px)
    @State private var draftArrow: (CGPoint, CGPoint)?  // arrow draft (image px)

    private let accent = Color(hex: AnnotationStyle.accent)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                toolRail
                Divider()
                canvas
            }
        }
        // Fill the ENTIRE window (ContentView makes the title bar transparent +
        // full-size while editing), so there's no empty title-bar band above the
        // top bar. The top bar itself insets to clear the traffic-light buttons.
        .background(.ultraThickMaterial)
        .ignoresSafeArea()
        .alert("Couldn't save this step", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Tool rail (left)

    private var toolRail: some View {
        VStack(spacing: 6) {
            toolButton(.select, "cursorarrow", "Select")
            toolButton(.box, "rectangle", "Box")
            toolButton(.arrow, "arrow.up.right", "Arrow")
            toolButton(.redact, "eye.slash", "Redact")
            toolButton(.crop, "crop", "Crop")
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(width: 56)
        .background(.thinMaterial)
    }

    private func toolButton(_ tool: EditorModel.Tool, _ icon: String, _ label: String) -> some View {
        // Clear the selection when switching tools: the selection chrome only
        // shows in Select, and otherwise the color/width controls (which apply to
        // the selection AND set the new-shape default) would silently mutate a
        // now-invisible shape.
        Button { model.selectedID = nil; model.tool = tool } label: {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(model.tool == tool ? accent.opacity(0.18) : Color.clear)
        .foregroundStyle(model.tool == tool ? accent : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(label)
    }

    // MARK: - Top bar (properties + actions)

    private var topBar: some View {
        HStack(spacing: 12) {
            propertiesBar

            Spacer()

            if model.selectedID != nil {
                Button(role: .destructive) { model.deleteSelected() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if model.crop != nil {
                Button("Clear crop") { model.crop = nil }
            }

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
            .disabled(model.saving || model.scanning)
        }
        // Sit BELOW the ~28pt title-bar strip. With the transparent, full-size
        // title bar the editor material fills that strip (so there's no blank
        // band and the traffic lights live in it), but the strip is a DRAGGABLE
        // region that swallows clicks — so the buttons must clear it or they
        // can't be pressed. Below it, normal 12pt insets.
        .padding(.top, 36)
        .padding([.horizontal, .bottom], 12)
    }

    /// Controls contextual to the active tool / selection: color + line width for
    /// shapes, blur mode for redactions.
    @ViewBuilder private var propertiesBar: some View {
        if showsShapeStyle {
            ColorPicker("", selection: strokeColorBinding, supportsOpacity: false)
                .labelsHidden()
                .help("Color")
            HStack(spacing: 4) {
                Image(systemName: "lineweight").foregroundStyle(.secondary)
                Slider(value: strokeWidthBinding, in: 1 ... 40).frame(width: 120)
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

    /// Show color/width controls when a shape tool is active or a colorable
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
            get: { min(model.strokeWidth, 40) },
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

    private func cropCGRect() -> CGRect? {
        model.crop.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    private func draw(_ ctx: GraphicsContext, _ f: Fit) {
        let imageRect = CGRect(x: f.ox, y: f.oy, width: f.dw, height: f.dh)
        ctx.draw(ctx.resolve(Image(decorative: model.rawImage, scale: 1)), in: imageRect)

        // Vector annotation previews (rect/arrow authorable; stamp/text/marker
        // still preview-only until E2). Baked on save.
        for a in model.annotations { drawAnnotationPreview(ctx, a, f) }

        // Redaction previews (blur) — gray placeholder; the real mosaic is baked
        // at flatten. Unselected ones get a faint dashed border.
        for a in model.annotations {
            guard case .blur(let b) = a else { continue }
            let r = toDisplay(CGRect(x: b.x, y: b.y, width: b.width, height: b.height), f)
            ctx.fill(Path(r), with: .color(.black.opacity(b.mode == .solid ? 0.85 : 0.55)))
            if b.id != model.selectedID {
                ctx.stroke(Path(r), with: .color(.white.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }

        // Selection chrome (Select tool only): accent bounding box + bottom-right
        // resize handle around the selected editable shape (rect/arrow/blur).
        if model.tool == .select, model.selectedID != nil, let b = model.boundsOfSelected() {
            let r = toDisplay(b, f)
            ctx.stroke(Path(r), with: .color(accent), lineWidth: 2)
            handle(ctx, at: CGPoint(x: r.maxX, y: r.maxY))
        }

        // Click-register marker preview — baked on save (WYSIWYG). Drawn before
        // the crop dim so a crop that excludes it dims it.
        if let click = model.step.click {
            let radius = (click.radius ?? Double(AnnotationStyle.clickMarkerRadius(
                width: model.imageSize.width, height: model.imageSize.height))) * f.s
            let c = toDisplay(CGPoint(x: click.image.x, y: click.image.y), f)
            let box = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            let color = Color(hex: AnnotationStyle.markerColor(for: model.step))
            ctx.fill(Path(ellipseIn: box), with: .color(color.opacity(0.18)))
            ctx.stroke(Path(ellipseIn: box), with: .color(color), lineWidth: max(2, radius * 0.22))
        }

        // Crop: dim everything outside the crop rect; show corner handles in the
        // Crop tool so it can be resized after drawing.
        if let crop = cropCGRect() {
            let cr = toDisplay(crop, f)
            var outside = Path(imageRect)
            outside.addRect(cr)
            ctx.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
            ctx.stroke(Path(cr), with: .color(accent), lineWidth: 2)
            if model.tool == .crop {
                for c in [CGPoint(x: cr.minX, y: cr.minY), CGPoint(x: cr.maxX, y: cr.minY),
                          CGPoint(x: cr.minX, y: cr.maxY), CGPoint(x: cr.maxX, y: cr.maxY)] {
                    handle(ctx, at: c)
                }
            }
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

    private func handle(_ ctx: GraphicsContext, at p: CGPoint) {
        let h = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
        ctx.fill(Path(roundedRect: h, cornerRadius: 2), with: .color(accent))
        ctx.stroke(Path(roundedRect: h, cornerRadius: 2), with: .color(.white), lineWidth: 1)
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
    /// (butt cap, head = max(12, strokeWidth*3), miter join) so preview == bake.
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
                case .moveCrop:
                    // Clamp the OFFSET (not the corners) so the crop keeps its
                    // size and stays fully in-image; an intersection clamp would
                    // shrink it against an edge instead of sliding it.
                    let img = model.imageSize
                    let dx = min(max(curImg.x - d.startImg.x, -d.origRect.minX), img.width - d.origRect.maxX)
                    let dy = min(max(curImg.y - d.startImg.y, -d.origRect.minY), img.height - d.origRect.maxY)
                    model.setCrop(d.origRect.offsetBy(dx: dx, dy: dy))
                case .resizeCrop:
                    if let fc = d.fixedCorner {
                        // Guard on the CLAMPED rect: over-dragging a flush-edge
                        // corner into the letterbox collapses the clamped extent,
                        // and setCrop nils a <1px crop — so only commit a valid one
                        // and keep the last good crop otherwise.
                        let r = model.clampedToImage(normalized(fc, curImg))
                        if r.width >= 1, r.height >= 1 { model.setCrop(r) }
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
            return Drag(mode: .createRect, startImg: startImg, origRect: .zero)
        case .arrow:
            return Drag(mode: .createArrow, startImg: startImg, origRect: .zero)
        case .redact:
            return Drag(mode: .createRedact, startImg: startImg, origRect: .zero)
        case .crop:
            // Resize (a corner handle) or move (inside) an existing crop; else
            // draw a new one.
            if let c = cropCGRect() {
                let hi = 10 / f.s
                let corners = [CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.maxX, y: c.minY),
                               CGPoint(x: c.minX, y: c.maxY), CGPoint(x: c.maxX, y: c.maxY)]
                if let gi = corners.firstIndex(where: { abs(startImg.x - $0.x) <= hi && abs(startImg.y - $0.y) <= hi }) {
                    return Drag(mode: .resizeCrop, startImg: startImg, origRect: c,
                                fixedCorner: corners[3 - gi]) // diagonal opposite stays put
                }
                if c.contains(startImg) {
                    return Drag(mode: .moveCrop, startImg: startImg, origRect: c)
                }
            }
            return Drag(mode: .createCrop, startImg: startImg, origRect: .zero)
        case .select:
            // Resize if the drag started on the selected shape's bottom-right
            // handle (±~8 pt tolerance).
            if let sel = model.boundsOfSelected() {
                let handleImg = 8 / f.s
                let corner = CGPoint(x: sel.maxX, y: sel.maxY)
                if abs(startImg.x - corner.x) <= handleImg, abs(startImg.y - corner.y) <= handleImg {
                    return Drag(mode: .resize, startImg: startImg, origRect: sel, original: model.selected)
                }
            }
            model.selectAnnotation(at: startImg)
            if let sel = model.boundsOfSelected() {
                return Drag(mode: .move, startImg: startImg, origRect: sel, original: model.selected)
            }
            return Drag(mode: .none, startImg: startImg, origRect: .zero)
        }
    }

    private func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
