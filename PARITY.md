# Windows → macOS parity

**Audit date:** 2026-07-08 · **Target:** shipped Windows **v1.0.2** · **Reference:** `shotAI-original/` (synced to `v1.0.2` / `753c399`)

This is the roadmap of record for bringing the macOS port to parity with the shipped
Windows app. It was produced by a full surface-by-surface audit (Windows v1.0.2 spec'd
from source, then diffed against the current macOS implementation): **162 concrete gaps
across 8 surfaces**. Companion visual report (rendered in shotAI's own target design
tokens): <https://claude.ai/code/artifact/2270bf42-2627-448e-8f6d-2a30661bc9e7>

## Verdict

**The hard part is done; most of the product isn't yet.** The riskiest, platform-specific
work — capture engine, coordinate math, permissions, region overlay — is at genuine
parity and live-validated. But Windows shipped from our original `1.0.0-rc1` clone point
all the way to **v1.0.2**, and measured against that the port implements **roughly a
third** of the surface. Everything downstream of "capture a step" is still absent:
editing, project management, Settings, theming, the Claude SOP pipeline, and all export.

> **One item is a real bug, not just a gap.** A **Windows-archived project opens on macOS
> with every screenshot "Image missing."** Windows packs `shots/` into an `archive.zip`
> and sets `archived: true`; the port has no `isArchivedOnDisk` / auto-unarchive path, and
> the `archived` / `archivedAt` fields survive only inside `extra` (untyped). This breaks
> the round-trip-with-Windows invariant the whole project rests on. Fix it first (P0).

## Parity matrix

| Surface | Status | Where it stands |
|---|---|---|
| Capture engine | ✅ matched | Event tap, ⌘⇧S hotkey, SCK grab, AX element-at-point, 0.85 downscale, auto-caption — ported behavior-for-behavior; tests pass. |
| Coordinate / geometry | ✅ matched | Global CG top-left points, scale factor, click→image round-trip; round-trips with Windows physical-px projects. |
| Permissions / TCC | ✅ matched | First-run wizard with poll + deep links (Screen Recording / Accessibility / Input Monitoring). |
| Region / area select | ✅ matched | Per-screen overlay excluded from capture; matches the Windows selection UX. |
| Recording pill | 🟡 partial | Window-hide takeover + non-activating panel + demo-mode keep-visible match. Missing per-capture green flash, two-row hint, honest discard wording. |
| Data model / project.json | 🟡 partial | Byte-compatible & round-trips. But `archived`/`archivedAt` untyped; summary lacks `archived` + `hasSop`. |
| App shell & navigation | 🟡 partial | Recording takeover matched; 4-view router → NavigationSplitView (sound native swap). Missing Settings, theme, brand header, app-menu Import/Settings/About. |
| Project list / Home | 🟡 partial | Select-to-open works. Missing Projects/Archive tabs, sort, date grouping, multi-select + bulk bar, per-row menu, SOP-ready/Draft badge. Rename/Delete exist in store with no UI. |
| Report / SOP viewer | 🟡 partial | Read-only; only interaction is the redaction editor. Missing the entire editing loop. |
| Annotation / redaction editor | 🟡 partial | Phase C open PR: select/redact/crop + Vision auto-redact + fail-closed flatten. Redaction-first slice. |
| Theme system & dark mode | 🟠 divergent | No token system; report bakes fixed light hex + indigo `#4f46e5` (brand is violet `#6344f1`) → renders half-dark & off-brand on dark systems. |
| Settings (tabbed) | 🔴 missing | No Settings scene, no ⌘,. Theme, projects dir, capture visibility/scale, byline, API key all unreachable. |
| Archive system | 🔴 missing | No archive/unarchive/auto-unarchive/stale-archive. Source of the P0 data bug. |
| SOP generation (Claude) | 🔴 missing | No SOPKit, client, cost/privacy gate, or key status. Phase D — the headline value. |
| Export (6 formats + package) | 🔴 missing | No ExportKit. Windows ships HTML/MD/PDF/Word/PowerPoint + a re-editable `.zip`. |
| App icon / brand identity | 🔴 missing | No `Assets.xcassets` — generic Dock/Finder/About icon. Phase E ship requirement. |
| First-run onboarding tour | 🔴 missing | No coach-mark tour. The permissions wizard covers TCC only. |

