# Windows → macOS parity

**Audit date:** 2026-07-20 · **Target:** shipped Windows **v1.0.2** · **Reference:** `shotAI-original/` (v1.0.2 / `753c399`) · **macOS build:** `1.0.0-rc4`

Roadmap of record for the macOS port's parity with the shipped Windows app. This is a
full surface-by-surface re-audit (Windows v1.0.2 read from source, diffed against the
current macOS build) and **supersedes the 2026-07-08 audit**, whose "roughly a third
built" verdict is obsolete — everything it listed as missing (Settings, archive, SOP,
export, app icon, theming, the editing loop) has since shipped.

## Verdict

**At functional parity. What remains is polish, two deliberate deferrals, and one missing
feature.** Every core surface is implemented and — per hand-testing — works end-to-end:
capture, the full report editing loop, annotation/redaction, the Claude SOP pipeline,
export, project management, archiving (including the Windows round-trip), Settings,
theming, and a Liquid Glass app icon. **~206 unit tests pass** across the five SwiftPM
packages (ShotModel 86 · CaptureKit 57 · EditorKit 18 · SOPKit 23 · ExportKit 22).

The prior audit's **P0 cross-platform archive bug is fixed** — typed `archived`/`archivedAt`,
pack/unpack, auto-unarchive on open, and no `updatedAt` bump, all test-covered; a
Windows-archived project now restores cleanly on macOS.

In a few places the port is **ahead of** v1.0.2: full-text Home search, a bulk-export
progress indicator, a non-activating capture pill, and the Liquid Glass icon have no
Windows equivalent.

The only hard ship gate left is **distribution** (Developer ID + notarization), tracked
separately in `docs/DISTRIBUTION.md` — not in this parity doc.

## Validation status (hand-tested)

- **Verified end-to-end:** SOP generation, capture, archive/unarchive, exports, report editing.
- **Capture modes:** Screen ✅ and Window ✅ hand-verified. **Auto mode on a multi-monitor
  setup is not yet hand-tested** (the display-resolution / click-display fallback paths are
  unit-tested only). This is the one open live-validation item.

## Parity matrix

