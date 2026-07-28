# Windows → macOS parity

**Audit date:** 2026-07-28 · **Target:** shipped Windows **v1.1.4** · **Reference:** `shotAI-original/` (v1.1.4 / `d9823ec`) · **macOS build:** `1.1.1` (build 7)

Roadmap of record for the macOS port's parity with the shipped Windows app. Full
surface-by-surface re-audit (Windows v1.1.4 read from source, verified against the current
macOS code). **Supersedes the v1.0.2-targeted audit** — Windows shipped five releases
(v1.1.0–v1.1.4) that closed the gaps macOS had opened: it now has section dividers, centered
narrow captures, project search, per-step note removal, step-framing cards, Home
auto-refresh, export dimensions **explicitly matched to macOS**, and — in v1.1.4 — the two
items macOS had most recently led on (plain-export image sizing and the in-session
capture-error surface). So the items macOS was "ahead" on are now parity, and the one
substantive gap runs the other way.

## Verdict

**At functional parity with Windows v1.1.4.** Both apps now share the section-divider model,
non-counted numbering, centered captures, the 880/820 report+export dimensions, project
search, report inserts (+Capture / +Screenshot), save-to-location export, Home list
auto-refresh, log bounding, attribute-sized plain-export images, and an in-session
capture-error surface on the pill — verified row-by-row in source.

**The one feature Windows has that macOS lacks: native `.docx` and `.pptx` export.** Windows
ships real Word (via the `docx` lib) and PowerPoint (via `pptxgenjs`) exporters; macOS defers
both (issue #53) and offers "HTML for Word/Docs" as the paste-in substitute. This is the
main open gap, by decision.

**macOS still leads Windows v1.1.4** on: the **Liquid Glass** app icon, and the Home
**window-width launch fix** (N/A on Windows — it creates its window at the list width and
persists no bounds, so there is nothing to coerce). Several other leads are macOS-native
idioms with no Windows analog (non-activating pill, native Settings scene, TCC permissions
wizard).

**Closed in Windows v1.1.4** (both were macOS leads in the previous audit):
- **Plain-export image sizing** — Windows' "HTML (for Word)" now emits width/height
  attributes, capped at 738px preserving aspect, with no attributes when the image won't
  decode. Numerically identical to `plainExportImageMaxWidth`.
- **In-session capture-error surface** — the Windows pill now subscribes to its
  `capture:error` broadcast, with this app's clearing semantics ported (a landed step clears
  it, leaving the session clears it, never shown idle, click to dismiss) and a red accent
  bar. **Implementations differ by design:** macOS shows a compact row-1 chip with the
  message in a `.help` tooltip; Windows puts the real message in row 2 (replacing the hint),
  because its wider font metrics overflow row 1's 380px once Pause/Stop/Discard are present.
  Windows also had to opt the text out of its drag region — a child of
  `-webkit-app-region: drag` is hit-tested by the OS for window moves and never receives the
  hover that fires a native tooltip. No macOS analog needed; noted for context.

The only hard ship gate is **distribution** — Developer ID + notarization
(`docs/DISTRIBUTION.md`). The shipped DMGs (1.0.0, 1.1.0, 1.1.1) are ad-hoc signed.

## Validation status (hand-tested)

- **Verified end-to-end:** SOP generation, capture, archive/unarchive, exports, report
  editing, section dividers (report + exports), narrow-capture centering, the
  self-contained Markdown export folder, and the Home window-width launch fix.
- **Capture modes:** Screen ✅ and Window ✅ hand-verified. **Auto mode on a multi-monitor
  setup is still not hand-tested** (fallback paths are unit-tested only). The one open
  live-validation item.

## Parity matrix