## What shipped after our clone (rc1 → v1.0.2)

The port branched from `1.0.0-rc1`; these landed since and are exactly the authoring,
management, and polish the port is missing. (Editing, SOP, and basic export already
existed at rc1 — those are unbuilt phases, not drift.)

- **RC2** — Tabbed Settings (AI / Capture / Appearance / Storage / About)
- **RC3** — Word + PowerPoint export (+ "HTML for Word"); shareable re-editable `.zip` package + import; first-run coach-mark tour
- **RC4** — Screenshot-quality slider (50–100% + readability floor)
- **RC5** — Dark-mode theming (light/dark/system token swap); Home triage (tabs, sort, date buckets, multi-select, badges); **project archiving** (`archive.zip` + auto-unarchive — the P0 bug)
- **1.0.0** — GA + MIT license; export byline "Created on … by …"
- **1.0.2** — text-step + callout fixes (the release the port targets)

## Design system to adopt (the "not very similar" root)

Windows tokenizes every color twice — light on `:root`, dark under `[data-theme]` — so the
whole app reskins from one block. The macOS report hardcodes light hex and an indigo
accent, so even the brand color diverges. Reproduce natively as an **Asset Catalog color
set** (Any + Dark appearance per token) read through a `Color` extension, with theme
override via `.preferredColorScheme` (macOS auto-follows the OS for "system").

| Token | Light | Dark | Usage |
|---|---|---|---|
| `accent` | `#6344f1` | `#9a8bf7` | Brand violet — buttons, step badges, focus ring, active tabs, links |
| `accent-tint` | `#efeafe` | `#241f3a` | Hover, selected item, active chip, bulk bar |
| `ink` / `ink-2` / `ink-3` | `#191826`/`#5a5772`/`#918ea6` | `#ece9f7`/`#a8a4c0`/`#726f8b` | Primary / secondary / tertiary text |
| `surface` / `surface-2` | `#ffffff`/`#faf9ff` | `#1b1926`/`#211f2e` | Cards / raised sub-surfaces |
| `ground` | `#f5f4fb` | `#121019` | Window background, sticky detail bar |
| `hair` / `control-bd` | `#e7e4f2`/`#cbc7db` | `#302c42`/`#3c3852` | Hairlines / control borders |
| `ok` (SOP ready) | `#0e9f6e` / tint `#e7f7ef` | `#34d399` / `#12271e` | Green status — **not** the accent |
| `draft` | `#c77d16` / tint `#fbf1e0` | `#e0a355` / `#2a2113` | Amber status |
| `danger` | `#dc2626` | `#f87171` | Destructive only |
| callout `note`/`caut`/`warn` | green / amber / red trios | (dark trios) | Callout boxes + rail glyphs (ℹ/⚠/⛔) |

**Type scale:** display 28/750 · section 19/700 · title 15/600 · body 14 · meta 13 ·
label 11 (uppercase, tracked). Substitute the system font (SF Pro) for Segoe UI; keep the
editor's on-canvas text in the flatten renderer's font.

**Accent drift to fix:** the report renders indigo `#4f46e5`; the shipped brand is violet
`#6344f1`. A single find-and-replace is the cheapest "same app" win.

## Roadmap

Ordered basics-first: data integrity and functional structure lead; cheap high-visibility
visual wins are pulled forward; the two greenfield packages (SOP + export) come last.
Phase tags map to the A–E plan in `FEASIBILITY.md`.

### P0 — correctness & the core loop
- **Fix cross-platform archive interop** *(Archive, L)* — typed `archived`/`archivedAt` on manifest + summary; port pack/unpack (`shots/`+`export/` ↔ `archive.zip`, fail-closed); auto-unarchive on open; archive must **not** bump `updatedAt`.
- **Complete the report editing loop** *(Phase C, XL — the open PR)* — inline caption/instruction edit; text steps & click-to-edit callouts; insert/import/delete/reorder/merge; zoom + drag-to-pan (persisted); overview intro; finish redaction slice + `ensureFlattened`.
- **Home CRUD basics** *(Home, M)* — `.contextMenu` per row + trailing ⋯; inline rename → `renameProject`; `.confirmationDialog` delete → `deleteProject`; Reveal in Finder. (Store methods already exist, unused.)