| Surface | Status | Where it stands now |
|---|---|---|
| Capture engine | ✅ matched | Behavior-for-behavior port of `CaptureController.ts` (double-click collapse, right-click menu arming, 4-deep menu chain, own-window gating, grab cascade, discard logic). 57 tests pass. *See multi-monitor caveat above.* |
| Coordinate / geometry | ✅ matched | `GrabMath`/`ImageOutput` port `capture-geometry.ts` formula-for-formula; schema invariant `image == round((global−origin)×scale)` tested; round-trips with Windows physical-px projects. |
| Permissions / TCC | ✅ matched | All three TCC classes, per-pane deep links, 1s-polling wizard shared with Settings, relaunch helper. macOS-only surface, complete. |
| Region / area select | ✅ matched | Per-screen overlay excluded from capture; drag/confirm/cancel + size badge match the Windows UX. |
| Data model / `project.json` | ✅ matched | Field-for-field mirror of `project.ts` incl. typed `archived`/`archivedAt`; tolerant decode reproduces the Windows coercions; unknown keys round-trip via `extra`; encode reproduces Windows key order + null-vs-absent shape. |
| Archive system | ✅ matched | **P0 fixed.** Pack/unpack (hybrid DEFLATE/STORED, fail-closed, zip-slip + symlink hardened), decodes Windows JSZip archives, auto-unarchive on open without bumping `updatedAt`, age-based auto-archive. Fully test-covered + hand-verified. |
| App shell & navigation | ✅ matched | Home⇄detail full-window swap + animated width; per-surface native toolbars; Settings as a native scene (intentional macOS idiom). |
| Report / SOP viewer | ✅ matched | Full editing loop — inline caption/instruction + editable title, insert/import/delete/reorder/merge, text steps + callouts, per-step zoom + drag-to-pan, overview intro. At/above Windows `Report.tsx`. |
| Theme system & dark mode | ✅ matched | `Theme.swift` maps every `project.css` token as a dynamic color; accent is violet `#6344F1` (not the old indigo); light/dark/system via `.preferredColorScheme`. Two intentional dark-legibility tweaks. |
| App icon / brand identity | ✅ matched | Liquid Glass Icon Composer `.icon` (layered, macOS 26 material + flattened fallback); two-tone wordmark + tagline brand header. |
| Recording pill | 🟡 partial | Two-row hint + per-capture green flash + non-activating panel + in-session error badge all present. **Gap:** discard never warns when it will delete the *whole* new project (Windows R5 `willDeleteProjectOnDiscard`) — the path is reachable and deletes correctly, only the honest wording is missing. |
| Settings (tabbed) | 🟡 partial | 5 tabs cover the Windows 5 (Capture at parity; Storage/Theme/Name relocated; Permissions is a correct macOS addition). **Gaps:** AI tab lacks the "create a key" link, per-option blurbs, and unreadable-key/ciphertext states; no tour-replay control (blocked on the tour). |
| App menu + create/naming | 🟡 partial | Create/naming at parity; menu has About/Settings/Import/Export/Quit. **Gaps:** Import lacks the `⌘O` accelerator; label is "Import shotAI Package…" vs Windows "Import Project…". |
| Project list / Home | 🟡 partial | Matches on tabs+counts, sort, date grouping, multi-select bulk bar, per-row menus, inline rename, delete confirms, Reveal in Finder, SOP-ready/Draft badge — and is ahead on search + bulk-export progress + `.zip`. **Gaps:** export menus omit `.docx`/`.pptx` (→ #53); no shift-click range select; ascending date-group ordering is inconsistent; no per-row busy state. (Import is surfaced in the Home toolbar between the New-project and Refresh buttons — a native placement, not a gap vs Windows' inline list-head button.) |
| Annotation / redaction editor | 🟡 partial | All 8 tools + fail-closed flatten; Vision auto-redact pipeline exists and is tested. **Gap:** the Auto-redact trigger is intentionally not surfaced in the UI, so users can't run the OCR pre-scan (Windows has a top-bar button). Minor: blur softness, crop-box color, per-tool hints. |
| SOP generation (Claude) | 🟡 partial | Functionally complete + secure: host pinned, key never surfaced (Keychain), cost estimate, review-before-send, generate/revert, tone/effort/custom-instructions, fail-closed redaction gate. **Gaps:** the review gate shows totals but no per-step preview of what's sent; per-step `note` dropped from the AI schema; thinner key-status states than Windows. |
| Export | 🟡 partial | HTML, PDF (native CoreText/CG), Markdown, and "HTML for Word/Docs" through the shared fail-closed gate + byline + collision suffixing; `.zip` package export/import round-trips with Windows. **Gap:** native `.docx`/`.pptx` deferred by decision (→ #53). PDF is drawn natively, so it won't be pixel-identical to the Windows print-to-PDF. |
| First-run onboarding tour | 🔴 missing | No coach-mark tour. Windows ships `Tour.tsx` (5 spotlight steps, once-flag `hasSeenTour`, replay from Settings). The permissions wizard covers TCC only. |

## Remaining work

### Deferred by decision (post-1.0)
- **Native `.docx` / `.pptx` export** — [#53](https://github.com/Armadillon44/shotAI_MacOS/issues/53). Feasible dependency-free via the existing DEFLATE zip writer (OOXML is zip-of-XML). "HTML for Word/Docs" is the interim path.
- **`.shotAI` registered file type** (double-click to import) — [#49](https://github.com/Armadillon44/shotAI_MacOS/issues/49).

### Missing feature
- **First-run onboarding tour** — port `Tour.tsx` (spotlight bubbles over hero / Capture / mode / pill / Settings), a persisted once-flag, and a Settings replay entry point. Needs a macOS anchoring mechanism for spotlighting Home controls.

### Fidelity / polish gaps
- **Pill discard honesty** — surface `willDeleteProjectOnDiscard` and warn "the entire project will be deleted" for a new-project discard (Windows R5).
- **Editor Auto-redact trigger** — re-expose the (already-built, tested) OCR pre-scan in the editor UI.
- **SOP review preview** — add the per-step "exactly what is sent" preview (thumbnails + captions) to the pre-send gate.
- **Settings AI tab** — key-create link, per-option blurbs, unreadable-ciphertext / secure-storage-unavailable states + Clear.
- **Home niceties** — shift-click range select; fix ascending date-group bucket order; per-row busy indicator. (Import is already surfaced in the Home toolbar; no change needed.)
- **App menu** — bind `⌘O` to Import; consider the "Import Project…" label.

### Needs live validation
- **Auto capture across a multi-monitor arrangement** (the one untested capture path).

### Doc hygiene
- Stale header comments claim work is unfinished when it has shipped: `Archive.swift` ("read side only"), `SystemPrompt.swift` / `RequestAssembler.swift` ("ported character-for-character" — the prompt has intentionally diverged).

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
