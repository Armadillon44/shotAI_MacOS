# shotAI for macOS

A **local-first SOP builder** for macOS. Record a process on screen; shotAI captures a
screenshot and the clicked UI element for each step, then turns them into an editable,
annotated step-by-step guide. Its differentiator: **Claude** rewrites the captured steps
into a polished Standard Operating Procedure — an overview, per-step instructions, and
cautions/callouts.

Everything runs and is stored **on your Mac**. The only network calls are to Anthropic's
API when you ask shotAI to write the SOP, and a once-a-day "is there a newer release?"
check against GitHub that you can turn off. This is a native Swift/SwiftUI port of
the [Windows app](https://github.com/Armadillon44/shotAI); `project.json` is
byte-compatible, so projects **round-trip between platforms**.

> **Status:** **1.1.3.** Capture engine, native SwiftUI
> annotation editor, manual redaction (blur or solid box, baked into a flattened copy), Claude SOP
> generation with review-before-send + one-click revert, element-at-point captions (native
> Accessibility), export to HTML / PDF / Markdown / "HTML for Word" + a shareable
> round-trip `.zip` package, project archiving, a first-run tour, and light/dark theming are
> all implemented.
> **New:** **Single sign-on.** Where an organization has configured it, staff sign in with
> their **work account** and Claude just works — no API key issued, stored, or typed on any
> machine, and no gateway or proxy in between. Access is an identity-provider role assignment,
> so revoking someone revokes Claude with it. Bring-your-own-key is unchanged for everyone
> else. See [docs/SSO-WIF.md](docs/SSO-WIF.md).
> **In 1.1.3:** shotAI now **tells you when a newer version is out** — a once-a-day check
> with a small notice on the Home screen, opt-out in Settings. It never downloads or installs
> anything itself. And because macOS resets an un-notarized app's permissions on every update,
> shotAI now **detects that and explains it** instead of silently failing to record.
> **In 1.1.2:** the styled **HTML export now pastes cleanly into a knowledge base**
> (tested against Freshservice): images are resampled and encoded as **AVIF**, taking a real
> 9-step SOP from 1.4 MB to ~0.17 MB, and the step layout keeps its column width.
> **In 1.1.1:** the **Markdown export is a self-contained `<name>/` folder** (the `.md`
> plus its `images/`), so it moves or zips as one unit — matching the Windows app.
> **In 1.1.0:** non-counted **section dividers** (phase headings that aren't numbered
> steps — Claude uses them to group a procedure into phases); narrow captures are centered
> at a uniform width across the report and exports; and the "HTML for Word" export sizes its
> images to match the styled HTML export.
> **Distribution note:** the release DMG is currently **ad-hoc signed**, so Gatekeeper
> blocks the first launch until you clear quarantine (see [Install](#install)). Developer ID
> signing + notarization is the remaining polish step
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
   instruction, or edit the project title in the header. Insert **section dividers** to mark
   where the procedure shifts to a new phase (they're headings, not numbered steps), plus
   text blocks and note/caution/warning callouts between steps. Open the native image editor to
   draw **boxes**, **arrows**, **numbers**, and **text**, adjust the click **marker**,
   **crop**, or **redact/blur** sensitive regions. Redactions are **baked into a flattened
   PNG** copy of the screenshot; the original pixels never leave your machine for any export
   or AI request (the send/export path is **fail-closed** and refuses a step whose
   redactions aren't baked). Each report step supports liquid-glass image zoom
   with drag-to-pan.

3. **Generate the SOP (optional).** With **your own** Anthropic API key — or, where your
   organization has configured it, a **single sign-on** with your work account and no key at
   all ([docs/SSO-WIF.md](docs/SSO-WIF.md)) — Claude reads the
   redaction-baked screenshots + captions and writes the guide **in place**: an overview,
   per-step headings and instructions, and callouts — in your chosen **tone** and
   **effort**. Before anything is sent you see an **estimated cost**; a single click
   **reverts** to your pre-AI version.

4. **Export & share.** Export to **HTML**, **PDF**, **Markdown**, or **HTML for Word**
   (a minimal-Arial semantic file that pastes cleanly into Word / Google Docs). Each frames
   every step as its own card — the same visual step separation you see in the report.
   Markdown lands as a self-contained **`<name>/` folder** (the `.md` plus its `images/`).
   Or export a shareable **`.zip` package** that another shotAI user (macOS or Windows) can
   **import** and keep editing.

5. **Manage.** The Home screen lists projects with **search**, sort, and **date grouping**,
   a **Draft / SOP-ready** status chip, and **multi-select** for bulk **archive / export /
   delete** (bulk export lets you choose a destination folder and shows progress).
   **Archiving** compresses a project in place to save disk while keeping it under an
   **Archive** tab; opening an archived project restores it automatically, and old projects
   can auto-archive by age.

### Privacy & local-first

Projects — screenshots, `project.json` manifest, and exports — live in a folder on your
Mac (`~/shotAI Projects` by default) and are **never uploaded in the background**. There is
**no telemetry**, ever, and nothing is sent unless you ask for it.

shotAI makes exactly two kinds of outbound request, both narrow and both pinned:

- **SOP generation** — only when *you* click Generate, and only to Anthropic
  (`api.anthropic.com`, **pinned** in the client, no base-URL override). Either your own
  API key, stored in the **macOS Keychain**, or a **short-lived token** obtained by signing
  in with your work account. Both are read only by the Claude client and never surfaced back
  to the UI — the credential type has no accessor, so a secret cannot reach UI code even by
  mistake.
- **Sign-in** (only when single sign-on is configured) — to your organization's identity
  provider, in a real system browser that shotAI cannot read. Only the refresh token is
  stored, in the Keychain; the working tokens live in memory and last minutes.
- **Update check** — once a day, a plain `GET` to `api.github.com` (**pinned**, redirects
  off-host refused) asking whether a newer release exists. It sends nothing but your IP and
  a `shotAI/<version>` User-Agent: no account, no cookies, no project data, no identifier.
  shotAI **never downloads or installs an update itself** — the Download button opens the
  release page in your browser. Turn it off in **Settings → General**, or force it off
  fleet-wide with an MDM configuration profile (`updateCheckDisabled`).

> **After you update:** because this build isn't notarized yet, macOS treats each new version
> as a different app and switches its permissions back off. shotAI notices when that has
> happened and walks you through re-granting them, rather than just failing to record. A
> notarized build will end this — see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Tech stack

- **Swift 6 / SwiftUI**, a single native app process. **Zero third-party dependencies** —
  everything is Apple frameworks.
- Seven in-repo **SwiftPM** packages (UI-free, tested headless):
  - **ShotModel** — the Codable `project.json` schema (byte-compatible with Windows,
    tolerant decode), path-confined atomic writes, and a `ProjectStore` actor.
  - **CaptureKit** — the recording engine: **ScreenCaptureKit** screenshots, **Accessibility**
    element-at-point captions, a **CGEvent** tap for clicks, a **Carbon** ⇧⌘S hotkey, and
    the TCC permission surface.
  - **EditorKit** — the annotation flatten/redaction pipeline (redactions baked into a
    flattened PNG). It also contains a local **Vision** OCR redaction-detection pass that
    is built and tested but **not currently surfaced in the UI**.
  - **SOPKit** — the Anthropic Messages API client (URLSession, pinned host), Keychain key
    store, cost estimator, and prompt assembly.
  - **ExportKit** — the HTML / PDF / Markdown / "HTML for Word" renderers and the `.zip`
    package export/import (PDF is rendered natively via CoreText + CoreGraphics).
  - **EntraKit** — single sign-on: OAuth authorization-code + PKCE against Microsoft Entra
    ID, hand-rolled on Apple frameworks, plus the token exchange and credential resolution.
    UI-free and headless-tested; the browser step sits behind a protocol.
  - **UpdateKit** — the notify-only update checker: a semver comparator, a pinned GitHub
    Releases client, and a persisted once-a-day throttle. It never touches the app bundle.
- The app target lives under [`shotAI/`](shotAI/) (Home, report/editor, capture UI, Settings).

## Requirements

- **macOS 14.0+** (Sonoma) — the floor for ScreenCaptureKit's `SCScreenshotManager`.
- **Apple Silicon**.
- Screen Recording, Accessibility, and Input Monitoring permissions (granted through a
  first-run wizard).
- An Anthropic API key **only** if you want SOP generation — capture, editing, redaction,
  and export all work without one. (Organizations can instead enable **Entra single sign-on**,
  where staff sign in with their work account and no key is ever issued or stored — see
  [docs/SSO-WIF.md](docs/SSO-WIF.md).)

## Install

1. Download the latest `shotAI-<version>.dmg` from
   [GitHub Releases](https://github.com/Armadillon44/shotAI_MacOS/releases) and drag
   **shotAI** into `/Applications`.
2. **Clear the Gatekeeper quarantine.** Because this build is **ad-hoc signed** (Developer ID
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
swift test --package-path Packages/UpdateKit

# Live smoke tests (drive the real frameworks / services)
swift run --package-path Packages/CaptureKit CaptureSelfTest   # needs Screen Recording
swift run --package-path Packages/ExportKit PdfSelfTest        # exercises the PDF renderer
swift run --package-path Packages/UpdateKit UpdateSelfTest     # one live GitHub API call
```

The app target is manually signed with an **Apple Development** cert (team `JX6BU857VX`)
so TCC grants persist across rebuilds; a fresh checkout will need its own dev signing
identity. See [`CLAUDE.md`](CLAUDE.md) for the full command list and signing notes, and
[`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md) + [`Scripts/dist.sh`](Scripts/dist.sh) for
the Developer ID / notarization pipeline.

## Getting access to Claude

SOP generation is off until shotAI can authenticate. There are two ways, and the app
picks whichever is available.

### Single sign-on (organizations)

Where an admin has configured it, **Settings ▸ AI ▸ Account** offers **Sign In**. You sign
in with your work account in a real browser, and shotAI receives a short-lived token that
renews itself. Nothing to obtain, nothing to paste, nothing to pay for personally.

If your sign-in succeeds but you haven't been granted access, shotAI says exactly that
rather than implying your login failed — that case needs IT, not another attempt.

Admins: see [docs/SSO-WIF.md](docs/SSO-WIF.md). It uses Anthropic's Workload Identity
Federation with Microsoft Entra ID, gated on an app role, with no gateway to run.

### Bring your own key

The path for everyone outside such an organization. **Settings ▸ AI ▸ Advanced** takes an
Anthropic API key, stored in the **macOS Keychain**; a read-only `ANTHROPIC_API_KEY`
environment variable is honored as a dev/CI fallback. The UI never reads the key back — it
only sets, clears, and reports status.

It sits under **Advanced** because sign-in is the normal route where it exists, not because
the key path is deprecated. It stays available precisely so it can be used when sign-in
itself is what's broken. If you have both, the signed-in session wins.

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
Packages/EditorKit/           annotation flatten + redaction bake (+ unsurfaced Vision OCR detection)
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
