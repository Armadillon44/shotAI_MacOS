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

**Status: Phase A complete** (2026-07-02). Scaffolding:

- `shotAI.xcodeproj` + `shotAI/` — SwiftUI app target (read-only project list + report viewer). Uses Xcode's filesystem-synchronized folder, so new files under `shotAI/` join the target automatically.
- `Packages/ShotModel/` — UI-free SwiftPM library: Codable schema (tolerant decode mirroring `readManifest` coercions; unknown keys/annotation types round-trip via `extra`/`JSONValue`), `confinePath`, `writeFileAtomic`, `ProjectStore` actor (the Windows writeQueue equivalent), and `ReportPresentation` (rendering rules ported from `Report.tsx`).
- `Fixtures/b7e2c4d1-…/` — a simulated Windows-app-created project (regenerate PNGs with `swift Scripts/make-fixture-shots.swift Fixtures/<uuid>`; geometry must match its `project.json`).

## Commands

- Model tests (ported vitest invariants + schema round-trip): `swift test --package-path Packages/ShotModel`
- Build app: `xcodebuild -project shotAI.xcodeproj -scheme shotAI -configuration Debug build`
- The app's projects dir defaults to `~/shotAI Projects` (same as Windows).

## Environment

Apple Silicon, macOS 26.5, Xcode 26.6 / Swift 6.3. `gh` CLI authenticated as **Armadillon44**.
