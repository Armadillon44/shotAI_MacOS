# shotAI app icon — Liquid Glass layers

Layered source for authoring the macOS 26 Liquid Glass app icon in **Icon Composer**
(ships with Xcode 26). Reconstructed 1:1 from the current flat icon
(`shotAI/Assets.xcassets/AppIcon.appiconset/icon_1024.png`) as clean vectors on a
1024×1024 canvas.

## Files

| File | Role |
| --- | --- |
| `01-background.svg` | **Background layer** — full-bleed purple gradient. **No rounded corners** (the system applies the squircle mask). |
| `02-brackets.svg` | **Midground layer** — the four white capture-frame brackets. Transparent elsewhere. |
| `03-sparkles.svg` | **Foreground layer** — the three sparkles. Transparent elsewhere. Put on top so they catch the strongest specular highlight. |
| `preview-flattened.svg` | Not a layer — all three composited with a rounded mask, for eyeballing against the current icon. |

Stacking order in Icon Composer (bottom → top): **01 → 02 → 03**.

> **Shipped.** The authored Icon Composer document now lives at **`shotAI/shotAI.icon`**
> (inside the app target's synchronized folder) and is the app icon
> (`ASSETCATALOG_COMPILER_APPICON_NAME = shotAI`). The old `AppIcon.appiconset` was
> removed — `shotAI.icon` is the single source of truth and generates the pre-macOS-26
> fallback itself. The SVGs here are the layer sources; edit the icon in Icon Composer by
> opening `shotAI/shotAI.icon`.

## Specs (reference)

- **Canvas:** 1024×1024.
- **Gradient:** linear, top-left `#6646F1` → bottom-right `#885AF6` (brand accent `#6344F1` sits between).
- **Brackets:** `#FFFFFF`, stroke 58, round cap + join. Corners inset ~108px (within the icon safe area).
- **Sparkles:** big center `#FFFFFF` at (444,535); two small `#EBE5FD` at (713,354) and (714,726).

## Using them in Icon Composer

1. `open -a "Icon Composer"` (Xcode 26 → Developer Tools).
2. New icon → import `01`, `02`, `03` as separate layers in that order.
3. Tune per-layer material/specular/shadow so the sparkles float above the brackets above the gradient.
4. Preview across appearances (Default / Dark / Clear / Tinted) and export `shotAI.icon`.
5. Point the app icon at the `.icon` in Xcode 26; keep `AppIcon.appiconset` as the pre-macOS-26 fallback.

## Notes

- **Do not bake in** the rounded-rect, rim highlight, or drop shadows — the system owns those.
- **Lean into glass on the sparkles.** Consider making the big center sparkle translucent/frosted rather than solid white so light reads through it.
- **Busy at small sizes:** three sparkles + four brackets is borderline at 16–32px. Consider dropping the two small sparkles for the layered version, or reducing their prominence.
- **Variants:** author a Dark (darker background, light marks) and check the Tinted/monochrome rendering — the bracket + sparkle silhouette should read in one color.
- **Scope:** this is the macOS app icon only. The Windows `assets/shotAI_icon.ico` (app + `.shotAI` file-association icon) is separate and unaffected. The full effect renders on macOS 26+; 14–25 use the flattened fallback.
