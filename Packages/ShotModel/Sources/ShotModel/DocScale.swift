import Foundation

/// Per-project document scale: how wide the document column renders, in the
/// report and in every export.
///
/// **This is a cross-platform contract** (`Armadillon44/shotAI_MacOS#83`, shipped
/// first on Windows in `Armadillon44/shotAI#72`). The field name, the range, the
/// detents and the snap algorithm must match the Windows implementation exactly,
/// or one project renders at two different widths depending on which app opened
/// it last.
///
/// Every derived width lives HERE, deliberately. `HTMLExport.swift` already
/// carried a "Keep in sync with DOC_CSS" comment for the 738px image ceiling;
/// with a scale in play that comment would have become two drifting derivations.
public enum DocScale {
    public static let min = 0.65
    public static let max = 1.25
    public static let `default` = 1.0
    /// The 13 legal values. Exact 2-decimal doubles: a `0.7000000000000001` in a
    /// manifest would fail an equality check on the other platform.
    public static let detents: [Double] = [0.65, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95,
                                           1.00, 1.05, 1.10, 1.15, 1.20, 1.25]

    /// Snap an arbitrary value to a legal detent. **Normative — do not
    /// reimplement from an intuition about how ties should break.**
    ///
    /// Exact midpoints are floating-point sensitive and no formulation is
    /// naturally tie-safe. `0.825 * 100` is `82.5` and rounds UP to `0.85`, while
    /// `1.025 * 100` is `102.49999999999999` and rounds DOWN to `1.00`. That
    /// asymmetry is a float artifact and is INTENTIONAL: a Windows cross-check
    /// comparing two plausible formulations is what surfaced it, and they
    /// disagree precisely at `1.025`. The steps below are the contract.
    ///
    /// Note the deliberate split for out-of-range input:
    /// - not a finite number → `1.0` (missing, null, NaN, ±Infinity, wrong type)
    /// - a finite number outside the range → **clamped**, not defaulted. A `3.0`
    ///   written by some future build means "as large as possible", not "normal";
    ///   defaulting it would silently discard that intent.
    public static func clamp(_ v: Double?) -> Double {
        guard let v, v.isFinite else { return `default` }
        var pct = (v * 100).rounded()
        pct = Swift.min(125, Swift.max(65, pct))
        pct = (pct / 5).rounded() * 5
        return pct / 100
    }

    /// Read the scale off a manifest, already snapped.
    public static func of(_ manifest: ProjectManifest) -> Double { clamp(manifest.displayScale) }

    /// Index into `detents` of the detent a value snaps to.
    ///
    /// This is the ONLY place `Double` equality against `detents` is performed.
    /// It is sound because `clamp` builds its result as `pct / 100` from the same
    /// whole-number percents the literals spell, and IEEE division of exact
    /// integers is correctly rounded — but that is a bit-pattern argument, not
    /// something a reader should have to re-derive at each call site, and a
    /// stepper that silently fell back to 100% would be a quiet bug rather than
    /// a loud one. `DocScaleTests.detentIndexRoundTrips` asserts it.
    public static func detentIndex(of v: Double?) -> Int {
        let snapped = clamp(v)
        return detents.firstIndex(of: snapped)
            ?? detents.firstIndex(of: `default`)!
    }

    /// The detent at `i`, clamped to the ends — what a step off either end lands on.
    public static func detent(at i: Int) -> Double {
        detents[Swift.min(Swift.max(i, 0), detents.count - 1)]
    }

    // MARK: Derived widths
    //
    // Chrome and font sizes do NOT scale, so the image ceiling is RE-DERIVED from
    // the scaled column, never multiplied. `htmlImageMax(s) != 738 * s` — they
    // agree only at s == 1, which is exactly what lets the wrong version pass a
    // spot check.

