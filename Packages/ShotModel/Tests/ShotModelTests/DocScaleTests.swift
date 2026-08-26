import Foundation
import Testing
@testable import ShotModel

/// #83 — the document-scale contract, shared byte-for-byte with the Windows
/// client. Every number here is normative, taken from the parity spec; if one of
/// these changes, the same project renders at two different widths depending on
/// which app opened it last.
@Suite struct DocScaleContract {

    /// The normative input→output table, row by row.
    @Test(arguments: [
        (0.65, 0.65), (1.0, 1.0), (1.25, 1.25),
        (0.824, 0.80), (0.825, 0.85), (0.826, 0.85),
        (1.024, 1.00),
        // A float artifact, and INTENTIONAL: 1.025 * 100 is 102.49999999999999,
        // so this midpoint rounds DOWN where 0.825 rounds up. Two plausible
        // formulations disagree exactly here, which is why the algorithm rather
        // than a description is the contract.
        (1.025, 1.00),
        (1.026, 1.05), (0.775, 0.80), (1.125, 1.15),
        // Out of range CLAMPS, it does not default: a 3.0 from a future build
        // means "as large as possible", not "normal".
        (0.6, 0.65), (1.3, 1.25), (42.0, 1.25), (-42.0, 0.65), (0.0, 0.65),
    ])
    func snapTable(input: Double, expected: Double) {
        #expect(DocScale.clamp(input) == expected)
    }

    /// Non-finite and absent DEFAULT rather than clamp — the deliberate split.
    @Test func nonFiniteDefaults() {
        #expect(DocScale.clamp(nil) == 1.0)
        #expect(DocScale.clamp(Double.nan) == 1.0)
        #expect(DocScale.clamp(.infinity) == 1.0)
        #expect(DocScale.clamp(-.infinity) == 1.0)
    }

    /// Idempotent, so a read-write-read round trip cannot drift.
    @Test func clampIsIdempotent() {
        for v in stride(from: -1.0, through: 3.0, by: 0.013) {
            #expect(DocScale.clamp(DocScale.clamp(v)) == DocScale.clamp(v))
        }
    }

    /// Always lands on one of the 13 detents, for ANY input.
    @Test func alwaysADetent() {
        for v in stride(from: -1.0, through: 3.0, by: 0.007) {
            #expect(DocScale.detents.contains(DocScale.clamp(v)))
        }
        #expect(DocScale.detents.count == 13)
    }

    /// Detents must be exact 2-decimal doubles — a 0.7000000000000001 in a
    /// manifest fails an equality check on the other platform.
    @Test func detentsAreExact() {
        for d in DocScale.detents {
            #expect(DocScale.clamp(d) == d)
            #expect((d * 100).rounded() / 100 == d)
        }
    }

    /// The derived-width table from the spec. Chrome does NOT scale, so the image
    /// ceiling is re-derived — `htmlImageMax(s) != 738 * s`, and they agree only
    /// at s == 1, which is what lets the wrong version pass a spot check.
    @Test(arguments: [
        (0.65, 572.0, 533.0, 530, 452, 904, 520),
        (0.70, 616.0, 574.0, 571, 493, 986, 560),
        (0.75, 660.0, 615.0, 612, 534, 1068, 600),
        (0.80, 704.0, 656.0, 653, 575, 1150, 640),
        (0.85, 748.0, 697.0, 694, 616, 1232, 680),
        (0.90, 792.0, 738.0, 734, 656, 1312, 720),
        (0.95, 836.0, 779.0, 775, 697, 1394, 760),
        (1.00, 880.0, 820.0, 816, 738, 1476, 800),
        (1.05, 924.0, 861.0, 857, 779, 1558, 840),
        (1.10, 968.0, 902.0, 898, 820, 1640, 880),
        (1.15, 1012.0, 943.0, 938, 860, 1720, 920),
        (1.20, 1056.0, 984.0, 979, 901, 1802, 960),
        (1.25, 1100.0, 1025.0, 1020, 942, 1884, 1000),
    ])
    func derivedWidths(s: Double, frame: Double, column: Double,
                       htmlCol: Int, img: Int, embed: Int, plain: Int) {
        #expect(DocScale.reportFrame(s) == frame)
        #expect(DocScale.reportColumn(s) == column)
        #expect(DocScale.htmlColumn(s) == htmlCol)
        #expect(DocScale.htmlImageMax(s) == img)
        #expect(DocScale.embedTarget(s) == embed)
        #expect(DocScale.plainBody(s) == plain)
    }

