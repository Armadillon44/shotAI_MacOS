# shotAI → native macOS (Swift) — Feasibility Assessment

**Date:** 2026-07-02 · **Source analyzed:** `shotAI-original/` (clone of github.com/Armadillon44/shotAI @ 1.0.0-rc1, commit 35f71c9)

## Verdict

**A fully native Swift/SwiftUI port is feasible — and macOS is arguably a *better* platform for this app than Windows.** Every subsystem of shotAI has a first-party Apple framework equivalent, several of which are strictly superior to the third-party native modules the Electron app depends on (Vision vs Tesseract, ScreenCaptureKit vs node-screenshots, a ~200-line Swift AX helper vs the Rust/koffi FFI addon). There is no component that blocks a native port.

The two honest costs:

1. **The Konva annotation editor must be rebuilt from scratch** (~1,800 lines of editor + flatten logic today). There is no Swift equivalent of Konva's scene graph + Transformer; a custom canvas with selection handles, inline text editing, and pixelate/redact baking is the single biggest work item.
2. **A permanent second codebase.** The original PLAN.md chose Electron precisely to share one codebase across Windows + macOS. A Swift port forfeits that: every future feature lands twice. Mitigation: the `project.json` schema is clean and platform-neutral — keep it byte-compatible so projects round-trip between the Windows app and the Mac app, and treat the schema as the cross-platform contract.

For calibration: the original app was built in **8 days (2026-06-24 → 07-02, 78 commits)** with heavy AI-assisted development, landing at ~12.2k lines of TypeScript + 205 lines of Rust. A Swift port of comparable quality is roughly a 10–14k-line Swift project; at similar development intensity, expect **~2–4×** the original effort (the editor rebuild, platform coordinate quirks, and signing/notarization are the multipliers).

---

## What shotAI is (component inventory)

Local-first Scribe-style SOP builder. Record a process → each click captures a screenshot + the clicked UI element → editable annotated step list → Claude rewrites it into a polished SOP → export HTML / PDF / Markdown / HTML-for-Word.

| Subsystem | Today (Electron, ~12.2k lines TS + 205 Rust) |
|---|---|
| Global click hook | `uiohook-napi` (libuiohook) |
| Global hotkey | Electron `globalShortcut` |
| Screenshots | `node-screenshots` (Rust/napi, BitBlt monitor grabs + crop) |
| Active window info | `get-windows` |
| UI element at click point | Custom Rust cdylib → Windows UI Automation, loaded via `koffi` FFI |
| Context-menu capture | Poll-timer keeps latest monitor frame; selection step uses it (menus invisible to per-window capture on Windows) |
| Annotation editor | Konva/react-konva: crop, pan/zoom, rounded rect, arrow, pixelate/solid redact, numbered stamps, text, click-marker rings; non-destructive vectors; flatten-on-output bakes redaction |
| Auto-redaction pre-scan | tesseract.js (WASM) + vendored eng model → SSN/Luhn/API-key detectors |
| SOP generation | `@anthropic-ai/sdk`, streaming, Zod structured output, vision (flattened renders only) |
| Secrets | Electron `safeStorage` |
| Storage | `~/shotAI Projects/<uuid>/project.json` + `shots/*.png` + `export/`; atomic writes; path confinement |
| Export | Self-contained HTML, PDF (offscreen window print), Markdown, HTML-for-Word |
| UI | 3 windows: always-on-top capture pill, transparent area-select overlay, main project window (report, editor, SOP panel, settings) |

Security invariants that must survive the port (from HARDENING-PLAN.md):
- **Redaction guarantee:** blur/crop must be baked into the flattened PNG before anything is sent to Claude or exported; render *freshness* (not existence) is enforced; changed annotations invalidate stale renders.
- **API key** never reaches UI code; egress pinned to `https://api.anthropic.com`.
- **Path confinement** for every file write inside a project folder.

---

## Component mapping: Electron dependency → native macOS API