    /// HTML content column; `.doc` adds `docPadding` per side.
    public static let htmlColumnBase: Double = 816
    /// The fixed horizontal padding `.doc` adds OUTSIDE the column, per side.
    /// Chrome: it does not scale.
    public static let docPadding: Double = 32
    /// Report frame (the outer `.frame(maxWidth:)`) — the same box as the HTML
    /// `.doc`, so at 100% this is still 880.
    public static let reportFrameBase: Double = htmlColumnBase + 2 * docPadding
    /// Report content column (`ReportPresentation.baseWidth`) — the SAME column
    /// the HTML uses. These were 880/820 against the HTML's 816, which is how
    /// the report came to render its cards and figures wider than the export.
    public static let reportColumnBase: Double = htmlColumnBase
    /// "HTML for Word" body width.
    public static let plainBodyBase: Double = 800
    /// Fixed step chrome subtracted from the column: 30 badge + 16 gap + 32 card
    /// padding. Does NOT scale.
    public static let stepChrome: Double = 78

    /// The report frame, derived — NOT `880 * s`.
    ///
    /// The doc padding is chrome and does not scale, so multiplying the whole
    /// 880 scaled the padding too. That is the second half of the same
    /// re-derive-don't-multiply rule as `htmlImageMax`, and breaking it made the
    /// report drift wider than the export as the scale rose: +18px at 100%,
    /// +34px at 125%. Agreeing at 100% is exactly what let it pass a spot check.
    public static func reportFrame(_ s: Double) -> Double {
        Double(htmlColumn(s)) + 2 * docPadding
    }
    public static func reportColumn(_ s: Double) -> Double { Double(htmlColumn(s)) }
    public static func htmlColumn(_ s: Double) -> Int { Int((htmlColumnBase * s).rounded()) }
    public static func plainBody(_ s: Double) -> Int { Int((plainBodyBase * s).rounded()) }

    /// The report column actually used: the scaled target, capped by the space
    /// available.
    ///
    /// Extracted so the derivation is testable. The geometry READ cannot be unit
    /// tested, but this is the part that can be got wrong later — and it must
    /// take the space OFFERED, never the content's own measured width. Measuring
    /// the content creates a feedback loop (the container sizes to its widest
    /// child, which sizes itself from the measured column) that pins the whole
    /// feature at whatever it settles on at 100%.
    public static func reportColumnFitting(_ s: Double, available: Double) -> Double {
        Swift.min(reportFrame(s), Swift.max(1, available))
    }

    /// Displayed image ceiling inside a step card. Re-derived, never multiplied.
    public static func htmlImageMax(_ s: Double) -> Int { htmlColumn(s) - Int(stepChrome) }

    /// Horizontal chrome between the report FRAME and the step figure: doc
    /// padding (32·2) + the badge rail (46) + step-card padding (16·2).
    ///
    /// Equal to `2 * docPadding + stepChrome` by construction, which is what
    /// makes `reportFrame(s) - reportFigureChrome == htmlImageMax(s)` hold at
    /// every scale — the report figure and the exported figure are the same
    /// width. `DocScaleTests.reportFigureMatchesExport` pins it.
    ///
    /// The SwiftUI report must actually SPEND this: 32pt outer padding per side,
    /// a 32 + 14 badge rail, and 16pt step-card padding per side. It previously
    /// spent 24 / 46 / 14, which is the other half of the drift.
    public static let reportFigureChrome: Double = 2 * docPadding + stepChrome
    /// The @2x resample target from the shared contract.
    ///
    /// **macOS does not consume this, deliberately.** `HTMLExport` embeds at 1x
    /// (#64): resampling to 2x was measured to save nothing at all, because
    /// interpolation blurs the flat colour runs screenshots are made of and PNG
    /// then compresses the result worse. The accepted tradeoff is that exported
    /// images read slightly softer than the in-app report on a Retina display.
    ///
    /// Kept because it is part of the cross-platform spec and is the number to
    /// compare against if that decision is ever revisited — not because anything
    /// here calls it.
    public static func embedTarget(_ s: Double) -> Int { 2 * htmlImageMax(s) }
}
