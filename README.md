# shotAI for macOS

A **local-first SOP builder** for macOS. Record a process on screen; shotAI captures a
screenshot and the clicked UI element for each step, then turns them into an editable,
annotated step-by-step guide. Its differentiator: **Claude** rewrites the captured steps
into a polished Standard Operating Procedure — an overview, per-step instructions, and
cautions/callouts.

Everything runs and is stored **on your Mac**. The only network call is to Anthropic's
API, and only when you ask shotAI to write the SOP. This is a native Swift/SwiftUI port of
the [Windows app](https://github.com/Armadillon44/shotAI); `project.json` is
byte-compatible, so projects **round-trip between platforms**.

> **Status:** **1.0.0-rc3** (build 3) — release candidate. Capture engine, native SwiftUI
> annotation editor, redaction (manual + local Vision OCR auto-redact), Claude SOP
> generation with review-before-send + one-click revert, element-at-point captions (native
> Accessibility), export to HTML / PDF / Markdown / "HTML for Word" + a shareable
> round-trip `.zip` package, project archiving, and light/dark theming are all implemented.
> **Distribution is not finished yet:** the current release DMGs are **ad-hoc signed**, so
> Gatekeeper blocks the first launch until you clear quarantine (see [Install](#install)).
> Developer ID signing + notarization is the remaining ship step
> ([docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)).

## How it works

1. **Record.** Choose a capture mode — whole **Screen**, a single **Window**, a dragged
   **Area**, or **Auto** (picks per click) — name the project, and click through your
   process in any app. For each click shotAI records a **screenshot**, the **active
   window**, the **name of the UI element** you clicked (via macOS Accessibility), and
   **where** you clicked (drawn as a marker on the step). A small non-activating capture
   **pill** shows progress with a persistent hint ("Click anything to capture a step ·
   ⇧⌘S") and flashes a **green ring** to confirm each captured step; the app hides its own
   windows so they never land in the shots. Press **⇧⌘S** to grab the current screen on
   demand. Right-click menus are captured as their own step, and double-clicks are
   collapsed into one.

2. **Review & annotate.** Each step is a card in the report — retitle it, edit the
   instruction, or edit the project title in the header. Open the native image editor to
   draw **boxes**, **arrows**, **numbers**, and **text**, adjust the click **marker**,
   **crop**, or **redact/blur** sensitive regions. Redactions are **baked into a flattened
   PNG** copy of the screenshot; the original pixels never leave your machine for any export
   or AI request (the send/export path is **fail-closed** and refuses a step whose
   redactions aren't baked). **Auto-redact** runs the **Vision framework locally** (offline)
   to find and suggest sensitive text. Each report step supports liquid-glass image zoom
   with drag-to-pan.

3. **Generate the SOP (optional).** With **your own** Anthropic API key, Claude reads the
   redaction-baked screenshots + captions and writes the guide **in place**: an overview,
   per-step headings and instructions, and callouts — in your chosen **tone** and
   **effort**. Before anything is sent you see an **estimated cost**; a single click
   **reverts** to your pre-AI version.

4. **Export & share.** Export to **HTML**, **PDF**, **Markdown**, or **HTML for Word**
   (a minimal-Arial semantic file that pastes cleanly into Word / Google Docs). Each frames
   every step as its own card — the same visual step separation you see in the report. Or
   export a shareable **`.zip` package** that another shotAI user (macOS or Windows) can
   **import** and keep editing.

5. **Manage.** The Home screen lists projects with **search**, sort, and **date grouping**,
   a **Draft / SOP-ready** status chip, and **multi-select** for bulk **archive / export /
   delete** (bulk export lets you choose a destination folder and shows progress).
   **Archiving** compresses a project in place to save disk while keeping it under an
   **Archive** tab; opening an archived project restores it automatically, and old projects
   can auto-archive by age.

### Privacy & local-first

Projects — screenshots, `project.json` manifest, and exports — live in a folder on your
Mac (`~/shotAI Projects` by default). Nothing is uploaded except SOP-generation requests,
which go only to Anthropic (`api.anthropic.com`, **pinned** in the client — there is no
base-URL override). The API key is yours, stored in the **macOS Keychain** and read only by
the Claude client, never surfaced back to the UI. No telemetry.

## Tech stack

- **Swift 6 / SwiftUI**, a single native app process. **Zero third-party dependencies** —
  everything is Apple frameworks.
- Five in-repo **SwiftPM** packages (UI-free, tested headless):
  - **ShotModel** — the Codable `project.json` schema (byte-compatible with Windows,
    tolerant decode), path-confined atomic writes, and a `ProjectStore` actor.
  - **CaptureKit** — the recording engine: **ScreenCaptureKit** screenshots, **Accessibility**
    element-at-point captions, a **CGEvent** tap for clicks, a **Carbon** ⇧⌘S hotkey, and
    the TCC permission surface.
  - **EditorKit** — the annotation flatten/redaction pipeline and **Vision** OCR
    auto-redaction.
  - **SOPKit** — the Anthropic Messages API client (URLSession, pinned host), Keychain key
    store, cost estimator, and prompt assembly.
  - **ExportKit** — the HTML / PDF / Markdown / "HTML for Word" renderers and the `.zip`
    package export/import (PDF is rendered natively via CoreText + CoreGraphics).
- The app target lives under [`shotAI/`](shotAI/) (Home, report/editor, capture UI, Settings).

## Requirements

- **macOS 14.0+** (Sonoma) — the floor for ScreenCaptureKit's `SCScreenshotManager`.
- **Apple Silicon**.
- Screen Recording, Accessibility, and Input Monitoring permissions (granted through a
  first-run wizard).
- An Anthropic API key **only** if you want SOP generation — capture, editing, redaction,
  and export all work without one.

## Install

1. Download the latest `shotAI-<version>.dmg` from
   [GitHub Releases](https://github.com/Armadillon44/shotAI_MacOS/releases) and drag
   **shotAI** into `/Applications`.
2. **Clear the Gatekeeper quarantine.** Because this RC is **ad-hoc signed** (Developer ID
   notarization is still pending), macOS blocks the first launch. Either:

   ```sh
   xattr -dr com.apple.quarantine /Applications/shotAI.app
   ```

   or open it once, then go to **System Settings ▸ Privacy & Security ▸ Open Anyway**.
3. **Grant permissions.** On first run, the permissions wizard walks you through enabling
   **Screen Recording**, **Accessibility**, and **Input Monitoring** in System Settings and
   polls until each is granted.

## Building from source

Requires Xcode 26 / Swift 6.3 on Apple Silicon.

```sh
# Build the app
xcodebuild -project shotAI.xcodeproj -scheme shotAI -configuration Debug build

# Per-package unit tests (all headless)
swift test --package-path Packages/ShotModel
swift test --package-path Packages/CaptureKit
swift test --package-path Packages/EditorKit
swift test --package-path Packages/SOPKit
swift test --package-path Packages/ExportKit

# Live smoke tests (drive the real frameworks)
swift run --package-path Packages/CaptureKit CaptureSelfTest   # needs Screen Recording
swift run --package-path Packages/ExportKit PdfSelfTest        # exercises the PDF renderer
```

The app target is manually signed with an **Apple Development** cert (team `JX6BU857VX`)
so TCC grants persist across rebuilds; a fresh checkout will need its own dev signing
identity. See [`CLAUDE.md`](CLAUDE.md) for the full command list and signing notes, and
[`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md) + [`Scripts/dist.sh`](Scripts/dist.sh) for
the Developer ID / notarization pipeline.

## Claude API key

SOP generation is **bring-your-own-key** and off until you add one. Set it in
**Settings ▸ AI** (⌘,), where it is stored in the **macOS Keychain**; a read-only
`ANTHROPIC_API_KEY` environment variable is honored as a dev/CI fallback. The UI never
reads the key back — it only sets, clears, and reports status.

shotAI uses **Claude Sonnet 5** (`claude-sonnet-5`) by default. The **tone**
(Professional / Friendly / Concise / Detailed — Professional by default) and **effort**
(Low / Medium / High — Medium by default) are configurable, plus optional free-text custom
instructions. With no key, capture, editing, redaction, and export all still work — only
the AI SOP step is unavailable.

## Project layout

```
shotAI.xcodeproj / shotAI/    SwiftUI app target: Home, report + editor,
                                capture UI (pill/overlay/permissions wizard), Settings
Packages/ShotModel/           Codable project.json schema, path confinement, ProjectStore
Packages/CaptureKit/          capture engine (SCK / AX / CGEvent tap / Carbon hotkey / TCC)
Packages/EditorKit/           annotation flatten + redaction bake + Vision OCR
Packages/SOPKit/              Anthropic client (pinned), Keychain key store, cost/prompt
Packages/ExportKit/           HTML / PDF / Markdown / HTML-for-Word + .zip package
Scripts/dist.sh               Developer ID sign → notarize → staple → DMG/pkg
Intune/                       PPPC profile + MDM notes for internal rollout
Fixtures/                     a simulated Windows-created project (round-trip test data)
docs/                         distribution guide (Phase E)
CLAUDE.md · FEASIBILITY.md · PARITY.md   port assessment + Win→Mac parity roadmap
```

On disk, each project is a folder under `~/shotAI Projects/`: a byte-compatible
`project.json` manifest, a `shots/` folder of screenshots (baked renders), an `export/`
folder, and (when archived) an `archive.zip`.

## Documentation

Full docs, guides, and screenshots live in the
[**Wiki**](https://github.com/Armadillon44/shotAI_MacOS/wiki).

## License

[MIT](LICENSE) — © 2026 LFI.
