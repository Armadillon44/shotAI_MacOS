import AppKit
import EditorKit
import ShotModel
import SwiftUI

/// Full-window annotation editor. Presented as an in-window overlay (not a
/// sheet). Windows-style layout: a vertical TOOL RAIL on the left (Select · Box
/// · Arrow · Redact · Number · Marker · Text · Crop), a contextual properties
/// row, and the canvas. Cancel/Save live in the window toolbar (ContentView).
/// Save re-flattens from the raw screenshot with redaction baked into the pixels.
struct EditorOverlay: View {
    @State var model: EditorModel

    // Drag state (image-px space).
    private struct Drag {
        enum Mode {
            case createRect, createArrow, createRedact, createCrop
            case placeStamp, placeMarker, placeText
            case move, resize, moveCrop, resizeCrop, none
        }
        var mode: Mode
        var startImg: CGPoint
        var origRect: CGRect              // selection/crop bounds at drag start
        var original: Annotation? = nil   // selection snapshot, for arrow scaling
        var fixedCorner: CGPoint? = nil   // resizeCrop: the corner held fixed
    }
    @State private var drag: Drag?
    @State private var draftRect: CGRect?               // box/redact/crop draft (image px)
    @State private var draftArrow: (CGPoint, CGPoint)?  // arrow draft (image px)

    // Inline text editing (state lives in the model so Save can flush it); the
    // focus flag is view-only.
    @FocusState private var textFocused: Bool

    /// Points→pixels for this display (2 on Retina). Used so "100%" means actual
    /// size (1 image pixel : 1 device pixel), not 1 image px : 1 point.
    @Environment(\.displayScale) private var displayScale

    /// When a crop is set, show ONLY the cropped region fit-to-view (matching the
    /// report + export). Cleared to adjust the crop on the full image.
    @State private var viewCropped = false

    /// Editor zoom. `.fit` fits the shown rect to the viewport (the DEFAULT, and
    /// re-fits on resize); `.absolute(z)` is a true scale where z = points per
    /// image pixel (so 1.0 = a real 100%, 1 image px : 1 pt). The canvas scrolls
    /// when the content exceeds the viewport.
    enum ZoomMode: Equatable { case fit; case absolute(CGFloat) }
    @State private var zoomMode: ZoomMode = .fit
    /// Latest canvas viewport, tracked so the zoom cluster (outside the canvas
    /// GeometryReader) can compute the fit scale + the true % label.
    @State private var viewportSize: CGSize = .zero

    /// Fit-to-viewport scale for the currently-shown rect (points per image px).
    private func fitScale(_ viewport: CGSize) -> CGFloat {
        let sr = shownRect
        guard viewport.width > 0, viewport.height > 0, sr.width > 0, sr.height > 0 else { return 1 }
        return min(viewport.width / sr.width, viewport.height / sr.height)
    }
    /// Current ABSOLUTE display scale (1.0 = true 100%).
    private var currentScale: CGFloat {
        switch zoomMode {
        case .fit: return fitScale(viewportSize)
        case .absolute(let z): return z
        }
    }
    private func setAbsoluteZoom(_ z: CGFloat) { zoomMode = .absolute(min(8, max(0.1, z))) }

    /// Live redaction-mosaic tiles, cached by region+block (a plain class so its
    /// mutation during the Canvas draw doesn't touch SwiftUI state).
    @State private var mosaic = MosaicCache()

