# Deploying shotAI with Microsoft Intune

For an internal La Crosse Footwear rollout. This folder has the two pieces Intune
needs; the signing prerequisites are in [`../docs/DISTRIBUTION.md`](../docs/DISTRIBUTION.md).

| File | What it is | Where it goes in Intune |
|------|------------|-------------------------|
| `shotAI-<version>.pkg` (produced by `Scripts/dist.sh pkg`) | The signed + notarized installer | **Apps** → macOS app |
| `shotAI-PPPC.mobileconfig` | Pre-approves the 3 permissions | **Devices → Configuration** → Custom profile |

> Prerequisite: an Apple Developer Program membership (ideally LFI's **org**
> account) so you have **Developer ID Application** + **Developer ID Installer**
> certs and can notarize. Intune deploys the app but can't sign it.

## 1. Build the installer
```sh
./Scripts/dist.sh pkg          # → build/dist/shotAI-<version>.pkg  (signed, notarized, stapled)
```

## 2. Fill in the Team ID in the PPPC profile
The profile ships with a `__LFI_TEAM_ID__` placeholder. After the signed build,
read the exact code requirement and confirm it matches the profile:
```sh
codesign -d -r - build/dist/shotAI.app
```
Replace `__LFI_TEAM_ID__` in `shotAI-PPPC.mobileconfig` with your Apple Developer
**Team ID** (the `subject.OU` in that requirement).

## 3. In the Intune admin center
1. **Apps → macOS → Add → "macOS app (PKG)"** → upload `shotAI-<version>.pkg`.
   - App/bundle id: `com.armadillon44.shotai`; set the version for detection.
   - Assign to your pilot device/user group.
2. **Devices → Configuration → Create → macOS → Templates → Custom** → upload
   `shotAI-PPPC.mobileconfig`. Assign to the same group.

## 4. What users experience
- The app installs silently to `/Applications`.
- **Accessibility** and **Input Monitoring** are pre-granted — no prompts.
- **Screen Recording**: silent on Macs enrolled via **Apple Business Manager /
  Automated Device Enrollment (supervised)**; on user-enrolled Macs the entry is
  pre-populated but users may get a **one-time** approval prompt. (Confirm your
  enrollment type with whoever manages Intune.)

## 5. Verify on a test Mac
```sh
codesign --verify --deep --strict --verbose=2 "/Applications/shotAI.app"
xcrun stapler validate "/Applications/shotAI.app"
# System Settings ▸ Privacy & Security ▸ Accessibility / Input Monitoring / Screen
# Recording should each already list shotAI as allowed (SR: supervised only).
```