| Concern | Electron/Windows today | Native Swift replacement | Delta |
|---|---|---|---|
| Global clicks | uiohook-napi | `CGEventTap` (listen-only) — `CGRequestListenEventAccess` to prompt | ✅ First-party; **Input Monitoring** TCC |
| Global hotkey | `globalShortcut` | Carbon `RegisterEventHotKey` (tiny wrapper, e.g. soffes/HotKey) | ✅ Solved problem |
| Screenshot | node-screenshots | **ScreenCaptureKit**: `SCScreenshotManager.captureImage` (macOS 14+), `SCShareableContent` for displays/windows | ✅ Better: GPU-composited, async |
| Exclude own windows | PID sets + geometry checks | `SCContentFilter(display:excludingApplications:…)` | ✅ **Built into the API** |
| Active window | get-windows | `NSWorkspace.frontmostApplication` + `CGWindowListCopyWindowInfo` (titles need Screen Recording — already granted) | ✅ First-party |
| Element at click | Rust UIA cdylib + koffi FFI | `AXUIElementCopyElementAtPosition` + `AXTitle`/`AXRole`/`AXFrame`, same climb-to-actionable-ancestor walk | ✅ **Entire Rust/FFI layer becomes ~200 lines of Swift.** Chromium/Electron apps expose AX trees, same as UIA. **Accessibility** TCC |
| Menu-popup capture | Poll timer + sync BitBlt grab | Display-level SCK capture includes menus (composited). Either keep the poll pattern with `SCScreenshotManager`, or run a **low-fps `SCStream` during recording and use the latest frame** — the stream *is* the "most recent frame" cache, replacing the hack | ✅ Cleaner design available |
| Annotation editor | Konva scene graph + Transformer | Custom SwiftUI `Canvas`/NSView: Core Graphics shapes, `CIPixellate` for mosaic redaction, custom drag/resize handles, `NSTextField`-overlay inline text editing | ⚠️ **Biggest rebuild** (~2–3k lines) |
| Flatten/bake | Konva `toCanvas` in renderer + main-side re-bake | `CGContext` offscreen render → PNG (one code path, unit-testable) | ✅ Simpler: one process, one path |
| OCR redaction pre-scan | tesseract.js + 15 MB vendored model | **Vision** `VNRecognizeTextRequest` (word boxes built in) | ✅ Better accuracy, hardware-accelerated, zero vendored data. Detector logic (`redact-detect.ts`) ports 1:1 |
| Claude | @anthropic-ai/sdk + Zod | **No official Swift SDK** (community: SwiftAnthropic, SwiftClaude). Recommend direct `URLSession`: Messages API + SSE streaming + JSON-schema structured output + `models.retrieve` key test is a small, auditable surface (~600–800 lines) with the base URL pinned | ⚠️ Hand-rolled but small |
| Secrets | Electron safeStorage | Keychain Services (`kSecClassGenericPassword`) | ✅ Better |
| Storage/model | TS interfaces + Zod + atomic writes | `Codable` structs mirroring `project.ts`; atomic write via temp-file + `FileManager.replaceItemAt`; same path-confinement checks | ✅ Direct port; **keep schema byte-compatible** |
| Report view | React DOM | Native SwiftUI list (`AttributedString(markdown:)` for bodies); the *export* HTML stays a string template ported verbatim | ✅ Native feel in-app, identical exports |
| PDF export | Offscreen BrowserWindow `printToPDF` | Offscreen `WKWebView.createPDF` fed the same export HTML | ✅ Same output |
| Capture pill / overlay | Frameless BrowserWindows | `NSPanel` (`.nonactivatingPanel`, `.floating`) / borderless transparent `NSWindow` per screen at `.screenSaver` level | ✅ This is what those APIs are for |
| IPC / preload / sandbox | contextBridge + 3 renderer processes | **Deleted.** Single process, Swift actors for the capture queue | ✅ Whole layer disappears (~1,200 lines) |

Windows-specific code that does **not** port and needs macOS-equivalent thinking instead: the shell-host classification for `auto` mode (`SHELL_HOST_RE`, "Program Manager" desktop detection) → macOS analogues are Dock, menu bar, Mission Control (classify via the frontmost app bundle ID + AX role); the x64-on-ARM emulation machinery and npm allow-scripts workarounds → irrelevant on a native arm64 Mac app.

---

## Permissions & distribution (the real macOS friction)

Three TCC permissions, exactly as the original PLAN.md Phase 5 anticipated:

| Permission | Needed for | Prompt API |
|---|---|---|
| **Screen Recording** | SCK captures; also unlocks window titles | `CGRequestScreenCaptureAccess` |
| **Accessibility** | `AXUIElementCopyElementAtPosition` (element-at-point) | `AXIsProcessTrustedWithOptions` |
| **Input Monitoring** | `CGEventTap` global click listener | `CGRequestListenEventAccess` |

- Build the **permissions wizard first-run flow** (detect each, deep-link to the exact System Settings pane). Element-at-point already fails soft in the data model (`element.available=false`), so Accessibility can be optional-but-recommended.
- **Periodic re-authorization:** since macOS 15 Sequoia, apps holding Screen Recording permission get a recurring (~monthly) "still allow?" system prompt, unchanged in spirit on macOS 26. Unavoidable for click-driven auto-capture; document it in-app. (Enterprise MDM can pre-authorize.) A future refinement: window/screen capture modes could use `SCContentSharingPicker`, which needs no TCC grant at all — but `auto` mode needs the full permission, so ship with the standard grant first.
- A live `SCStream` shows the screen-capture menu-bar indicator — arguably a feature (visible recording state).
- **Distribution: Developer ID + notarization + hardened runtime** (Apple Developer Program, $99/yr). The Mac App Store is **out**: sandboxed apps can't use AX element inspection or global event taps. Signing/notarizing a plain Swift app is significantly simpler than notarizing an Electron bundle.

