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

No alpha correction has been applied yet. Corrections should happen after a
precise playfield mask and hardware crop check, otherwise we risk blocking
legitimate vectors around irregular borders.