    /// The multiplication trap, stated as a test so nobody "simplifies" it back.
    @Test func imageCeilingIsRederivedNotMultiplied() {
        #expect(DocScale.htmlImageMax(1.0) == 738)
        for s in DocScale.detents where s != 1.0 {
            #expect(DocScale.htmlImageMax(s) != Int((738.0 * s).rounded()),
                    "738 * s agrees with the correct derivation only at s == 1")
        }
    }

    /// If display and embed drift apart, an export silently stops being @2x and
    /// its text softens with nothing failing.
    @Test func embedIsAlwaysExactlyTwiceDisplay() {
        for s in DocScale.detents {
            #expect(DocScale.embedTarget(s) == 2 * DocScale.htmlImageMax(s))
        }
    }

    /// 1.0 must reproduce every pre-feature constant exactly. This is the
    /// compatibility promise.
    @Test func unityMatchesThePreFeatureConstants() {
        #expect(DocScale.reportFrame(1.0) == 880)
        #expect(DocScale.reportColumn(1.0) == ReportPresentation.baseWidth)
        #expect(DocScale.htmlImageMax(1.0) == 738)
        #expect(DocScale.plainBody(1.0) == 800)
    }

    /// Absent on the manifest reads as 1.0 and stays off disk.
    @Test func absentIsTheNormalState() throws {
        var m = ProjectManifest(id: "p", title: "t", createdAt: "2026-01-01",
                                updatedAt: "2026-01-01", steps: [])
        #expect(DocScale.of(m) == 1.0)
        let json = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        #expect(!json.contains("displayScale"))

        m.displayScale = 3.0        // a future build's "as large as possible"
        #expect(DocScale.of(m) == 1.25, "clamped, not defaulted")
    }
}

/// Store behaviour for the scale — the write side of the contract.
@Suite struct DocScaleStore {
    private func project() async throws -> (ProjectStore, String) {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("docscale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        return (store, try await store.createProject(title: "T").path)
    }

    @Test func writesSnappedAndReadsBack() async throws {
        let (store, path) = try await project()
        _ = try await store.setDisplayScale(at: path, 0.83)   // off-detent
        let m = try await store.openProject(at: path).manifest
        #expect(m.displayScale == 0.85, "clamped on write, not just on read")
        #expect(DocScale.of(m) == 0.85)
    }

    /// The default is stored as ABSENT, so a project that never touches the
    /// slider stays byte-identical to one written before the feature existed.
    @Test func defaultIsWrittenAsAbsent() async throws {
        let (store, path) = try await project()
        _ = try await store.setDisplayScale(at: path, 1.25)
        _ = try await store.setDisplayScale(at: path, 1.0)
        let m = try await store.openProject(at: path).manifest
        #expect(m.displayScale == nil, "back to default means the key is gone")
        let json = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        #expect(!json.contains("displayScale"))
    }

    /// A no-op must not write. `mutate` bumps `updatedAt` unconditionally, so
    /// saving an unchanged value re-dates the project and throws it to the top of
    /// the home list under "Today" — the bug Windows shipped.
    @Test func noOpDoesNotWriteOrReDateTheProject() async throws {
        let (store, path) = try await project()
        _ = try await store.setDisplayScale(at: path, 0.90)
        let before = try await store.openProject(at: path).manifest.updatedAt

        #expect(try await store.setDisplayScale(at: path, 0.90) == nil, "no change, no write")
        // An off-detent value that SNAPS to the current one is still a no-op.
        #expect(try await store.setDisplayScale(at: path, 0.89) == nil)

        let after = try await store.openProject(at: path).manifest.updatedAt
        #expect(after == before, "updatedAt must not move")
    }

    @Test func outOfRangeWriteIsClampedNotRejected() async throws {
        let (store, path) = try await project()
        _ = try await store.setDisplayScale(at: path, 99)
        #expect(try await store.openProject(at: path).manifest.displayScale == 1.25)
    }
}

/// The report figure must honour the scale in BOTH dimensions.
@Suite struct DocScaleViewport {
    /// A wide capture grows with the column.
    @Test func widthGrowsWithScale() {
        let s = ProjectStep(id: "a", order: 0, kind: .shot, screenshot: "a.png", trigger: .click)
        let small = ReportPresentation.viewport(for: s, imagePixelSize: (2400, 1200), docScale: 0.65)
        let unity = ReportPresentation.viewport(for: s, imagePixelSize: (2400, 1200), docScale: 1.0)
        let big = ReportPresentation.viewport(for: s, imagePixelSize: (2400, 1200), docScale: 1.25)
        #expect(small!.boxWidth < unity!.boxWidth)
        #expect(big!.boxWidth > unity!.boxWidth)
        #expect(unity!.boxWidth == 820, "1.0 reproduces the pre-feature column exactly")
    }

