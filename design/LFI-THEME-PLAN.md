# Implementation plan — the "LFI" theme

**Status:** plan only. Nothing implemented.
**Open questions:** none — all settled 2026-09-09, see §6.
**Design source:** [`design/lfi-theme-study.html`](lfi-theme-study.html) (published mock-up) and `design/lfi-design-system/`.
**Companion issue (Windows):** to be filed on `Armadillon44/shotAI`.

This document is written to be ported. Every count and file reference below was
measured against the tree at `985515b`, and the Windows section is a survey of the
live `v1.2.0` repo, not the pinned `shotAI-original/` clone (which is `v1.1.4` and
predates several of the files involved).

---

## 1. The finding that shapes everything

**Theming today is one axis, not two.** `Palette` is 35 `static let` tokens, each an
`NSColor(name:)` whose provider branches on the *OS appearance* (`aqua` vs `darkAqua`).
`ThemePref` (`system`/`light`/`dark`) never reaches `Palette` — it is applied only as
`.preferredColorScheme(...)` at the two scene roots, which changes the window's
appearance, and the providers then resolve correctly for free.

A brand is not an appearance. The mock-up has LFI in **both** light and dark, so the
real shape is **theme × appearance = 2 × 2 = 4 palettes**. There is no seam in `dyn()`
for a third input.

**The invalidation crux.** Reading `Palette.accent` from a view body registers *no*
SwiftUI dependency — it is not `@State`, not `@Environment`, not `@Observable`. Flip a
theme global and nothing re-renders. Worse, it fails *partially*: any view that
re-renders for an unrelated reason (hover, scroll, a model mutation) picks up the new
colour, so the window ends up half-old and half-new. That reads as a flaky bug rather
than a missing wire.

Three approaches were considered:

| Approach | Verdict |
|---|---|
| Global that the `NSColor` provider reads | **Silently does nothing.** No dependency, no re-render. |
| `.id(theme)` on the root view | **Rejected.** Forces a rebuild, but destroys every `@State` below it — scroll position, editor state, inline-edit focus, sheet presentation. Unacceptable while a project or the editor is open. |
| `@Environment(\.palette)` | **Chosen.** Declaring and reading it in a body is exactly what registers the dependency. |

So `Palette` becomes a `struct PaletteTokens` with 35 stored `Color` fields, two static
instances (`.shotAI`, `.lfi`), each field still built by the existing `dyn(light,dark)`.
The appearance axis stays inside `NSColor`, where it already provably works. Only the
brand axis is lifted into SwiftUI.

**Cost: 118 call sites across 8 files** become `pal.accent` instead of `Palette.accent`.
Mechanical, but wide.

Two sites are *not* mechanical and need real thought:

- `ReportView.swift:994` — `var color: Color = Palette.ink` is a default argument on
  `InlineEditable`'s memberwise init. A default argument cannot read `@Environment`.
  It becomes `Color? = nil`, resolved in `body`, and every caller relying on the
  default has to be checked.
- `Editor/EditorOverlay.swift:75` — `private let brand = Palette.accent` is a stored
  property, captured once at init.

---

## 2. Scope: what "everything" actually covers

A `Palette`-only change reskins **Home and the report view, and nothing else.** The
rest of the app is not tokenized:

| Surface | State today | In scope? |
|---|---|---|
| Home, report view | Fully tokenized | **Yes** — this is what the mock shows |
| Settings | Stock `Form`/`Section`/`Picker`; 29 semantic colours, 5 `Palette` refs | Accent only (see §6) |
| Annotation editor | Mixed; some hardcoded hex | Yes, phase 2 |
| Record / permissions sheets, tour | Mostly stock | Yes, phase 2 |
| Capture pill, area-select, click markers | Deliberately theme-agnostic hardcoded | **No — settled** |
| HTML / PDF exports | 61 hardcoded colours in ExportKit | **Yes** — see §5 |
| Markdown export | No styling at all | N/A |

The capture-surface exclusion is a decision already taken: those colours stay
hardcoded, matching Windows. **Consequence to accept knowingly:** during a recording
the violet area-select rectangle still appears, so the corporate theme is not
end-to-end.

---

## 3. Phase 0 — tokenize with no visual change

**This is the most important phase and it ships zero user-visible difference.**

