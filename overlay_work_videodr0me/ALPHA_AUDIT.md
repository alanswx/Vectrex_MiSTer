# Alpha and border audit — first pass

## What was checked

Every staged image was opened as RGBA. The audit sampled the outer 8% frame and
measured its alpha distribution. This is a conservative screening test: title
cutouts and irregular artwork make the whole outer ring an imperfect border
mask, so mixed results require visual/hardware review rather than automatic
rejection.

All 34 staged images contain usable alpha after conversion. The 540x720 legacy
sources were decoded according to the documented local RGBA4444 layout.

## Strongest blocking-border candidates

At least 75% of the sampled outer ring is alpha 240–255:

- Frogger (91.4%)
- Gyrostronomy (97.5%)
- Rotor (80.3%)
- Spike (75.5%)
- Spinball (86.8%)
- Star Castle (76.3%)

## Manual border review required

These have less than 55% of the sampled outer ring at alpha 240–255 and should
be checked first on hardware/contact sheets:

- Patriots (46.7%)
- Spike Hoppin' (49.6%)
- Vec Pilot (51.3%)
- Vector Blade (26.2%; alpha never reaches zero in the sampled ring)
- Wormhole (35.7%; alpha never reaches zero in the sampled ring)

The remaining images measure between 54% and 75% opaque in the coarse outer-ring
test. That is compatible with shaped frames but is not proof that every border
pixel blocks vectors.

## Important source decision

Mine Storm uses Overlay Packs `mine.png`. The `raphkoster/minestorm.png` and
`minestorm2.png` files are exact duplicates of each other and are fully opaque;
they are not the preferred source. This implements the specific “mine good,
minestorm bad” guidance.

The alpha threshold correction is now applied by the VART builders. Fine-line opacity remains a separate title-specific review item.


## Alpha policy (2026-08-30)

VART alpha is a control boundary, not a cosmetic color value. Before palette quantization, the builders normalize every alpha value from 254 through 255 to exact 255. After quantization, they explicitly serialize the indexed transparency table and apply the same threshold again, because Pillow exposes that table only when the PNG is written. Values below 254 remain unchanged. Pillow FASTOCTREE otherwise averages opaque and near-opaque pixels into palette alpha 254, making the opaque-brightness diagnostic unreliable.

This rule is applied in both vart/build_vart.py and tools/overlays/build_vart.py. Any regenerated ART files must use one of these builders. Existing files must be rebuilt after changing the rule.

This pass does not automatically lower fine-line alpha: white/red sector lines can legitimately be alpha 255 in source art and require title-specific visual review. Downscaling should avoid dithering and ringing; where thin strokes wash out, use the exact-plane mode or author a dedicated low-resolution PNG.


## Resampling policy (2026-08-30)

Do not use Lanczos, bilinear, or bicubic for these overlays. The default reduction filter is Pillow HAMMING: it is sharper than bilinear and avoids the ringing and overshoot seen with sharper sinc-style filters. It is used without dithering. RGBA alpha is retained, and alpha values at or above 254 are normalized to exact 255 before palette quantization.

The main converter creates the normal planes from one native portrait source and creates TATE planes by rotating first, scaling the native 1080 side to 1360, centering the resulting approximately 1360x1065 image in a transparent 1360x1080 canvas, then reducing that full-raster master. When a thin stroke still does not survive, use the exact-plane mode with a hand-authored or AI-reimaged PNG for that resolution rather than repeatedly resizing it.