    /// Drawing accent (rose) — for the annotations + their selection chrome.
    private let accent = Color(hex: AnnotationStyle.accent)
    /// App brand (violet) — for the editor chrome (active tool, tints).
    private let brand = Palette.accent

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
        .background(.ultraThickMaterial)
        .ignoresSafeArea(edges: [.horizontal, .bottom])
        // Open into the cropped view if the step already has a saved crop.
        .onAppear { viewCropped = model.crop != nil }
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
            toolButton(.number, "number", "Step Number")
            toolButton(.marker, "target", "Marker")
            toolButton(.text, "textformat", "Text")
            toolButton(.crop, "crop", "Crop")
            Spacer()
            zoomCluster
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(width: 56)
        .background(brand.opacity(0.08)) // subtle violet wash over the material
        .background(.thinMaterial)
    }

    /// Zoom −/label/+ pinned at the rail base. The label shows the TRUE scale;
    /// clicking it snaps to a real 100% (1:1), or back to Fit if already there.
    /// Scroll to pan.
    private var zoomCluster: some View {
        // True 100% (actual size) = 1 image px : 1 device px → s = 1/displayScale.
        let hundred = 1 / displayScale
        let percent = Int((currentScale * displayScale * 100).rounded())
        return VStack(spacing: 2) {
            zoomButton("plus.magnifyingglass", "Zoom in") { setAbsoluteZoom(currentScale * 1.25) }
            Button {
                // Snap to actual-size 100%, or back to Fit if already there.
                zoomMode = (percent == 100) ? .fit : .absolute(hundred)
            } label: {
                Text("\(percent)%")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Toggle 100% / Fit")
            zoomButton("minus.magnifyingglass", "Zoom out") { setAbsoluteZoom(currentScale / 1.25) }
        }
    }

    private func zoomButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 36, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func toolButton(_ tool: EditorModel.Tool, _ icon: String, _ label: String) -> some View {
        let active = model.tool == tool
        return Button {
            // Clear the selection when switching tools: the selection chrome only
            // shows in Select, and otherwise the color/size controls (which apply
            // to the selection AND set the new-shape default) would silently
            // mutate a now-invisible shape. Commit any open text first.
            if model.editingTextID != nil { commitText() }
            model.selectedID = nil
            model.tool = tool
            // Picking Crop shows the full image so the crop box can be adjusted;
            // keep the current zoom (matching Windows — resetting it here jumped
            // the view jarringly).
            if tool == .crop { viewCropped = false }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(active ? brand : Color.clear) // solid violet chip when active
        .foregroundStyle(active ? Color.white : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(label)
    }

    // MARK: - Top bar (contextual properties + editing actions)

    private var topBar: some View {
        // Centered options, FIXED height so the canvas never shifts as the
        // contextual controls appear/disappear.
        HStack(spacing: 12) {
            Spacer(minLength: 12)
            propertiesBar
            if model.selectedID != nil {
                Button(role: .destructive) { model.deleteSelected() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if model.crop != nil {
                Button(viewCropped ? "Show full" : "Fit to crop") { viewCropped.toggle(); zoomMode = .fit }
                Button("Clear crop") { model.crop = nil; viewCropped = false; zoomMode = .fit }
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        .background(brand.opacity(0.10)) // subtle violet band
        .background(.thinMaterial)
    }

    @ViewBuilder private var propertiesBar: some View {
        if showsColor {
            ColorPicker("", selection: strokeColorBinding, supportsOpacity: false)
                .labelsHidden()
                .help("Color")
        }
        if showsStrokeWidth {
            HStack(spacing: 4) {
                Image(systemName: "lineweight").foregroundStyle(.secondary)
                Slider(value: strokeWidthBinding, in: 1 ... 40).frame(width: 110)
            }
            .help("Line width")
        }
        if showsFontSize {
            HStack(spacing: 4) {
                Image(systemName: "textformat.size").foregroundStyle(.secondary)
                Slider(value: fontSizeBinding, in: 10 ... 160).frame(width: 110)
            }
            .help("Text size")
        }
        if model.selectedIsText {
            Button("Edit text") { beginEditingSelectedText() }
        }
        if model.tool == .redact || model.selectedIsBlur {
            Picker("Style", selection: $model.redactMode) {
                Text("Blur").tag(BlurAnnotation.Mode.pixelate)
                Text("Black box").tag(BlurAnnotation.Mode.solid)
            }
            .pickerStyle(.segmented).fixedSize()
            .onChange(of: model.redactMode) { model.applyStyleToSelected() }
            // Mosaic strength (bigger block = coarser = more obfuscation). Only
            // for Blur; the floor is minRedactBlock so text can't stay legible.
            if model.redactMode == .pixelate {
                HStack(spacing: 4) {
                    Image(systemName: "circle.grid.3x3.fill").foregroundStyle(.secondary)
                    Slider(value: redactBlockBinding,
                           in: Double(AnnotationStyle.minRedactBlock) ... 60).frame(width: 110)
                }
                .help("Blur strength")
            }
        }
    }

    private var showsColor: Bool {
        switch model.tool { case .box, .arrow, .number, .marker, .text: return true; default: break }
        return model.selectedIsColorable
    }
    private var showsStrokeWidth: Bool {
        model.tool == .box || model.tool == .arrow || model.selectedHasStrokeWidth
    }
    private var showsFontSize: Bool {
        model.tool == .text || model.selectedIsText
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

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { model.fontSize },
            set: { s in
                model.fontSize = s
                model.setSelectedFontSize(s)
            })
    }

    private var redactBlockBinding: Binding<Double> {
        Binding(
            get: { max(Double(AnnotationStyle.minRedactBlock), model.redactBlock) },
            set: { v in
                model.redactBlock = v
                model.applyStyleToSelected()
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
            // ScrollView so a zoomed image pans (trackpad / scroll wheel). On
            // macOS a ScrollView doesn't scroll on click-drag, so click-drag
            // still draws/moves annotations.
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in draw(ctx, f) }
                        .frame(width: f.frameW, height: f.frameH)
                        .contentShape(Rectangle())
                        .focusable() // so the canvas can receive key presses
                        .gesture(dragGesture(f))
                        .highPriorityGesture(SpatialTapGesture(count: 2).onEnded { value in
                            let img = toImage(value.location, f)
                            if let t = model.textAt(img) {
                                model.selectedID = t.id
                                beginEditingText(id: t.id, initial: t.text)
                            }
                        })
                        .onKeyPress(.escape) {
                            if model.editingTextID != nil { commitText(); return .handled }
                            model.selectedID = nil
                            model.tool = .select
                            return .handled
                        }
                        .onKeyPress(.delete) {
                            if model.editingTextID != nil { return .ignored } // let the field handle it
                            if model.selectedID != nil { model.deleteSelected(); return .handled }
                            return .ignored
                        }

                    if let id = model.editingTextID, let t = textAnnotation(id) {
                        let p = toDisplay(CGPoint(x: t.x, y: t.y), f)
                        // No horizontal padding + no font floor, so the field sits
                        // exactly where the text bakes (no jump on commit).
                        TextField("Text", text: $model.editingText)
                            .textFieldStyle(.plain)
                            .font(.custom("Helvetica", size: t.fontSize * f.s))
                            .foregroundStyle(Color(hex: t.fill))
                            .focused($textFocused)
                            .frame(minWidth: 30, alignment: .leading)
                            .fixedSize()
                            .background(Color.white.opacity(0.16))
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .stroke(Color(hex: "#4f46e5"), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .offset(x: p.x, y: p.y)
                            .onSubmit { commitText() }
                            .onChange(of: textFocused) { _, focused in if !focused { commitText() } }
                    }
                }
                .frame(width: f.frameW, height: f.frameH)
            }
            // Anchor to the center so zooming (which changes the content size)
            // keeps the middle of the view stable instead of jumping to top-left.
            .defaultScrollAnchor(.center)
            .background(Color.black.opacity(0.15))
            // Track the viewport so the zoom cluster can compute the fit scale +
            // the true % label from outside this GeometryReader.
            .onChange(of: geo.size, initial: true) { _, s in viewportSize = s }
        }
        .clipped()
    }

    // srx/sry = origin (image px) of the SHOWN rect (the crop when viewCropped,
    // else the whole image). ox/oy center the (possibly zoomed) content within a
    // frame of frameW×frameH = max(content, viewport) — so it centers when it
    // fits and the enclosing ScrollView pans it when it doesn't.
    private struct Fit {
        var s: CGFloat; var ox: CGFloat; var oy: CGFloat
        var dw: CGFloat; var dh: CGFloat; var srx: CGFloat; var sry: CGFloat
        var frameW: CGFloat; var frameH: CGFloat
    }

    /// The image region currently shown: the crop in viewCropped mode, else the
    /// whole image.
    private var shownRect: CGRect {
        (viewCropped ? cropCGRect() : nil) ?? CGRect(origin: .zero, size: model.imageSize)
    }

    private func fit(_ viewport: CGSize) -> Fit {
        let sr = shownRect
        // Absolute scale: .fit → fit the shown rect; .absolute → that true scale.
        let s: CGFloat
        switch zoomMode {
        case .fit: s = fitScale(viewport)
        case .absolute(let z): s = z
        }
        let dw = sr.width * s, dh = sr.height * s
        let frameW = max(dw, viewport.width), frameH = max(dh, viewport.height)
        return Fit(s: s, ox: (frameW - dw) / 2, oy: (frameH - dh) / 2,
                   dw: dw, dh: dh, srx: sr.minX, sry: sr.minY, frameW: frameW, frameH: frameH)
    }

    private func toImage(_ p: CGPoint, _ f: Fit) -> CGPoint {
        CGPoint(x: f.srx + (p.x - f.ox) / f.s, y: f.sry + (p.y - f.oy) / f.s)
    }
    private func toDisplay(_ r: CGRect, _ f: Fit) -> CGRect {
        CGRect(x: f.ox + (r.minX - f.srx) * f.s, y: f.oy + (r.minY - f.sry) * f.s,
               width: r.width * f.s, height: r.height * f.s)
    }
    private func toDisplay(_ p: CGPoint, _ f: Fit) -> CGPoint {
        CGPoint(x: f.ox + (p.x - f.srx) * f.s, y: f.oy + (p.y - f.sry) * f.s)
    }

    private func cropCGRect() -> CGRect? {
        model.crop.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    private func textAnnotation(_ id: String) -> TextAnnotation? {
        for a in model.annotations { if case .text(let t) = a, t.id == id { return t } }
        return nil
    }

    private func draw(_ ctx0: GraphicsContext, _ f: Fit) {
        var ctx = ctx0
        // In the cropped view, clip everything to the crop rect so out-of-crop
        // pixels don't bleed into the centered letterbox margins (keeps the
        // preview WYSIWYG with the exported crop).
        if viewCropped, let crop = cropCGRect() {
            ctx.clip(to: Path(toDisplay(crop, f)))
        }
        // Full image at its display rect — in viewCropped mode this extends past
        // the crop (clipped above); otherwise it fills the frame.
        let imageRect = toDisplay(CGRect(origin: .zero, size: model.imageSize), f)
        ctx.draw(ctx.resolve(Image(decorative: model.rawImage, scale: 1)), in: imageRect)

        for a in model.annotations { drawAnnotationPreview(ctx, a, f) }

        // Redaction previews — LIVE: solid = opaque black; blur = the actual
        // mosaic (downsampled tile of the underlying pixels, cached), so the user
        // sees the real effect. A draft/uncomputable region falls back to gray.
        // Unselected ones get a faint dashed border.
        for a in model.annotations {
            guard case .blur(let b) = a else { continue }
            let r = toDisplay(CGRect(x: b.x, y: b.y, width: b.width, height: b.height), f)
            if b.mode == .solid {
                ctx.fill(Path(r), with: .color(.black))
            } else if let tile = mosaic.tile(for: b, image: model.rawImage, imageSize: model.imageSize) {
                ctx.draw(ctx.resolve(Image(decorative: tile, scale: 1)), in: r)
            } else {
                ctx.fill(Path(r), with: .color(.black.opacity(0.55)))
            }
            if b.id != model.selectedID {
                ctx.stroke(Path(r), with: .color(.white.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }

        // Selection chrome (Select tool only): accent bounding box + a resize
        // handle for handle-resizable shapes; text gets a dashed outline (it's
        // sized via the font slider, not handles).
        if model.tool == .select, model.selectedID != nil, let b = model.boundsOfSelected() {
            let r = toDisplay(b, f)
            if model.selectedIsText {
                ctx.stroke(Path(r), with: .color(accent), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            } else {
                ctx.stroke(Path(r), with: .color(accent), lineWidth: 2)
                handle(ctx, at: CGPoint(x: r.maxX, y: r.maxY))
            }
        }

        // Editable click-register marker preview — baked on save (WYSIWYG).
        // Drawn before the crop dim so a crop that excludes it dims it.
        if let cp = model.clickPoint {
            let radius = model.clickEffectiveRadius() * f.s
            let c = toDisplay(cp, f)
            let box = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            let color = Color(hex: model.markerColor)
            ctx.fill(Path(ellipseIn: box), with: .color(color.opacity(0.18)))
            ctx.stroke(Path(ellipseIn: box), with: .color(color), lineWidth: max(2, radius * 0.22))
        }

        // Crop box + dim ONLY on the full image (viewCropped shows just the crop,
        // so no dim/box). Corner handles in the Crop tool for resizing.
        if !viewCropped, let crop = cropCGRect() {
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
            // Helvetica-Bold to match Flatten's baked digits.
            ctx.draw(ctx.resolve(Text(String(s.n))
                .font(.custom("Helvetica-Bold", size: radius * 1.15))
                .foregroundColor(Color(hex: s.textColor))), at: c)
        case .text(let t):
            if t.id == model.editingTextID { break } // shown by the inline TextField
            let at = toDisplay(CGPoint(x: t.x, y: t.y), f)
            ctx.draw(ctx.resolve(Text(t.text)
                .font(.custom("Helvetica", size: t.fontSize * f.s))
                .foregroundColor(Color(hex: t.fill))), at: at, anchor: .topLeading)
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

    // MARK: - Inline text editing

    private func beginEditingText(id: String, initial: String) {
        model.beginEditingText(id: id, initial: initial)
        // Focus on the next tick — setting it inline (before the field is in the
        // responder chain) misses.
        DispatchQueue.main.async { textFocused = true }
    }

    private func focusNewText() {
        // addText already opened the editor in the model; just take focus.
        DispatchQueue.main.async { textFocused = true }
    }

    private func beginEditingSelectedText() {
        if case .text(let t) = model.selected { beginEditingText(id: t.id, initial: t.text) }
    }

    private func commitText() {
        model.commitPendingText()
        textFocused = false
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
                    if model.selectedID == EditorModel.clickID {
                        let c0 = CGPoint(x: d.origRect.midX, y: d.origRect.midY)
                        model.setClickPoint(CGPoint(x: c0.x + (curImg.x - d.startImg.x),
                                                    y: c0.y + (curImg.y - d.startImg.y)))
                    } else if let orig = d.original {
                        model.moveSelected(orig, dx: curImg.x - d.startImg.x, dy: curImg.y - d.startImg.y)
                    }
                case .resize:
                    if model.selectedIsCircle {
                        // Center-anchored radius so the handle tracks the pointer.
                        let center = CGPoint(x: d.origRect.midX, y: d.origRect.midY)
                        model.setSelectedRadius(max(abs(curImg.x - center.x), abs(curImg.y - center.y)))
                    } else if let orig = d.original {
                        model.resizeSelected(orig, to: normalized(CGPoint(x: d.origRect.minX, y: d.origRect.minY), curImg))
                    }
                case .moveCrop:
                    let img = model.imageSize
                    let dx = min(max(curImg.x - d.startImg.x, -d.origRect.minX), img.width - d.origRect.maxX)
                    let dy = min(max(curImg.y - d.startImg.y, -d.origRect.minY), img.height - d.origRect.maxY)
                    model.setCrop(d.origRect.offsetBy(dx: dx, dy: dy))
                case .resizeCrop:
                    if let fc = d.fixedCorner {
                        let r = model.clampedToImage(normalized(fc, curImg))
                        if r.width >= 1, r.height >= 1 { model.setCrop(r) }
                    }
                case .placeStamp, .placeMarker, .placeText, .none:
                    break // click-to-place happens on release
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
                        if let r = draftRect, r.width >= 5, r.height >= 5 {
                            model.setCrop(r)
                            // Once cropped, fit the view to the crop + drop to Select.
                            if model.crop != nil { viewCropped = true; zoomMode = .fit; model.tool = .select }
                        }
                    case .createArrow:
                        if let (a, b) = draftArrow, hypot(b.x - a.x, b.y - a.y) >= 5 { model.addArrow(from: a, to: b) }
                    case .placeStamp:
                        model.addStamp(at: d.startImg)
                    case .placeMarker:
                        model.addMarker(at: d.startImg)
                    case .placeText:
                        _ = model.addText(at: d.startImg) // opens the inline editor
                        focusNewText()
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
        // A press anywhere while editing text commits the edit first.
        if model.editingTextID != nil { commitText() }
        switch model.tool {
        case .box:
            return Drag(mode: .createRect, startImg: startImg, origRect: .zero)
        case .arrow:
            return Drag(mode: .createArrow, startImg: startImg, origRect: .zero)
        case .redact:
            return Drag(mode: .createRedact, startImg: startImg, origRect: .zero)
        case .number:
            return Drag(mode: .placeStamp, startImg: startImg, origRect: .zero)
        case .marker:
            return Drag(mode: .placeMarker, startImg: startImg, origRect: .zero)
        case .text:
            return Drag(mode: .placeText, startImg: startImg, origRect: .zero)
        case .crop:
            if let c = cropCGRect() {
                let hi = 10 / f.s
                let corners = [CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.maxX, y: c.minY),
                               CGPoint(x: c.minX, y: c.maxY), CGPoint(x: c.maxX, y: c.maxY)]
                if let gi = corners.firstIndex(where: { abs(startImg.x - $0.x) <= hi && abs(startImg.y - $0.y) <= hi }) {
                    return Drag(mode: .resizeCrop, startImg: startImg, origRect: c, fixedCorner: corners[3 - gi])
                }
                if c.contains(startImg) {
                    return Drag(mode: .moveCrop, startImg: startImg, origRect: c)
                }
            }
            return Drag(mode: .createCrop, startImg: startImg, origRect: .zero)
        case .select:
            // Resize if the drag started near a handle-resizable selection's
            // bottom-right handle. Generous tolerance so the corner is easy to
            // grab — important for redactions, where a miss lands in the body and
            // becomes a size-preserving move (which reads as "can't resize").
            if model.selectedIsResizable, let sel = model.boundsOfSelected() {
                let handleImg = 14 / f.s
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

/// Produces + caches the live pixelate-mosaic tile for a redaction region: crop
/// the raw pixels, average-downsample to region/block (drawn back scaled-up +
/// smoothed by the Canvas), mirroring Flatten's bake so the preview matches the
/// saved result. Not @Observable — cached lookups happen inside the Canvas draw.
private final class MosaicCache {
    private var cache: [String: CGImage] = [:]

    func tile(for b: BlurAnnotation, image: CGImage, imageSize: CGSize) -> CGImage? {
        let key = "\(b.id):\(Int(b.x.rounded())):\(Int(b.y.rounded())):\(Int(b.width.rounded())):\(Int(b.height.rounded())):\(Int(b.blockSize.rounded()))"
        if let hit = cache[key] { return hit }
        guard let t = Self.compute(b, image, imageSize) else { return nil }
        if cache.count > 80 { cache.removeAll(keepingCapacity: true) } // bound during drags
        cache[key] = t
        return t
    }

    private static func compute(_ b: BlurAnnotation, _ image: CGImage, _ imageSize: CGSize) -> CGImage? {
        let x0 = max(0, min(b.x, imageSize.width))
        let y0 = max(0, min(b.y, imageSize.height))
        let x1 = max(0, min(b.x + b.width, imageSize.width))
        let y1 = max(0, min(b.y + b.height, imageSize.height))
        let w = Int((x1 - x0).rounded()), h = Int((y1 - y0).rounded())
        guard w >= 1, h >= 1,
              let region = image.cropping(to: CGRect(x: x0, y: y0, width: CGFloat(w), height: CGFloat(h)))
        else { return nil }
        // Match the bake: block floored at minRedactBlock so text can't stay legible.
        let block = max(Double(AnnotationStyle.minRedactBlock), b.blockSize < 1 ? 12 : b.blockSize)
        let sw = max(1, Int((Double(w) / block).rounded()))
        let sh = max(1, Int((Double(h) / block).rounded()))
        guard let small = CGContext(
            data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        small.interpolationQuality = .high // averaging downsample
        small.draw(region, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        return small.makeImage()
    }
}