Right now the same step card is implemented in **two colour vocabularies on macOS**
(`Theme.swift`, and `HTMLExport`+`PdfExport`) and **four on Windows** (`project.css`,
`export-css.ts`, `export-docx.ts`, `export-pptx.ts`). They have already drifted:
**four colour divergences exist today between `docCSS` and `PdfExport.Ink`** (section
heading, section body, section rule, badge text), and the Windows toolbar carries a
drifted accent (`#4f46e5` against the app's `#6344f1`).

Adding a second brand on top of un-tokenized, already-drifted copies makes the
regression surface invisible. So:

1. Extract every literal into a token, keeping the **exact current values**.
2. Add tests that assert the current values, so any later change is deliberate.
3. Add a parity test asserting the HTML and PDF palettes agree — this is what would
   have caught the four existing divergences.
4. Ship it. Nothing looks different.

Only then add LFI values. Do the same on Windows before its port.

---

## 4. Phase 1–3 — macOS, app chrome

### Phase 1 · Colour plumbing
- `Palette` → `struct PaletteTokens`, two instances, `@Environment(\.palette)`.
- Set at both scene roots (`shotAIApp.swift:46`, `:115`) beside `.preferredColorScheme`.
- 118 call-site edits; 2 structural fixes above.
- **Settings UI: two controls, not one.** `ThemePref` (System/Light/Dark) stays as the
  *appearance*; a new `BrandPref` (shotAI/LFI) is the *brand*. Collapsing them into one
  six-case picker would misrepresent them as mutually exclusive.
- New optional key in `AppPreferences`, decoded with `decodeIfPresent` and defaulted, so
  existing preference files load unchanged.

### Phase 2 · Geometry
There are **47 `cornerRadius:` literals across 10 files, but only ~30 distinct decision
sites** — 29 of the 47 are duplicated inside 14 adjacent `overlay`/`clipShape` pairs on
the same view. 43 of 47 are themeable chrome; 4 are annotation data or canvas handles
and must not move. Two pairs must move in lockstep or break visually:
`Tour.swift:126↔146` (spotlight ring ↔ mask cutout) and
`CapturePill.swift:190↔326` (pill silhouette ↔ flash ring).

**A single `8` is wrong.** 8px on the 26×16 percent field or the 12pt editor handles
looks broken. Introduce a small scale — `Radii.card` / `.control` / `.small` — rather
than one value. There are **zero** radius constants in the repo today, so this is
greenfield.

**Two things the mock-up implies that should be decided explicitly:**
- The mock draws status chips as 8px rounded rects. In the app they are `Capsule()`.
  There are **17 Capsules and 13 Circles** — search field, mode toggle, status pills,
  sign-in chip, update badge. Converting them is a substantial visual change, not a
  token flip. **Recommendation: keep them capsules.** The mock overstated this.
- The on-screen report card is 10px and the exported HTML card is 12px — they already
  disagree. *Settled: the **export moves to 10** to match the report, not the reverse.*
  This is a real, if tiny, visual change to already-shipped output, so it cannot ride in
  phase 0 (which is defined as no-visual-change). It gets its own commit with a test, on
  both platforms. Default brand is then 10px everywhere; LFI is 8px everywhere.

### Phase 3 · Typography
- **154 font references across 16 files; 144 are call sites needing a decision.** 17
  distinct hardcoded point sizes. A half-built `Typo` enum exists (`Style.swift`, 7
  tokens) but has only 8 consumers, all in `HomeView`.
- Archivo: two OFL variable TTFs, **1.4 MB** total, `wdth` 62–125.
- **The condensed treatment is reachable** — verified via `NSFontDescriptor` +
  `kCTFontVariationAttribute`; the instance survives `.weight()` and
  `.monospacedDigit()` and bridges to SwiftUI as `Font(CTFont)`.
- **wdth 66 (the study's value) needs that variation route. wdth 62 is Archivo's named
  Condensed instance and works with a bare `Font.custom`.** At 12pt the visual
  difference is a few percent of advance width; the implementation difference is a whole
  abstraction. **Recommendation: use 62 and delete the abstraction.**
- Bundling trap: the target uses `GENERATE_INFOPLIST_FILE` with no Info.plist on disk,
  and Xcode defines no `INFOPLIST_KEY_` for `ATSApplicationFontsPath`. Prefer
  `CTFontManagerRegisterFontsForURL(.process)` at launch — **it avoids touching bundle
  generation, which matters here because TCC grants key off the code-signing designated
  requirement.** Caveat: anything drawn before registration falls back to the system face.
- Non-issues, contrary to expectation: Dynamic Type (macOS SwiftUI ignores it),
  `monospacedDigit` (works on custom fonts), SF Symbols (carry weight correctly).
- Real cost: 144 call sites **plus a reflow pass on every fixed-width frame**, because
  Archivo's advance widths differ from SF.
- 4 call sites must not change — Helvetica parity with the flattened annotation renderer
  (`EditorModel:273`, `EditorOverlay:347/542/548`, source of truth `Flatten.swift:299-300`).

---

## 5. Phase 4 — exports

ExportKit is cleanly isolated: **it never reads `Palette`** (the 4 mentions in
`PdfExport.swift` are comments), and depends only on `ShotModel`. Colour lives in
exactly two places:

- `HTMLExport.swift` — **39 hex literals** across `docCSS` (35) and `plainCSS` (4).
- `PdfExport.swift` — `enum Ink`, **20 hex + 2 bare `.white`**.

`docCSS(scale:)` and `plainCSS(scale:)` are already parameterized free functions whose
caller derives the value from the manifest, so a `theme:` argument slots in exactly the
way `scale:` did. The PDF is harder: `Ink` is a namespace of statics referenced from both
a free function and a class, so it must become a value threaded through `PdfCanvas.init`.

**Five greys have no `Palette` equivalent** (`#1f2937`, `#6b7280`, `#374151`, `#e5e7eb`,
`#cbd5e1` — 16 of the 59 occurrences). Snapping them to the nearest token changes how the
*current* export looks for every existing user. Keep them as neutral tokens the theme
overrides, rather than silently re-mapping.

### Two rules I recommend adopting

**Exports are always the theme's LIGHT values.** A dark-background PDF is unreadable
printed and ruinous on toner. The export axis is *which brand*, never *which appearance*.
This also means the export theme needs its own wording in Settings so nobody expects dark
mode to travel.

**Do not embed the font in HTML exports — it is arithmetically impossible.** Archivo as
base64 is **~1.37 MB against a measured 0.8–1.5 MB total Freshservice paste budget**. It
would consume the entire budget and the images would silently drop. Name Archivo first in
the CSS stack (it renders for anyone who has it, falls back gracefully otherwise) and
bundle it only for the native PDF renderer, which embeds properly and is the one format
where fidelity is guaranteed.

**Out of reach entirely:** baked annotation colours. Click rings and markers
(rose `#e11d48`, blue `#2563eb`) are flattened into the PNG at save time. Retinting them
means re-flattening every step of every project and rewriting `project.json`. Recommend
accepting rose markers inside a rust-and-charcoal document, or treating it as separate work.

---

## 6. Recommendations on the open questions

| Question | Recommendation | Why |
|---|---|---|
| Where does the theme live? | **Both** — see §6a | *Settled 2026-09-09.* App preference drives app chrome; the project carries its own theme so its report and exports are reproducible on any machine. |
| LFI as a peer of light/dark, or orthogonal? | **Orthogonal** — two pickers | The mock has LFI in both appearances. A single six-case picker would misrepresent them. |
| Do exports follow the app theme? | **Yes, brand only, always light** | See §5. |
| Semantic colours | **Forest `#3E7D5A` / tan / destructive**, as settled in the study | Measured 6.83:1 on its own tint against the olive's 5.56:1. |
| Stock macOS controls | **Leave stock; `.tint()` only** | Genuinely restyling `Form` means replacing it. Disproportionate, and Settings is not a surface users stare at. Accept that Settings stays mostly system chrome. |
| Capsules → 8px rects? | **No, keep capsules** | 17 sites, substantial visual change, and the mock overstated it. |
| wdth 66 or 62? | **62** | Named instance, no variation-axis abstraction, indistinguishable at UI sizes. |
| Ship the italic TTF? | **No** | 741 KB of the 1.4 MB, and only `PdfExport` has an italic path. |

### 6a. Resolution model — app preference *and* project *(settled)*

The theme lives in two places with a defined precedence, mirroring how `displayScale`
already works.

**`AppPreferences.brand`** — an app preference. Governs Home, Settings, the sheets and
the wizard. This is the operator's choice.

**`ProjectManifest.theme`** — an additive optional key in `project.json`. Governs that
project's report rendering **and all of its exports**, so the same project produces the
same document on any machine.

**Precedence, stated once so both platforms implement it identically:**

1. A project with a `theme` key renders and exports in that theme, **including the
   window chrome while it is open.** A half-LFI window — corporate report inside a
   violet shell — is incoherent, and the report is meant to be WYSIWYG with the export.
2. A project with no `theme` key falls back to the app preference. Existing projects
   therefore behave exactly as they do today.
3. Home and Settings always use the app preference; they belong to no project.

**Write rule, copied from `displayScale`:** the key is stamped at project creation from
the current app preference, and **omitted entirely when it is the default brand.** A
shotAI-branded project writes nothing, so existing projects and the common case stay
byte-identical; only an LFI project carries the key. The store must also refuse a no-op
write, because `mutate` bumps `updatedAt` unconditionally — the same trap `setDisplayScale`
already guards against.

**Where the user changes it:** a per-project control in the report toolbar beside the
document-size slider. Same place, same semantics, same precedent.

**Cross-platform:** this is a schema change and needs the Windows companion issue before
either side ships it. Tolerant decode means a macOS-written `theme` key round-trips
through an older Windows build untouched via `extra`, so a staggered rollout is safe —
Windows will render such a project in its own theme until it learns the key, which is
the same way `displayScale` rolled out.

---

## 7. Windows port

**Windows is easier for app chrome and harder overall.**

Easier: theming is one 39-token CSS custom-property block in
`src/renderer/project/project.css` (`:root` light, `:root[data-theme='dark']` overriding
37), applied by `theme.ts` setting `<html data-theme>`, with **386 `var(--…)` reads**
already in place. A third theme really is close to "another `[data-theme]` block." The
one hardwired-to-two chokepoint is `resolveDark(pref): boolean`, which becomes
`resolveTheme(pref): ThemeId`. The Settings UI is already a data-driven array.

Harder: **five surfaces to theme against macOS's two.**

| Surface | State | Note |
|---|---|---|
| `project.css` | 39 tokens, 386 reads | The easy one |
| `src/main/export-css.ts` | **38 hex, zero tokens**, commented *"Light-only (exports don't theme)"* | **New in v1.2.0 — absent from the pinned v1.1.4 clone** |
| `export-docx.ts` | 17 hex string constants | Third hand-copy of the palette |
| `export-pptx.ts` | 23 hex string constants | Fourth hand-copy |
| `toolbar.css` / `overlay.css` | Separate documents, never receive `data-theme`, drifted accent | Out of scope per the capture-surface decision |

Radius: **79 `border-radius` declarations, only 15 using a `var(--radius*)` token** — 64
literals to extract.

Fonts: **zero font files and zero `@font-face` rules in the entire Windows repo.**

**Word cannot draw a rounded card.** The `.docx` step card is a single-cell table with
square borders. *Settled: a square-cornered `.docx` is accepted as a documented
divergence.* No DrawingML re-implementation.

---

## 8. Sequencing

| Phase | Ships | Visible change |
|---|---|---|
| 0 | Tokenize both platforms; parity tests | **None** — by design |
| 0b | Export card radius 12 → 10, both platforms | 2px, on new exports only |
| 1 | macOS colour plumbing + LFI palette + Settings picker | Home and report reskin |
| 1b | `theme` key in `project.json` + per-project control | Projects pin their brand |
| 2 | Geometry tokens, 8px card radius | Corners tighten |
| 3 | Archivo bundling + type tokens | Typeface changes |
| 4 | Themed exports (HTML + PDF) | Exported SOPs reskin |
| 5 | Windows port, phases 0→4 | Parity |

Phase 0 on both platforms should land before any LFI values on either. Phases 1–3 are
independently shippable and independently revertible; each is a real improvement to the
codebase even if LFI is later abandoned, which is the main argument for doing them in
this order rather than as one large branch.

---

## 9. Things deliberately not done

- **Capture surfaces stay violet.** Settled. The theme is not end-to-end during a recording.
- **Baked annotation colours stay rose/blue.** Would require re-flattening every project.
- **Settings stays stock chrome** beyond the accent tint.
- **No webfont embedding in HTML exports.** Budget-impossible, see §5.
