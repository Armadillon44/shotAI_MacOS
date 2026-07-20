import SwiftUI

// First-run coach-mark tour — the macOS port of the Windows Tour.tsx (R2). A
// sequence of floating bubbles that spotlight the real Home controls and teach
// the capture → annotate → AI → export path. Fires once (persisted
// `hasSeenTour`), skippable (Skip / Esc / click-outside), replayable from
// Settings ▸ General. macOS has no in-window Settings gear (it's ⌘,), so the
// final step is centered rather than anchored.

// MARK: - Anchors

/// Home controls the tour can spotlight. Published by `.tourAnchor(_:)` and
/// resolved against the overlay's geometry.
enum TourAnchor: Hashable {
    case hero, capture, mode
}

struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourAnchor: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [TourAnchor: Anchor<CGRect>],
        nextValue: () -> [TourAnchor: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publish this view's bounds so the first-run tour can spotlight it.
    func tourAnchor(_ id: TourAnchor) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

// MARK: - Steps

struct TourStep {
    let anchor: TourAnchor?
    let headline: String
    let body: String
    var showPill: Bool = false
}

/// The 5 steps, ported from Windows `Tour.tsx` (shortcut + Settings wording
/// adapted for macOS).
let tourSteps: [TourStep] = [
    TourStep(
        anchor: .hero,
        headline: "Welcome to shotAI",
        body: "Record a process, mark it up, and let Claude turn it into a step-by-step guide — an SOP — you can export and share. It all starts here."),
    TourStep(
        anchor: .capture,
        headline: "Capture your process",
        body: "Click “Capture” to start recording. shotAI hides while you work — every click captures a screenshot and becomes a numbered step. Building from images or text instead? Use “Empty project”."),
    TourStep(
        anchor: .mode,
        headline: "Choose what gets captured",
        body: "“Screen” grabs a full monitor each step — the most predictable choice, and the default. Pick “Window” or “Area” to narrow it down. “Auto” guesses per click and can grab extra context."),
    TourStep(
        anchor: nil,
        headline: "Recording? Just click",
        body: "Once recording, a small pill stays on top. Switch to any app and click anything to capture a step — or press ⇧⌘S. Pause to stop capturing, Stop to finish, the red ✕ to discard.",
        showPill: true),
    TourStep(
        anchor: nil,
        headline: "Let Claude write the guide",
        body: "When you’re ready for AI-written instructions, open Settings (⌘,) ▸ AI and add an Anthropic API key (your organization may provide one, or create your own — billed per use). Then use “Generate SOP with Claude”."),
]

// MARK: - Overlay

private let bubbleW: CGFloat = 330
private let bubbleGap: CGFloat = 14

struct TourOverlay: View {
    let anchors: [TourAnchor: Anchor<CGRect>]
    let proxy: GeometryProxy
    let onFinish: () -> Void

    @State private var i = 0
    @State private var bubbleH: CGFloat = 180
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var step: TourStep { tourSteps[min(i, tourSteps.count - 1)] }
    private var spot: CGRect? {
        guard let a = step.anchor, let anchor = anchors[a] else { return nil }
        return proxy[anchor]
    }

    private var stepAnim: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.18) }
    private func next() {
        if i >= tourSteps.count - 1 { onFinish() } else { withAnimation(stepAnim) { i += 1 } }
    }
    private func back() { if i > 0 { withAnimation(stepAnim) { i -= 1 } } }

    var body: some View {
        let size = proxy.size
        ZStack(alignment: .topLeading) {
            // Dim + spotlight cutout (full dim when the step is centered).
            dim
                .contentShape(Rectangle())
                .onTapGesture { onFinish() }   // click-outside skips

            if let spot {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: spot.width + 12, height: spot.height + 12)
                    .position(x: spot.midX, y: spot.midY)
                    .allowsHitTesting(false)
            }

            bubble
                .frame(width: bubbleW)
                .background(bubbleHeightReader)
                .position(bubbleCenter(in: size))
        }
        .ignoresSafeArea()
    }

    // MARK: dim

    @ViewBuilder private var dim: some View {
        if let spot {
            Color.black.opacity(0.5).reverseMask {
                RoundedRectangle(cornerRadius: 10)
                    .frame(width: spot.width + 12, height: spot.height + 12)
                    .position(x: spot.midX, y: spot.midY)
            }
        } else {
            Color.black.opacity(0.5)
        }
    }

    // MARK: bubble

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Step \(i + 1) of \(tourSteps.count)")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(Color.accentColor)
            Text(step.headline)
                .font(.system(size: 17, weight: .bold))
            if step.showPill { pillMock }
            Text(step.body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                dots
                Spacer()
                Button("Skip") { onFinish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)   // Esc
                if i > 0 { Button("Back") { back() }.buttonStyle(.plain) }
                Button(i == tourSteps.count - 1 ? "Done" : "Next") { next() }
                    .buttonStyle(.borderedProminent)
                // NB: intentionally no .defaultAction (Return) shortcut — the Home
                // name field can retain focus behind the dim, and Return would then
                // also fire its onSubmit (starting a capture). Click Next to advance.
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.top, 2)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(tourSteps.indices, id: \.self) { d in
                Circle()
                    .fill(d == i ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
    }

    /// Static mini recording-pill illustration for the "Recording? Just click"
    /// step (the real pill doesn't exist until a session is live).
    private var pillMock: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: "#34d399")).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Capturing · 3").font(.system(size: 11, weight: .semibold))
                Text("Click anything · ⇧⌘S").font(.system(size: 9)).foregroundStyle(Color(hex: "#aeb4c7"))
            }
            Spacer(minLength: 6)
            pillChip("Pause", bg: "#2c3142", fg: "#f4f5f7")
            pillChip("Stop", bg: "#6344f1", fg: "#ffffff")
            pillChip("✕", bg: "#2c3142", fg: "#fca5a5")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: "#1f2330")))
        .frame(maxWidth: .infinity)
    }

    private func pillChip(_ t: String, bg: String, fg: String) -> some View {
        Text(t)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color(hex: fg))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: bg)))
    }

    // MARK: geometry

    /// Below the anchor if there's room, else above; horizontally clamped.
    /// Centered when the step has no anchor.
    private func bubbleCenter(in size: CGSize) -> CGPoint {
        guard let spot else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let below = spot.maxY + bubbleGap + bubbleH + 16 <= size.height
        let cx = min(max(spot.midX, 12 + bubbleW / 2), size.width - 12 - bubbleW / 2)
        let cy = below
            ? spot.maxY + bubbleGap + bubbleH / 2
            : spot.minY - bubbleGap - bubbleH / 2
        return CGPoint(x: cx, y: max(bubbleH / 2 + 8, cy))
    }

    private var bubbleHeightReader: some View {
        GeometryReader { g in
            Color.clear.preference(key: BubbleHeightKey.self, value: g.size.height)
        }
        .onPreferenceChange(BubbleHeightKey.self) { bubbleH = $0 }
    }
}

private struct BubbleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 180
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private extension View {
    /// Punch a hole in `self` shaped like `mask` (for the spotlight cutout).
    func reverseMask<M: View>(@ViewBuilder _ mask: () -> M) -> some View {
        self.mask {
            Rectangle().overlay(mask().blendMode(.destinationOut))
        }
    }
}
