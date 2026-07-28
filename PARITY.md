# Windows → macOS parity

**Audit date:** 2026-07-28 · **Target:** shipped Windows **v1.0.2** · **Reference:** `shotAI-original/` (v1.0.2 / `753c399`) · **macOS build:** `1.1.0` (build 6)

Roadmap of record for the macOS port's parity with the shipped Windows app. Full
surface-by-surface re-audit (Windows v1.0.2 read from source, verified against the current
macOS code). **Supersedes the 2026-07-20 audit** — every row it marked 🟡/🔴 for the
onboarding tour, the recording pill's discard warning, the Settings AI tab, and the Home
list niceties has since shipped (PRs #55/#57), and v1.1.0 added four things that put macOS
*ahead* of v1.0.2.

## Verdict

**At functional parity, and now ahead of v1.0.2 in several places.** Every core surface is
implemented and — per hand-testing — works end-to-end: capture, the full report editing
loop, annotation/redaction, the Claude SOP pipeline, export, project management, archiving
(including the Windows round-trip), Settings, theming, the first-run tour, and a Liquid
Glass app icon. **214 unit tests pass** across the five SwiftPM packages
(ShotModel 88 · CaptureKit 59 · EditorKit 18 · SOPKit 23 · ExportKit 26).

**macOS is ahead of Windows v1.0.2** on: non-counted **section dividers** (Windows inserts
AI section headings as *counted* text steps); **narrow-capture centering** and **Word-paste
image sizing** in the exports; full-text **Home search**; a **bulk-export progress**
indicator; the **non-activating capture pill** (with an in-session error badge + capture
flash); and the **Liquid Glass icon**. The section-dividers work is tracked for Windows
parity in `Armadillon44/shotAI` #45 (and #46 for capture centering).

**What remains:** two deferred-by-decision features (native `.docx`/`.pptx`, a `.shotAI`
file type), one deliberate deferral (the auto-redact OCR trigger stays unsurfaced), a short
list of fidelity/polish gaps, and one untested capture path (multi-monitor Auto). The only
hard ship gate is **distribution** — Developer ID + notarization — tracked in
`docs/DISTRIBUTION.md`, not here. The shipped DMGs (1.0.0, 1.1.0) are ad-hoc signed.

## Validation status (hand-tested)

- **Verified end-to-end:** SOP generation, capture, archive/unarchive, exports, report
  editing, section dividers (report + exports), narrow-capture centering, the Home
  window-width launch fix.
- **Capture modes:** Screen ✅ and Window ✅ hand-verified. **Auto mode on a multi-monitor
  setup is still not hand-tested** (the display-resolution / click-display fallback paths
  are unit-tested only). This is the one open live-validation item.

## Parity matrix

| Surface | Status | Where it stands now |
|---|---|---|
| Capture engine | ✅ matched | Behavior-for-behavior port of `CaptureController.ts` (double-click collapse, right-click menu arming, 4-deep menu chain, own-window gating, grab cascade, discard logic). 59 tests pass. *See multi-monitor caveat above.* |
| Coordinate / geometry | ✅ matched | `GrabMath`/`ImageOutput` port `capture-geometry.ts` formula-for-formula; schema invariant `image == round((global−origin)×scale)` tested; round-trips with Windows physical-px projects. |
| Permissions / TCC | ✅ matched | All three TCC classes, per-pane deep links, 1s-polling wizard shared with Settings, relaunch helper. macOS-only surface, complete. |
| Region / area select | ✅ matched | Per-screen overlay excluded from capture; drag/confirm/cancel + size badge match the Windows UX. |
| Data model / `project.json` | ✅ matched | Field-for-field mirror of `project.ts` incl. typed `archived`/`archivedAt`; tolerant decode reproduces the Windows coercions; unknown keys round-trip via `extra`. Adds `CalloutKind.section` (Windows lacks it); decode is tolerant, so a Windows/older build degrades a section to a plain text step and the value still round-trips. |
| Archive system | ✅ matched | Pack/unpack (hybrid DEFLATE/STORED, fail-closed, zip-slip + symlink hardened), decodes Windows JSZip archives, auto-unarchive on open without bumping `updatedAt`, age-based auto-archive. Test-covered + hand-verified. |
| App shell & navigation | ✅ matched | Home⇄detail full-window swap + animated width (Home 800 ⇄ detail 1040); per-surface native toolbars; Settings as a native scene. The persisted window frame's width is coerced to Home in `App.init`, so a quit-while-wide detail view no longer restores Home too wide (`coerceMainWindowWidthToHome`, `shotAIApp.swift`). |
| Report / SOP viewer | ✅ matched | Full editing loop — inline caption/instruction + editable title, insert/import/delete/reorder/merge, text steps, callouts, **section dividers**, per-step zoom + drag-to-pan, overview intro. At/above `Report.tsx`. |
| Theme system & dark mode | ✅ matched | `Theme.swift` maps every `project.css` token as a dynamic color; accent violet `#6344F1`; light/dark/system via `.preferredColorScheme`. Two intentional dark-legibility tweaks. |
| App icon / brand identity | ✅ matched | Liquid Glass Icon Composer `.icon` (layered macOS 26 material + flattened fallback); two-tone wordmark + tagline brand header. |
| Recording pill | ✅ matched | Two-row hint + per-capture green flash + non-activating panel + in-session error badge, **and** the whole-project discard warning ("the entire project will be deleted" for a new-project discard — Windows R5 `willDeleteProjectOnDiscard`, unit-tested). The panel/badge/flash have no Windows equivalent (ahead). |
| Settings (tabbed) | ✅ matched | 5 tabs (General / AI / Capture / Appearance / Permissions). AI tab now has the create-a-key link, per-option blurbs (model/tone/effort), and the unreadable-key / secure-storage states + Clear. Permissions is a correct macOS addition. |
| Project list / Home | ✅ matched | Tabs+counts, sort, date grouping (ascending bucket order fixed), multi-select bulk bar, **shift-click range select**, **per-row busy state**, per-row menus, inline rename, delete confirms, Reveal in Finder, SOP-ready/Draft badge. Ahead on full-text search, bulk-export progress, and `.zip`. (Residual: export submenus omit `.docx`/`.pptx` → #53, an export-format gap not a list gap.) |
| First-run onboarding tour | ✅ matched | `Tour.swift` — 5-step coach-mark spotlight (ports `Tour.tsx`), persisted `hasSeenTour` once-flag, fires on first run over Home, and a Settings ▸ General "Show intro tour" replay control. |
| Section dividers | ⬆️ ahead | `CalloutKind.section`: a non-counted phase-divider heading, wired through the model, the report (borderless divider, grip-only rail, aligned to the step column), all exporters (HTML/PDF/Markdown/Word-HTML), and SOP generation (Claude's `sectionHeading`/`sectionBody` inserts become `callout:.section`). Windows v1.0.2 inserts section headings as **counted** text steps (`sop-apply.ts`). Windows parity: `Armadillon44/shotAI`#45. |
| Report / export image layout | ⬆️ ahead | A capture narrower than the column is **centered** (equal L/R padding) in the report, styled HTML, and PDF (Windows `.step__img` left-hugs). The Word/Docs export sizes images with width/height **attributes** capped to the styled column so a paste isn't oversized (Windows emits attribute-less `<img>`). Windows parity: `Armadillon44/shotAI`#46. |
| App menu + create/naming | 🟡 partial | Create/naming at parity; menu has About/Settings/Import/Export/Quit. **Gaps:** Import lacks the `⌘O` accelerator (Windows binds it); label is "Import shotAI Package…" vs Windows "Import Project…" (partly a real semantic difference — macOS imports a `.zip` package, Windows imports a project folder). |
| Annotation / redaction editor | 🟡 partial | All 8 tools + fail-closed flatten (re-flattens from the raw screenshot; render-freshness gated). **Deliberate gap:** the Vision auto-redact OCR trigger stays **intentionally unsurfaced** — the pipeline is built + tested but has no UI caller (by design; kept wired for an easy future re-add). Minor: blur softness, crop-box color, per-tool hints. |
| SOP generation (Claude) | 🟡 partial | Functionally complete + secure: host pinned, key in Keychain (never surfaced), cost estimate, review-before-send, generate/revert, tone/effort/custom-instructions, fail-closed redaction gate. The user `note` **is** sent to Claude as input context (parity). **Gaps:** the review gate shows totals only (no per-step thumbnail/caption preview like Windows `SopPanel.tsx`); per-step `note` is dropped from the AI **output** schema, so Claude can't author/rewrite a note (existing notes pass through). |
| Export | 🟡 partial | HTML, PDF (native CoreText/CG), Markdown, and "HTML for Word/Docs" through the shared fail-closed gate + byline + collision suffixing; `.zip` package round-trips with Windows; sections + narrow-capture centering + Word-paste image sizing (ahead — see the two rows above). **Gap:** native `.docx`/`.pptx` deferred by decision (→ #53). PDF is drawn natively, so it isn't pixel-identical to the Windows print-to-PDF. |

## Remaining work

### Deferred by decision (post-1.0)
- **Native `.docx` / `.pptx` export** — [#53](https://github.com/Armadillon44/shotAI_MacOS/issues/53). Feasible dependency-free via the existing DEFLATE zip writer (OOXML is zip-of-XML). "HTML for Word/Docs" is the interim path.
- **`.shotAI` registered file type** (double-click to import) — [#49](https://github.com/Armadillon44/shotAI_MacOS/issues/49).

### Deliberate deferral
- **Editor Auto-redact trigger** — the OCR pre-scan is built + tested but intentionally not surfaced in the editor UI (Dylan's call — stays removed). Re-exposing it is a one-line UI add if wanted.

### Fidelity / polish gaps
- **SOP review preview** — add the per-step "exactly what is sent" preview (thumbnails + captions) to the pre-send gate (Windows shows it; macOS shows totals only).
- **SOP note output** — add `note` back to the AI output schema if Claude should be able to author/rewrite notes (currently input-only).
- **App menu** — bind `⌘O` to Import; reconsider the "Import Project…" label.

### Needs live validation
- **Auto capture across a multi-monitor arrangement** (the one untested capture path).

### Doc hygiene
- Stale header comments that claim unfinished/verbatim work: `Archive.swift` still says "READ side only … packing lands next phase" (packing shipped + tested); `SystemPrompt.swift` still claims "ported character-for-character" but base-prompt paragraph 2 has intentionally diverged (dropped the `note` clause, added title-derivation guidance). `RequestAssembler.swift` is fine (lineage note only).

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
`hair` tokens (bold heading + thin rule + muted body), no tint and no glyph.

Intentional dark divergences from the Windows tokens: `ink-3` lifted for legibility, input
fields lightened for affordance, card shadows violet-tinted. By design; dark tokens are not
byte-identical.

**Type scale:** display 28/750 · section 19/700 · title 15/600 · body 14 · meta 13 ·
label 11 (uppercase, tracked). System font (SF Pro) substitutes Segoe UI.

## Deliberately do **not** port (native wins)

- **Window width-switching** (720↔1010) — the Home⇄detail width swap + native toolbars are the right idiom.
- **4-view boolean router / "← Back" button** — the full-window swap and native Back are the native substitutions.
- **Custom dropdowns / delete modal** — native `Menu`/`Picker`/`.confirmationDialog`.
- **`matchMedia` theme listener** — macOS auto-follows OS appearance for "system".
- **GPU auto-disable, Windows installer icons** — N/A; the macOS analog is Developer ID + notarization + the `.icon`.
- **App Store distribution** — impossible: the sandbox forbids AX + event taps → ship via Developer ID.
- **Native `.docx`/`.pptx` via a JS lib** — if built (#53), do it dependency-free via the existing zip writer, not by importing an Office library.

There is **no** auto-update infrastructure and **no** menu-bar item on Windows — do not invent them for macOS.
