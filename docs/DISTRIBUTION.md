# Phase E — Distributing shotAI (Developer ID + notarization)

Goal: hand someone a `shotAI.dmg` that opens cleanly on any Mac — no
"unidentified developer" wall, works offline. This needs a **Developer ID**
signature + **Apple notarization**. The whole flow is automated in
[`Scripts/dist.sh`](../Scripts/dist.sh); the steps below are the **one-time human
setup** it depends on.

> The current local **Apple Development** cert is for running on your own machine
> only. It **cannot** sign for distribution — that's what Developer ID is for.

---

## One-time setup (you)

### 1. Join the Apple Developer Program — $99/year
<https://developer.apple.com/programs/enroll/>. Uses your Apple ID
(dylan.dreier@icloud.com). Approval takes a few hours to ~a day.

- **Individual** — fast; the app is attributed to you personally.
- **Organization (LFI)** — attributes it to Lacrosse Footwear; requires a
  D‑U‑N‑S number and authority to enroll the company. Slower, but the right
  choice if this ships under LFI. Decide before enrolling — switching later is
  painful.

**Check whether you're already enrolled:** sign in at
<https://developer.apple.com/account>. A paid membership shows a *Membership*
section (expiration + Team ID `JX6BU857VX`) and *Certificates, Identifiers &
Profiles*. A free account shows an **Enroll** button instead.

### 2. Create a "Developer ID Application" certificate
Easiest in Xcode: **Settings ▸ Accounts ▸ (your Apple ID) ▸ Manage
Certificates… ▸ + ▸ Developer ID Application**. It installs into your login
keychain. Verify:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 3. Store a notarization credential (once)
Notarization uploads the app to Apple's automated malware scan. Authenticate with
an **app-specific password**:

1. Create one at <https://appleid.apple.com> ▸ **Sign-In & Security ▸
   App-Specific Passwords**.
2. Store it in your keychain under a profile name the script uses. **You** run
   this — the password goes straight into the keychain; the script never sees it:

   ```sh
   xcrun notarytool store-credentials shotai-notary \
     --apple-id "dylan.dreier@icloud.com" \
     --team-id JX6BU857VX \
     --password "<the app-specific password>"
   ```

   (Alternative: an App Store Connect API key `.p8` via
   `--key/--key-id/--issuer`. The app-specific password is simplest to start.)

---

## Ship a build

From the repo root:

```sh
./Scripts/dist.sh
```

It builds Release, signs with your Developer ID cert + hardened runtime, notarizes
and staples the app **and** the DMG, verifies Gatekeeper, and leaves the result at:

```
build/dist/shotAI-<version>.dmg
```

First notarization of a new app can take a few minutes; later ones are usually
1–2 min. `notarytool ... --wait` blocks until Apple responds.

---

## Why the app is signed the way it is

- **Not sandboxed.** shotAI needs a CGEventTap, Accessibility, and a Carbon
  hotkey — all forbidden in the App Sandbox. Sandbox is only required for the Mac
  App Store, which this app can't target regardless. Developer ID distribution is
  unsandboxed and fully supported.
- **Hardened runtime, empty entitlements.** Notarization requires the hardened
  runtime. Screen Recording, Accessibility, and Input Monitoring are gated by
  **TCC at runtime**, not by entitlements — so
  [`Signing/Distribution.entitlements`](../Signing/Distribution.entitlements) is
  intentionally empty (and must never include `get-task-allow`, which
  notarization rejects).
- **Zero third-party dependencies**, so there's no embedded framework/dylib to
  sign — the signature covers a single app bundle.

## TCC permissions after distribution
A Developer-ID signature gives a **stable designated requirement** (bundle id +
team), so a user grants Screen Recording / Accessibility / Input Monitoring once
and the grants survive updates (same property that keeps them stable across local
rebuilds). The first-run permissions wizard still guides them.

## Internal rollout (LFI / MDM) — usually better than a personal purchase

For deploying to La Crosse Footwear machines, prefer the company's infrastructure
over a personal $99 membership:

1. **Sign under LFI's Apple Developer *organization* account, not a personal one.**
   Get added to the org team, create the **Developer ID Application** cert there,
   and set `TEAM_ID` in [`Scripts/dist.sh`](../Scripts/dist.sh) to the org team.
   The app becomes a company asset; no personal cost.

2. **Deploy + pre-approve permissions via MDM (Jamf / Intune / Kandji / …).**
   An MDM can push the app *and* ship a **PPPC** (Privacy Preferences Policy
   Control) configuration profile that pre-grants shotAI's TCC permissions, so end
   users never see the permission wizard. The three services shotAI needs:

   | Permission        | TCC service key            | PPPC pre-approval |
   |-------------------|----------------------------|-------------------|
   | Accessibility     | `kTCCServiceAccessibility` | Yes (Allow)       |
   | Input Monitoring  | `kTCCServiceListenEvent`   | Yes (Allow)       |
   | Screen Recording  | `kTCCServiceScreenCapture` | Depends on macOS/MDM version — may still need a one-time user OK |

   PPPC keys the approval to the app's **code requirement**. After signing, read
   the exact requirement with:

   ```sh
   codesign -d -r - "build/dist/shotAI.app"
   ```

   For a Developer-ID-signed build it looks like:

   ```
   identifier "com.armadillon44.shotai" and anchor apple generic and
   certificate leaf[subject.OU] = <LFI_TEAM_ID>
   ```

   Notarization is **optional** for MDM-installed apps (an MDM install isn't
   quarantined), but a stable Developer ID signature is still required for PPPC.

   For MDM you'll want a signed **`.pkg`** rather than a DMG. That's built in:
   `./Scripts/dist.sh pkg` produces a signed + notarized `.pkg`, and
   [`Intune/shotAI-PPPC.mobileconfig`](../Intune/shotAI-PPPC.mobileconfig) is a
   ready PPPC profile pre-filled with the bundle id + the three services (just add
   your Team ID). Full Intune steps: [`Intune/README.md`](../Intune/README.md).

**Ask your Mac admin:** (1) Do we have an Apple Developer Program *organization*
membership I can be added to? (2) What MDM manages our Macs, and can we ship an
internal signed app + a PPPC profile pre-approving the three permissions above?

## Verifying by hand
```sh
spctl -a -t open --context context:primary-signature -vv build/dist/shotAI-*.dmg   # DMG accepted
spctl -a -vvv "/Applications/shotAI.app"                                           # app accepted: "source=Notarized Developer ID"
xcrun stapler validate "/Applications/shotAI.app"                                  # ticket stapled
codesign --verify --deep --strict --verbose=2 "/Applications/shotAI.app"
```

## Gotchas
- **`get-task-allow` / debug builds can't be notarized** — always ship the
  **Release** build (the script forces it).
- **Timestamp required** — signing uses `--timestamp` (needs network at sign
  time); notarization rejects ad-hoc/un-timestamped signatures.
- **Renew:** the Developer ID cert is valid ~5 years; the Program membership is
  annual. If the membership lapses, the cert still validates already-notarized
  builds, but you can't notarize new ones until renewed.
