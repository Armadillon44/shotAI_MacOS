# Windows → macOS parity

**Audit date:** 2026-07-28 · **Target:** shipped Windows **v1.1.4** · **Reference:** `shotAI-original/` (v1.1.4 / `d9823ec`) · **macOS build:** `1.1.3` (build 9)

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

**The one feature-level gap: native `.docx` and `.pptx` export.** Windows
ships real Word (via the `docx` lib) and PowerPoint (via `pptxgenjs`) exporters; macOS defers
both (issue #53) and offers "HTML for Word/Docs" as the paste-in substitute. Deferred by
decision. Two smaller Windows-ahead gaps remain, both recorded in the matrix below: the
pre-send SOP review has no per-step preview, and `⌘O` isn't bound to Import. macOS also still
carries the inert legacy per-step **`note`** field that Windows deleted in v1.1.0, which by
decision stays as-is (see "Step `note` field" below).

**macOS still leads Windows v1.1.4** on: the **KB-paste-ready styled HTML export** (images
resampled to the display width and encoded **AVIF**, ~1.4 MB → ~0.17 MB on a real 9-step SOP,
plus a per-block column width so pasted step cards don't stretch — Windows tracks this as
`Armadillon44/shotAI`#56 and #57), the **Liquid Glass** app icon, and the Home
**window-width launch fix** (N/A on Windows — it creates its window at the list width and
persists no bounds, so there is nothing to coerce). The recording pill itself is at parity —
Windows ships an equivalent frameless always-on-top toolbar window (380×74, same controls and
hint/error rows) — macOS leads only in that its pill is a **non-activating** panel, so
clicking it never steals focus from the app being recorded (Windows' never sets Electron's
`focusable: false`). The native **Settings scene** and the **TCC permissions wizard** genuinely
have no Windows analog.

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

### Step `note` field — inert legacy, staying as-is (settled)

Windows removed the per-step `note` field end-to-end in v1.1.0 (`9549d56`): gone from
`ProjectStep`, `StepPatch`, its exporters, and the `User note:` line to Claude. macOS never
mirrored the removal, so `ProjectStep.note` still exists here.

**In practice it is inert on macOS.** Nothing can create one: there is no UI to author or edit
a step note (the report shows caption + instruction only; the "Note" in the ＋ menu is the
`CalloutKind.note` box, a different feature), capture always writes `note: ""`, and Claude no
longer writes one either. Every consumer that still reads it (HTML/Markdown/PDF exporters, the
Claude request assembler, Home search) is guarded by `!note.isEmpty`, so all of them are no-ops
for anything captured on macOS. A non-empty note can only arrive from a project authored by
**Windows before v1.1.0**, or from hand-edited JSON.

The only thing that always happens is `ProjectSchema.swift` encoding `"note": ""` into each
step on write. Harmless: Windows' `normalizeSteps` passes unknown keys straight through.

**Decision (2026-07-28): leave it alone.** Removing the field would be the only change with a
real downside, since it would drop legacy notes carried by pre-v1.1.0 Windows projects from the
report and exports. Keeping the read path costs nothing and preserves them. Recorded here so
it isn't re-litigated as a "gap" by a future audit; **do not "fix" it.**

The only hard ship gate is **distribution** — Developer ID + notarization
(`docs/DISTRIBUTION.md`). The shipped DMGs (1.0.0, 1.1.0, 1.1.1, 1.1.2, 1.1.3) are ad-hoc signed.

## Validation status (hand-tested)

- **Verified end-to-end:** SOP generation, capture, archive/unarchive, exports, report
  editing, section dividers (report + exports), narrow-capture centering, the
  self-contained Markdown export folder, the Home window-width launch fix, and pasting the
  styled HTML export into a real Freshservice KB article (images + column width both correct).
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
| Data model / `project.json` | ✅ matched | Typed `archived`/`archivedAt` and the 4-value `CalloutKind` union (incl. `section`) match; tolerant decode reproduces the Windows coercions; unknown keys round-trip via `extra`. One accepted difference: macOS still writes the inert legacy `ProjectStep.note` key (always `""` for anything captured here) that Windows dropped in v1.1.0 — staying as-is by decision, see "Step `note` field" above. |
| Archive system | ✅ matched | Pack/unpack (hybrid DEFLATE/STORED, hardened), decodes Windows JSZip archives, auto-unarchive on open. |
| App shell & navigation | ✅ matched | Home⇄detail width swap (800⇄1040) + native toolbars; Settings as a native scene. Persisted window width coerced to Home on launch (`coerceMainWindowWidthToHome`). |
| Report / SOP viewer | ✅ matched | Full editing loop — inline caption/instruction + editable title, insert/import/delete/reorder/merge, text steps, callouts, **section dividers** (both apps), per-step zoom + drag-to-pan, overview intro. |
| Section dividers | ✅ matched | Non-counted `CalloutKind.section` on both (Windows added it in v1.1.2): un-numbered, rendered as a divider in report + every export, and Claude's phase headings come through as sections, not extra steps. |
| Narrow-capture centering | ✅ matched | Byte-identical `.step__img{…margin-inline:auto}` (Windows v1.1.2) + report/PDF centering. |
| Export dimensions | ✅ matched | `.doc` 880 + image base 820 — Windows v1.1.3 explicitly ported these to match macOS (its source cites `ReportPresentation.baseWidth`). |
| Project list / Home | ✅ matched | Tabs+counts, sort, date grouping, multi-select bulk bar + destinations + progress, shift-click range select, per-row busy state, inline rename, Reveal in Finder, badges, **full-text search**, and **auto-refresh** (20s poll + foreground, paused during rename/select — Windows pauses during typing). |
| First-run onboarding tour | ✅ matched | 5-step coach-mark spotlight, persisted once-flag, Settings replay. |
| Theme system & dark mode | ✅ matched | `Theme.swift` maps the `project.css` COLOR tokens as dynamic colors (all but `--danger-bd`, unused on macOS); violet accent; light/dark/system. Shape/shadow tokens (`--radius*`, `--shadow*`) are re-derived natively rather than ported. Two intentional dark-legibility tweaks. |
| Settings (tabbed) | ✅ matched | General / AI / Capture / Appearance / Permissions; AI tab has key-create link, per-option blurbs, unreadable-key / secure-storage states. |
| Recording pill | ✅ matched | Two-row hint, per-capture green flash, whole-project discard warning, and an **in-session capture-error surface** on both (Windows added it in v1.1.4; same clear-on-step / clear-on-session / dismiss semantics + red accent bar, but it shows the message inline in row 2 rather than a row-1 chip + tooltip — its 380px row 1 can't fit both). **Ahead:** non-activating panel. |
| SOP generation (Claude) | 🟡 partial | Secure + complete: host pinned, Keychain key, cost estimate, review-before-send, generate/revert, tone/effort/custom-instructions, fail-closed gate. Neither app lets Claude *write* a per-step note any more. **Gap:** the pre-send review shows token/cost totals only; Windows renders a per-step list with a thumbnail, window title and caption for everything being sent (`SopPanel.tsx`). (macOS would still forward a legacy per-step `note` as context if one existed, but nothing on macOS creates one — see "Step `note` field" above.) |
| Export (HTML / PDF / Markdown / Word-HTML / `.zip`) | ⬆️ ahead | All five through the shared fail-closed gate; dimensions + centering + sections match Windows. **Markdown is a self-contained `<name>/` folder** (`<name>.md` + `images/`) for every destination, with folder-level collision numbering (macOS 1.1.1) — matches Windows. The plain-export **738px width/height image cap now matches on both** (Windows v1.1.4). `.zip` packages round-trip between platforms. **Ahead (1.1.2):** the styled HTML resamples images to the 738px display width and encodes **AVIF**, and every top-level block carries its own column width, so the export pastes into a KB article at ~⅛ the size and without stretching. Windows tracks both as `Armadillon44/shotAI`#56/#57; note the codec must differ there (Electron can write WebP but not AVIF; macOS is the reverse). *Note:* the PDF is drawn natively (CoreText/CG) rather than print-to-PDF, so it is not pixel-identical to Windows' — same content and layout, different rasterizer. Native Office formats are a separate row. |
| Native Office export (`.docx` / `.pptx`) | 🔴 macOS gap | **Windows ships both** (Word via `docx`, PowerPoint via `pptxgenjs`; both render cards, sections, centered captures, callouts, and safely handle a macOS-authored section). macOS defers both (→ #53); "HTML for Word/Docs" is the interim paste path. |
| App menu + create/naming | 🟡 partial | Create/naming at parity. **Gap:** Import lacks `⌘O` (Windows binds `CmdOrCtrl+O`). The label differs — "Import shotAI Package…" vs Windows "Import Project…" — but that's cosmetic only: both open a `.zip` package picker (Windows' handler filters to `zip` with `openFile`, same mechanism as macOS). |
| Annotation / redaction editor | 🟡 partial | All 8 tools + fail-closed flatten. **Deliberate gap:** the Vision auto-redact OCR trigger stays unsurfaced (built + tested, no UI caller — by design). Minor: blur softness, crop-box color, per-tool hints. |

## Remaining work

### The one Windows-ahead feature
- **Native `.docx` / `.pptx` export** — [#53](https://github.com/Armadillon44/shotAI_MacOS/issues/53). Windows now ships both; macOS defers. Feasible dependency-free via the existing DEFLATE zip writer (OOXML is zip-of-XML) — do **not** import an Office library. "HTML for Word/Docs" is the interim path.

### Settled, no action
- **Step `note` field** — Windows deleted it in v1.1.0; macOS keeps an inert copy (no UI creates one, capture writes `""`, every reader is empty-guarded). **Decided 2026-07-28: leave as-is** — removing it would only strand legacy notes from pre-v1.1.0 Windows projects. See "Step `note` field" in the Verdict; not a gap, don't re-open it.

### Deferred by decision
- **`.shotAI` registered file type** (double-click to import) — [#49](https://github.com/Armadillon44/shotAI_MacOS/issues/49).

### macOS-only planned work (not a Windows gap)
- **Update / auto-update** — [#62](https://github.com/Armadillon44/shotAI_MacOS/issues/62), investigated 2026-07-28; **Phase 1 shipped in macOS 1.1.3** (2026-08-04, PR #68). macOS now has a **notify-only** daily GitHub-Releases check (a Home notice, Settings opt-out, MDM `updateCheckDisabled` kill switch) plus **post-update TCC re-grant detection** — it never downloads or installs anything. Windows has no updater at all, so macOS is **⬆️ ahead** here; the notify-only half is worth filing as Windows parity (still unfiled). The **self-installing** half is a different call: keep it macOS-specific, per the reasoning below. **Self-installing update is hard-blocked on Phase E** (Developer ID + notarization): the ad-hoc signature's designated requirement is a bare cdhash, so every update would orphan all three TCC grants (Screen Recording / Accessibility / Input Monitoring) and silently break the app. Once signed with Developer ID the requirement becomes bundle-id + team-OU and grants survive updates, which is also what `Intune/shotAI-PPPC.mobileconfig` already pins. A **notify-only** checker (dependency-free, GitHub Releases API) is shippable now and is the recommended first step. If a self-installer is ever built, note it as a deliberate platform-specific feature rather than a Windows gap — Windows has no TCC, so the constraint driving the design doesn't exist there.

### Deliberate deferral
- **Editor Auto-redact trigger** — the OCR pre-scan is built + tested but intentionally not surfaced (Dylan's call). Re-exposing it is a one-line UI add if wanted.

### Fidelity / polish gaps
- **SOP review preview** — add the per-step "exactly what is sent" preview (thumbnails + captions) to the pre-send gate (Windows shows it; macOS shows totals).
- **App menu** — bind `⌘O` to Import (label wording is cosmetic; both platforms import a `.zip` package, so no change needed there).

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

**Tests:** 301 across the six SwiftPM packages (ShotModel 88 · CaptureKit 79 · EditorKit 18 · SOPKit 23 · ExportKit 39 · UpdateKit 54).

## Deliberately do **not** port (native wins)

- **Window width-switching** (720↔1010) — the Home⇄detail width swap + native toolbars are the right idiom.
- **4-view boolean router / "← Back" button** — the full-window swap and native Back are the native substitutions.
- **Custom dropdowns / delete modal** — native `Menu`/`Picker`/`.confirmationDialog`.
- **`matchMedia` theme listener** — macOS auto-follows OS appearance for "system".
- **GPU auto-disable, Windows installer icons / `--silent` switch** — N/A; the macOS analog is Developer ID + notarization + the `.icon`.
- **App Store distribution** — impossible: the sandbox forbids AX + event taps → ship via Developer ID.
- **Native `.docx`/`.pptx` via a JS lib** — when built (#53), do it dependency-free via the existing zip writer, not by importing `docx`/`pptxgenjs`.

There is **no** auto-update infrastructure and **no** menu-bar item on Windows. Don't invent a
menu-bar item for macOS. Auto-update is a different case: neither platform has it, but it is
wanted on macOS and tracked as [#62](https://github.com/Armadillon44/shotAI_MacOS/issues/62) —
so treat that as macOS-only planned work, not a "do not port".