### P1 — shell, identity & the AI product
- **Settings scene (⌘,)** *(Shell, M)* — `Settings { SettingsView() }`; Storage (projects dir), Appearance (theme), Capture (keep-visible toggle, scale slider). Reserve AI tab for Phase D.
- **Theme token system + report dark-mode fix** *(Visual, M)* — Asset Catalog semantic colors; replace hardcoded hex in the report; `#4f46e5` → `#6344f1`; theme override via `.preferredColorScheme`.
- **Phase D — SOPKit** *(D, XL)* — URLSession client pinned to `api.anthropic.com` + cost estimator + progress/cancel; Keychain API key never surfaced to UI (source stored/env/none + encryption/unreadable states); review-before-send privacy/cost modal; generate/revert, tone/effort/custom-instructions. Depends on `ensureFlattened`.
- **Phase D — ExportKit** *(D, XL)* — HTML/MD verbatim; PDF via offscreen WKWebView; docx/pptx; crop each screenshot to its report zoom/pan; callout glyphs baked for grayscale; byline footer; safe filenames + collision suffix; package export/import (`.zip`, zip-slip confined). Runs `ensureFlattened` first.
- **Home browse power features** *(Home, L)* — sort (name/created/modified) + date-bucket grouping; Projects/Archive tabs + counts + empty states; multi-select + bulk bar; SOP-ready/Draft badge (`hasSop`); startup auto-archive-stale.
- **App menu + create/naming flow** *(Shell/D, M)* — title field on create → `createProject(title:)`; New Empty Project (⌘N); File → Open (⌘O) / Import (⌘⇧O).

### P2 — fidelity & ship polish
- **Report visual fidelity pass** *(Visual, M)* — base width 820→900; zoom floor 0.5→1 (read-floor to fit); header count = all steps incl. callouts; solid-accent number badge + white digit; italic-grey placeholders; two-column rail/body grid.
- **Brand identity & app icon** *(Phase E, early, S)* — `Assets.xcassets` AppIcon set; optional in-window brand header; custom About panel.
- **Hardening & pill polish** *(B follow-up, S)* — main window `sharingType = .none`; pill flash/hint/discard parity; non-modal error banner in the detail pane.

### P3 — discovery & edge states
- **Onboarding, capture defaults & settings edges** *(Onboarding/E, M)* — first-run coach-mark tour (`hasSeenTour`, replayable); RecordSheet default auto→screen; API-key edge states (env fallback, unreadable-ciphertext + Clear); watch for out-of-band project changes.

## Quick wins (cheap, high-impact)

- Accent `#4f46e5` → `#6344f1` in the report — instant on-brand
- Report base width 820→900 and zoom floor 0.5→1 — ends two display divergences
- Header step count = `manifest.steps.count` (all steps incl. callouts)
- Fill the number badge with accent + white digit (currently inverted)
- Main window `NSWindow.sharingType = .none` — closes a content-protection gap
- Wire ⌘O to the existing "Open Project…" action
- RecordSheet default mode auto → screen (Windows' predictable default)
- Add typed `archived`/`archivedAt` now, ahead of the full archive port

## Deliberately do **not** port (native wins)

- **Window width-switching** (720↔1010) — `NavigationSplitView` showing sidebar+detail is the right idiom
- **4-view boolean router** — the master-detail split is an intentional native substitution
- **"← Back" button** — sidebar deselect/select is the native equivalent
- **Custom dropdowns / delete modal** — use native `Menu`/`Picker`/`.confirmationDialog`; the Electron ones dodged web quirks
- **matchMedia theme listener** — macOS auto-follows OS appearance for "system"
- **GPU auto-disable, Windows installer icons** — N/A; the macOS analog is Developer ID + notarization + AppIcon
- **App Store distribution** — impossible: the sandbox forbids AX + event taps → ship via Developer ID

There is **no** auto-update infrastructure and **no** system tray/menu-bar item on Windows — do not invent them for macOS.