    /// The HEIGHT cap scales too. A portrait capture is height-limited, so
    /// without this the extra column width buys it nothing and the slider looks
    /// inert on exactly the captures that need it most.
    @Test func heightCapScalesForAPortraitCapture() {
        let s = ProjectStep(id: "a", order: 0, kind: .shot, screenshot: "a.png", trigger: .click)
        let unity = ReportPresentation.viewport(for: s, imagePixelSize: (600, 2000), docScale: 1.0)
        let big = ReportPresentation.viewport(for: s, imagePixelSize: (600, 2000), docScale: 1.25)
        #expect(unity!.boxHeight == 600, "the pre-feature height cap")
        #expect(big!.boxHeight > unity!.boxHeight, "height must scale, not stay pinned at 600")
    }

    /// A measured column narrower than the scaled base still wins, so a figure
    /// can never overflow the card that actually contains it.
    @Test func measuredColumnStillWins() {
        let s = ProjectStep(id: "a", order: 0, kind: .shot, screenshot: "a.png", trigger: .click)
        let v = ReportPresentation.viewport(for: s, imagePixelSize: (2400, 1200),
                                            fitWidth: 400, docScale: 1.25)
        #expect(v!.boxWidth <= 400)
    }
}

/// The report column derivation. The geometry READ cannot be unit tested, but
/// this is the arithmetic around it — and getting it wrong is what pinned the
/// feature: a column measured off the CONTENT feeds back on itself, because the
/// container sizes to its widest child and that child sizes itself from the
/// column. Taking the space OFFERED breaks the loop.
@Suite struct DocScaleReportColumn {
    /// Given room, the column is the scaled target — this is what makes the
    /// slider do anything above 100%.
    @Test func growsWithScaleWhenThereIsRoom() {
        #expect(DocScale.reportColumnFitting(1.00, available: 2000) == 880)
        #expect(DocScale.reportColumnFitting(1.25, available: 2000) == 1100)
        #expect(DocScale.reportColumnFitting(0.65, available: 2000) == 572)
    }

    /// A window narrower than the target still wins, so the report never
    /// overflows the space it was given.
    @Test func availableWidthCapsTheTarget() {
        #expect(DocScale.reportColumnFitting(1.25, available: 900) == 900)
        #expect(DocScale.reportColumnFitting(1.00, available: 600) == 600)
    }

    /// Degenerate geometry (a zero-size first layout pass) must not produce a
    /// zero or negative column.
    @Test func neverCollapsesToZero() {
        #expect(DocScale.reportColumnFitting(1.0, available: 0) >= 1)
        #expect(DocScale.reportColumnFitting(1.0, available: -50) >= 1)
    }
}

// MARK: - Detent lookup (#83 manual-entry control)

/// The stepper and the percent field both turn a scale back into a detent INDEX
/// so they can move by one. That lookup is `Double` equality, safe only because
/// `clamp` and the `detents` literals produce identical bit patterns. Asserted
/// here rather than trusted: a regression would not throw, it would silently
/// snap every step back to 100%.
@Suite struct DocScaleDetentLookup {
    @Test func indexRoundTripsForEveryDetent() {
        for (i, d) in DocScale.detents.enumerated() {
            #expect(DocScale.detentIndex(of: d) == i, "detent \(d)")
        }
    }

    /// The same lookup reached the way the text field reaches it: an integer
    /// percent the user typed, divided by 100.
    @Test func indexRoundTripsFromTypedPercent() {
        for (i, d) in DocScale.detents.enumerated() {
            let pct = Int((d * 100).rounded())
            #expect(DocScale.detentIndex(of: Double(pct) / 100) == i, "typed \(pct)")
        }
    }

    /// Typed values that are not detents snap the way `clamp` snaps, and a
    /// finite out-of-range value clamps to an end rather than defaulting to 100%.
    @Test(arguments: [(0.83, 0.85), (2.00, 1.25), (0.10, 0.65), (1.00, 1.00)])
    func snapsAndClamps(input: Double, expected: Double) {
        #expect(DocScale.detent(at: DocScale.detentIndex(of: input)) == expected)
    }

    /// Not-a-finite-number is the "missing" case, which is 100% — not a clamp.
    @Test func nonFiniteIsTheDefaultDetent() {
        #expect(DocScale.detent(at: DocScale.detentIndex(of: nil)) == 1.00)
        #expect(DocScale.detent(at: DocScale.detentIndex(of: .nan)) == 1.00)
        #expect(DocScale.detent(at: DocScale.detentIndex(of: .infinity)) == 1.00)
    }

    /// Stepping off either end holds, instead of wrapping or trapping.
    @Test func detentAtClampsIndex() {
        #expect(DocScale.detent(at: -1) == DocScale.min)
        #expect(DocScale.detent(at: 999) == DocScale.max)
    }
}
