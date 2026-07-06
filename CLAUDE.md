# shotAI for macOS

Native Swift/SwiftUI port of **shotAI** — Dylan's local-first, Scribe-style SOP builder (record a process → screenshot + clicked UI element per step → annotated step guide → Claude writes the SOP → export HTML/PDF/Markdown/Word-HTML).

## This repo

- `FEASIBILITY.md` — the full port assessment (2026-07-02). **Read this first**; it contains the component-by-component API mapping, permissions/distribution story, risks, and the phased plan.
- `shotAI-original/` — reference clone of the Windows Electron app (github.com/Armadillon44/shotAI, private, 1.0.0-rc1). The source of truth for behavior, data model, and security invariants. Do not modify it; it's a read-only reference.

## Key decisions (from FEASIBILITY.md)

- SwiftUI app, single process, **macOS 14.0+ minimum** (ScreenCaptureKit `SCScreenshotManager` floor).
- **`project.json` schema stays byte-compatible** with the Windows app (`shotAI-original/src/shared/project.ts` is the contract) so projects round-trip between platforms.
- Modules: ShotModel (Codable schema, path confinement, atomic writes) · CaptureKit (CGEventTap clicks, hotkey, SCK capture, AX element-at-point) · EditorKit (annotation canvas + single flatten path) · SOPKit (URLSession Claude client — no official Swift SDK; pin `https://api.anthropic.com`; key in Keychain) · ExportKit (HTML/MD templates ported verbatim; PDF via offscreen WKWebView).
- Security invariants to preserve (see `shotAI-original/docs/HARDENING-PLAN.md`): redaction/crop must be **baked into the flattened PNG** before anything is sent to Claude or exported (freshness-enforced, stale renders invalidated); API key never reaches UI code; every project-folder write is path-confined.
- TCC permissions: Screen Recording + Accessibility + Input Monitoring, with a first-run permissions wizard. Distribution: Developer ID + notarization (App Store impossible — sandbox forbids AX/event taps).

## Phases

A) Codable model + read-only viewer (exit: opens a Windows-created project) → B) capture engine + permissions wizard → C) annotation editor + redaction (Vision OCR) → D) Claude SOP + export → E) sign/notarize/ship.

**Status: Phase A complete** (2026-07-02), **Phase B complete** (2026-07-04). Scaffolding:

- `shotAI.xcodeproj` + `shotAI/` — SwiftUI app target (project list + report viewer + capture UI). Uses Xcode's filesystem-synchronized folder, so new files under `shotAI/` join the target automatically.
- `Packages/ShotModel/` — UI-free SwiftPM library: Codable schema (tolerant decode mirroring `readManifest` coercions; unknown keys/annotation types round-trip via `extra`/`JSONValue`), `confinePath`, `writeFileAtomic`, `ProjectStore` actor (the Windows writeQueue equivalent), and `ReportPresentation` (rendering rules ported from `Report.tsx`).
- `Packages/CaptureKit/` — the recording engine, ported behavior-for-behavior from `CaptureController.ts`: `CaptureEngine` actor (event decisions + FIFO capture queue), menu-popup poll cache, own-window exclusion, 0.85 downscale contract, auto-caption builder (Windows UIA controlType vocabulary), AX element-at-point (`AXElementLocator`), SCK screenshotter (own app excluded via content filter — `sharingType=.none` is NOT the mechanism on 15+), listen-only mouse-only CGEventTap (empirically needs no TCC) + Carbon ⌘⇧S hotkey, TCC permission surface. Hardware sits behind protocols; the pipeline tests run headless.
- `shotAI/Capture/` — non-activating pill NSPanel, per-screen area-select overlay, permissions wizard (poll + deep links), record-target sheet, coordinator.
- **Coordinate convention (macOS)**: "global" = CG top-left POINTS (CGEvent/AX/SCDisplay share it); `monitor.scaleFactor` = pixels-per-point; `click.image = round((global − origin) × imageScale)` with `imageScale = pixelScale × downscale` — self-consistent per project, round-trips with Windows projects (which store physical px). AppKit rects flip globally about the primary screen only (`CoordinateSpaces.swift`).
- `Fixtures/b7e2c4d1-…/` — a simulated Windows-app-created project (regenerate PNGs with `swift Scripts/make-fixture-shots.swift Fixtures/<uuid>`; geometry must match its `project.json`).
- Phase B behavioral specs extracted from the Windows app (constants, invariants, edge cases) informed the port; the originals in `shotAI-original/src/main/` remain the source of truth.

### Phase B review — deferred findings (intentionally not fixed yet)

An adversarial multi-dimension review ran on the Phase B code; the confirmed correctness/security/concurrency findings were fixed (session-generation guards for actor re-entrancy, per-arm menu-poll flag, `SystemTriggers` locking + main-thread Carbon calls, strict `display(containing:)` resolution, orphan-filename clamp, pid-based SCK exclusion, real 600 ms element-query timeout, popup-value privacy). These were consciously deferred:

- **Symlinked `shots/` residual** — `confinePath` is lexical only (documented Windows-parity gap); a hostile foreign project with `shots` symlinked out isn't blocked. Fix belongs in `PathConfine.swift` (lstat/realpath) when symlink hardening lands, and would cover the Windows app too.
- **Two `SCShareableContent` enumerations per capture** (`SCKScreenshotter.displays()` then `captureDisplay()`), and 2/tick during menu polling — latency, not correctness. Fold display resolution into one enumeration in a perf pass.
- **Capture errors during recording show an alert on the ordered-out main window** — invisible until the session ends. Needs the error surfaced on the pill (plumb `lastError` into `PillView`); a UX follow-up.
- **`.rounded()` vs JS `Math.round` for negative half-point crop offsets** — sub-pixel formula-parity nit; macOS already stores point-space coords, not Windows physical px, so exact byte-parity of the pixel math isn't a goal.

## Commands

- Model tests: `swift test --package-path Packages/ShotModel`
- Capture tests (headless pipeline + geometry + captions): `swift test --package-path Packages/CaptureKit`
- **Live capture smoke test** (drives real SCK/AX/store; needs Screen Recording): `swift run --package-path Packages/CaptureKit CaptureSelfTest` — the macOS analog of the Windows `capture-selftest.ts`; prints `[capture-test] PASS/FAIL`.
- Build app: `xcodebuild -project shotAI.xcodeproj -scheme shotAI -configuration Debug build`
- The app's projects dir defaults to `~/shotAI Projects` (same as Windows).
- TCC reset for wizard testing: `tccutil reset ScreenCapture|Accessibility|ListenEvent com.armadillon44.shotai` (grants are keyed to bundle id + signature; re-signs orphan them — symptom: nil tap / SCK userDeclined with the toggle apparently ON).

## Environment

Apple Silicon, macOS 26.5, Xcode 26.6 / Swift 6.3. `gh` CLI authenticated as **Armadillon44**.