| Surface | Status | Where it stands vs Windows v1.1.4 |
|---|---|---|
| Capture engine | ✅ matched | Behavior-for-behavior port of `CaptureController.ts`. 59 tests. *See multi-monitor caveat.* |
| Coordinate / geometry | ✅ matched | `capture-geometry.ts` ported formula-for-formula; round-trips with Windows physical-px projects. |
| Permissions / TCC | ✅ matched | Live-polling wizard + Settings pane. macOS-native surface (Windows needs no capture permission). |
| Region / area select | ✅ matched | Per-screen overlay excluded from capture; drag/confirm/cancel + size badge. |
| Data model / `project.json` | ✅ matched | Field-for-field mirror incl. typed `archived`/`archivedAt` and `CalloutKind.section` (both platforms now carry the 4-value union); tolerant decode; unknown keys round-trip via `extra`. |
| Archive system | ✅ matched | Pack/unpack (hybrid DEFLATE/STORED, hardened), decodes Windows JSZip archives, auto-unarchive on open. |
| App shell & navigation | ✅ matched | Home⇄detail width swap (800⇄1040) + native toolbars; Settings as a native scene. Persisted window width coerced to Home on launch (`coerceMainWindowWidthToHome`). |
| Report / SOP viewer | ✅ matched | Full editing loop — inline caption/instruction + editable title, insert/import/delete/reorder/merge, text steps, callouts, **section dividers** (both apps), per-step zoom + drag-to-pan, overview intro. |
| Section dividers | ✅ matched | Non-counted `CalloutKind.section` on both (Windows added it in v1.1.2): un-numbered, rendered as a divider in report + every export, and Claude's phase headings come through as sections, not extra steps. |
| Narrow-capture centering | ✅ matched | Byte-identical `.step__img{…margin-inline:auto}` (Windows v1.1.2) + report/PDF centering. |
| Export dimensions | ✅ matched | `.doc` 880 + image base 820 — Windows v1.1.3 explicitly ported these to match macOS (its source cites `ReportPresentation.baseWidth`). |
| Project list / Home | ✅ matched | Tabs+counts, sort, date grouping, multi-select bulk bar + destinations + progress, shift-click range select, per-row busy state, inline rename, Reveal in Finder, badges, **full-text search**, and **auto-refresh** (20s poll + foreground, paused during rename/select — Windows pauses during typing). |
| First-run onboarding tour | ✅ matched | 5-step coach-mark spotlight, persisted once-flag, Settings replay. |
| Theme system & dark mode | ✅ matched | `Theme.swift` maps every `project.css` token; violet accent; light/dark/system. Two intentional dark-legibility tweaks. |
| Settings (tabbed) | ✅ matched | General / AI / Capture / Appearance / Permissions; AI tab has key-create link, per-option blurbs, unreadable-key / secure-storage states. |
| Recording pill | ✅ matched | Two-row hint, per-capture green flash, whole-project discard warning, and an **in-session capture-error surface** on both (Windows added it in v1.1.4; same clear-on-step / clear-on-session / dismiss semantics + red accent bar, but it shows the message inline in row 2 rather than a row-1 chip + tooltip — its 380px row 1 can't fit both). **Ahead:** non-activating panel. |
| SOP generation (Claude) | 🟡 partial | Secure + complete: host pinned, Keychain key, cost estimate, review-before-send, generate/revert, tone/effort/custom-instructions, fail-closed gate; user note sent as input. Note-writing removed on **both** apps (v1.1.0 Windows / macOS), so that's parity now. **Gap:** the pre-send review shows totals only; Windows shows a per-step thumbnail+caption preview. |
| Export (HTML / PDF / Markdown / Word-HTML / `.zip`) | ✅ matched | All five through the shared fail-closed gate; dimensions + centering + sections match Windows. **Markdown is a self-contained `<name>/` folder** (`<name>.md` + `images/`) for every destination, with folder-level collision numbering (macOS 1.1.1) — matches Windows. The plain-export **738px width/height image cap now matches on both** (Windows v1.1.4). `.zip` packages round-trip between platforms. *Note:* the PDF is drawn natively (CoreText/CG) rather than print-to-PDF, so it is not pixel-identical to Windows' — same content and layout, different rasterizer. Native Office formats are a separate row. |
| Native Office export (`.docx` / `.pptx`) | 🔴 macOS gap | **Windows ships both** (Word via `docx`, PowerPoint via `pptxgenjs`; both render cards, sections, centered captures, callouts, and safely handle a macOS-authored section). macOS defers both (→ #53); "HTML for Word/Docs" is the interim paste path. |
| App menu + create/naming | 🟡 partial | Create/naming at parity. **Gaps:** Import lacks `⌘O` (Windows binds it); label "Import shotAI Package…" vs Windows "Import Project…" (partly a real difference — macOS imports a `.zip` package, Windows a project folder). |
| Annotation / redaction editor | 🟡 partial | All 8 tools + fail-closed flatten. **Deliberate gap:** the Vision auto-redact OCR trigger stays unsurfaced (built + tested, no UI caller — by design). Minor: blur softness, crop-box color, per-tool hints. |

## Remaining work

### The one Windows-ahead feature
- **Native `.docx` / `.pptx` export** — [#53](https://github.com/Armadillon44/shotAI_MacOS/issues/53). Windows now ships both; macOS defers. Feasible dependency-free via the existing DEFLATE zip writer (OOXML is zip-of-XML) — do **not** import an Office library. "HTML for Word/Docs" is the interim path.

### Deferred by decision
- **`.shotAI` registered file type** (double-click to import) — [#49](https://github.com/Armadillon44/shotAI_MacOS/issues/49).

### Deliberate deferral
- **Editor Auto-redact trigger** — the OCR pre-scan is built + tested but intentionally not surfaced (Dylan's call). Re-exposing it is a one-line UI add if wanted.

### Fidelity / polish gaps
- **SOP review preview** — add the per-step "exactly what is sent" preview (thumbnails + captions) to the pre-send gate (Windows shows it; macOS shows totals).
- **App menu** — bind `⌘O` to Import; reconsider the "Import Project…" label.

### Needs live validation
- **Auto capture across a multi-monitor arrangement** (the one untested capture path).

## Design system (implemented)

The Windows token system (`:root` light + `[data-theme=dark]`) is reproduced natively in
`Theme.swift` as dynamic colors, read app-wide, with light/dark/system via
`.preferredColorScheme`. Token reference of record:

| Token | Light | Dark | Usage |
|---|---|---|---|
| `accent` | `#6344f1` | `#9a8bf7` | Brand violet — buttons, step badges, focus ring, active tabs, links |
| `accent-tint` | `#efeafe` | `#241f3a` | Hover, selected item, active chip, bulk bar |
| `ink` / `ink-2` / `ink-3` | `#191826`/`#5a5772`/`#918ea6` | `#ece9f7`/`#a8a4c0`/`#8e8aa8` | Primary / secondary / tertiary text |
| `surface` / `surface-2` | `#ffffff`/`#faf9ff` | `#1b1926`/`#211f2e` | Cards / raised sub-surfaces |
| `ground` | `#f5f4fb` | `#121019` | Window background, sticky detail bar |
| `hair` / `control-bd` | `#e7e4f2`/`#cbc7db` | `#302c42`/`#3c3852` | Hairlines / control borders |
| `ok` (SOP ready) | `#0e9f6e` / tint `#e7f7ef` | `#34d399` / `#12271e` | Green status — **not** the accent |
| `draft` | `#c77d16` / tint `#fbf1e0` | `#e0a355` / `#2a2113` | Amber status |
| `danger` | `#dc2626` | `#f87171` | Destructive only |
| callout `note`/`caut`/`warn` | green / amber / red trios | (dark trios) | Callout boxes + rail glyphs (ℹ/⚠/⛔) |

A **section divider** is not a colored callout: it reuses the neutral `ink` / `ink-2` /
`hair` tokens (bold heading + thin rule + muted body), no tint and no glyph — same on both platforms.

Intentional dark divergences: `ink-3` lifted for legibility, input fields lightened, card
shadows violet-tinted. Dark tokens are not byte-identical.

**Type scale:** display 28/750 · section 19/700 · title 15/600 · body 14 · meta 13 ·
label 11 (uppercase, tracked). System font (SF Pro) substitutes Segoe UI.

**Tests:** 216 across the five SwiftPM packages (ShotModel 88 · CaptureKit 59 · EditorKit 18 · SOPKit 23 · ExportKit 28).

## Deliberately do **not** port (native wins)

- **Window width-switching** (720↔1010) — the Home⇄detail width swap + native toolbars are the right idiom.
- **4-view boolean router / "← Back" button** — the full-window swap and native Back are the native substitutions.
- **Custom dropdowns / delete modal** — native `Menu`/`Picker`/`.confirmationDialog`.
- **`matchMedia` theme listener** — macOS auto-follows OS appearance for "system".
- **GPU auto-disable, Windows installer icons / `--silent` switch** — N/A; the macOS analog is Developer ID + notarization + the `.icon`.
- **App Store distribution** — impossible: the sandbox forbids AX + event taps → ship via Developer ID.
- **Native `.docx`/`.pptx` via a JS lib** — when built (#53), do it dependency-free via the existing zip writer, not by importing `docx`/`pptxgenjs`.

There is **no** auto-update infrastructure and **no** menu-bar item on Windows — do not invent them for macOS.