## Platform gotchas to design for

- **Coordinate spaces:** `CGEvent` locations are top-left-origin global points; `NSScreen`/AppKit frames are bottom-left-origin; Retina backing scale separates points from pixels. `project.json` stores physical-pixel geometry — define one conversion boundary at capture time (store pixels + `scaleFactor`, as today) and unit-test it on a mixed-DPI dual-monitor setup. This is the same risk class the Windows app already manages; it just flips axes.
- **Swift 6 strict concurrency:** the capture queue's promise-chain serialization maps naturally to an `actor CaptureEngine`; AX and CGEventTap callbacks arrive on their own threads/run-loop — annotate and isolate deliberately from day one.
- **`window.app` values** differ (`chrome.exe` vs `Google Chrome`) — cosmetic in captions/SOP text; harmless for round-tripping.

## Alternative considered: port the existing Electron app to macOS

This is the repo's own Phase 5 and is much cheaper: `node-screenshots`, `uiohook-napi`, and `get-windows` all ship macOS support; the Rust element-locator needs a macOS implementation (or ship without it — the fallback already exists); add the permissions wizard + DMG/ZIP packaging + notarization. Realistically **days, not weeks**, to a working Mac build — but it stays an Electron app: ~250 MB, Chromium chrome, non-native UX. It's the right move if time-to-Mac matters most or if maintaining two codebases is unacceptable. Given the stated goal ("as native to macOS as possible, possibly fully ported to Swift"), the Swift rewrite is the recommended path; the Electron port can even ship first as a stopgap since both read the same project folders.

---

## Recommended architecture (Swift)

- **App:** SwiftUI lifecycle, single process, **macOS 14.0+ minimum** (SCScreenshotManager floor; dev machine runs 26.5, Xcode 26.6/Swift 6.3 already installed).
- **Targets/modules:**
  - `ShotModel` — Codable manifest/step/annotation types (byte-compatible with `project.ts` schema v1), path confinement, atomic writes. *Port the existing vitest cases (`path-confine`, `mutate-serialize`, `export-geometry`, `redact-detect`) to XCTest — they encode the security invariants.*
  - `CaptureKit` — `actor CaptureEngine`: event tap, hotkey, SCK grabs (+ optional latest-frame SCStream), window/monitor resolution, `auto` classification, element-at-point (AX), auto-captions.
  - `EditorKit` — annotation canvas + the **single flatten path** (CGContext → PNG, redaction baked, marker baked).
  - `SOPKit` — Claude client (URLSession + SSE + JSON-schema structured output), review-before-send, render gate (only fresh flattened renders leave the machine), Keychain.
  - `ExportKit` — HTML/Markdown string templates (ported verbatim), WKWebView→PDF, HTML-for-Word.
  - App UI — project window (report list, editor sheet, SOP panel, settings), capture pill `NSPanel`, area-select overlay windows, permissions wizard, optional menu-bar extra.

## Phased plan

| Phase | Scope | Exit test |
|---|---|---|
| **A — Model + viewer** | Codable schema, ProjectStore, project list + read-only report view | Opens a project folder **created by the Windows app** and renders it correctly (data-compat proven on day one) |
| **B — Capture engine** | Permissions wizard, event tap, hotkey, SCK capture, region modes, own-window exclusion, auto-captions, element-at-point | Record a flow in Safari/Finder; steps + PNGs + captions land in `project.json`; pill clicks create no steps |
| **C — Editor + redaction** | Annotation canvas, flatten/bake, marker rings, crop/zoom/pan, Vision OCR pre-scan + detectors | Redacted export provably contains no original pixels; re-edit round-trips |
| **D — SOP + export** | Claude streaming + structured output, review-before-send, revert, all four export formats | Windows-app exports and Mac-app exports of the same project are equivalent |
| **E — Ship** | Developer ID signing, notarization, Sparkle or manual updates, menu-bar polish | Notarized DMG installs clean on a second Mac; first-run wizard grants all three permissions |

Rough relative sizing: B ≈ C > D > A ≈ E. The original took 8 AI-assisted days for the Windows equivalent of A–D; budget ~2–4× that for Swift parity, front-loaded in B and C.

## Bottom line

Green light. No blockers, three of the four native concerns get *easier* on macOS (capture, OCR, element-at-point), one gets rebuilt (editor), and the platform frictions (TCC permissions, notarization, coordinate flips) are well-understood and already anticipated by the original plan. Keep `project.json` as the shared contract and the Mac app becomes a true sibling, not a fork.
