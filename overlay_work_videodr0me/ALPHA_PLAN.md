# Alpha contract plan

Updated 2026-08-30. Supersedes the alpha policy notes in `ALPHA_AUDIT.md`,
which measured an outer-ring sample rather than the artwork's own geometry.

## The question

The opaque-brightness option has to decide, per pixel, whether the artwork
blocks the beam or filters it. Videodr0me asked whether the pack already
follows a de facto opacity standard, and whether a threshold of `alpha > 127`
could stand in for one. `vart/alpha_census.py` answers both from the artwork
itself; results are in `test_results/alpha_census/`.

## What the compositor does today

`rtl/videodr0me_fb/vfb_overlay.sv` is linear in alpha, with no threshold
anywhere:

    transmission = 255 - (255 - art_colour) * alpha / 256
    out          = art_colour * (alpha * blend_weight / 64)   ambient
                 + vector * transmission / 255                beam

For a black blocker that gives a beam leak of 0.4% at alpha 255, 1.2% at 253,
7.1% at 238, 15.3% at 217 and 50.2% at 128. A near-opaque region therefore
already leaks in the current build; it is mild enough that nobody noticed. Add
a feature that classifies the same pixels binarily and the identical defect
turns into hard-edged patches, which is what "looks horrible" is.

## Census results

124 source images: 90 in `overlays/`, 34 in `canonical/`, plus the 1956
planes inside `artwork/generated/`. Each band is measured
twice, once over all pixels and once over the *body* — what survives a
two-pixel erosion — so antialias rims are separated from mis-authored areas.

The standard exists, and it is 255. Of the 123 images that have any solid area
at all, 118 place it at exactly alpha 255. The five exceptions are Vector Blade
at 238, Lost Souls and Doodle Jump at 217, Pipe Race at 214 and Curling at 210
— individual authoring or decode accidents, not a rival convention. Vector
Blade's 238 is `0xE` from its 540x720 RGBA4444 decode, the source already
listed first in `LOW_RESOLUTION.md`. Laser Wars has no solid area at all.

Twelve images carry a near-opaque body of 0.1% of the plane or more, worst
first: Pipe Race (85.2% at alpha 214), Lost Souls (27.0% at 217), Doodle Jump
(11.8% at 217), Vector Blade (15.2% at 238), Floor Is Lava (9.6% at 254),
Curling (8.8% at 210), Treasure Diver (4.4% at 242), All Good Things (0.8% at
252), Rip Off (0.4% at 249), Brick Crushers (0.3% at 233), Star War (0.1% at
253) and Patriots (0.1% at 253). Thirteen more are under 0.1% and are single
stray pixels. Berzerk and Narzod have one alpha value, 255, and block the
whole screen.

A threshold cannot work. 100 of the 124 images carry a genuinely translucent
body larger than 0.5% of the plane, and those bodies are the playfield: 60% to
90% of the plane, at modal alpha 50 or 51 for most of the pack and at 127, 128,
136 or 153 for the rest. `alpha > 127` would promote Rotor (128), Bubble
Splitter (136), Vector Blade (153), Shark Attack, Asteroid Cowboy, Hover Race,
Kingdom Of Heaven, Portal Fight, Space Assault, Pac Men and Eating Fish (all
128) to solid blockers over most of their screen, while Space Ball, Knight
Rider, Pyoro Chan and Thirsty Astronaut survive at 127 by one alpha step. The
line falls in the middle of the pack's most common gel levels, so no cut point
separates intent from tint.

## What the shipping encode does to it

The same census over the 1956 planes inside `artwork/generated/` finds a much
worse picture than the sources, which locates the fault in our own pipeline
rather than in the community's artwork. 90% of source images are clean; only
43% of shipping planes are. The clean rate falls with every reduction, and the
rotated path is worse than the portrait path at every size:

    plane        n   clean  minor  defect  opaque-only   mean unsafe body
    1360x1080  489   290     95     104        0              0.70%
      916x720  489   288     96     105        0              0.65%
      720x480  489   162    130     161       36              1.06%
      720x240  489   101    100     252       36              1.67%

    normal     489   355    145     152        0
    90CW       652   243    138     235       36
    90CCW      652   243    138     235       36

Worse, 36 files — 18 titles in both rotations — ship a 720x480 and a 720x240
plane whose alpha is uniformly 255. Verified directly on
`starcastle_90CW.art`: the artwork is present, 255 distinct colours, but the
alpha channel has been flattened, so in TATE at those two resolutions the
overlay covers the whole screen and only the 0.4% blocker leak gets through.
The portrait planes of the same titles are correct. Affected: Armor Attack,
Clean Sweep, Cosmic Chasm, Frogs'n'Fly, Hyper Chase, Karl Quappe, Mine Storm,
Mine Storm 2, Solar Quest, Space War, Space Wars, Star Castle, Stunt Man
Stories 2, Thrust, Vecman 1 and 2, Vector Patrol and Web Wars.

This is why step 2 comes before any artwork repair: most of what the pack looks
guilty of, we did to it on the way out.

## Decision

Fix the artwork, keep the core linear. The contract is:

- 255 means blocker. Exact, no tolerance.
- 0 means clear.
- 1 to 254 means genuine tint, allowed only for authored gels and for
  antialias rims within two pixels of a 255 or 0 region.

If a core-side safety net is still wanted, `alpha >= 250 -> 255` is harmless:
at 250 the filter already passes under 2%, so snapping costs nothing visible
and touches only pixels that were meant to be solid. 127 is not in that
category.

## Plan

1. Census. Done. `vart/alpha_census.py`, evidence in
   `test_results/alpha_census/`. Rerun it after every pipeline or artwork
   change; it is the gate for the rest.

2. Fix the pipeline before touching artwork. First find where the rotated
   480p and 240p path flattens alpha to 255 for those 18 titles; that is a
   plain bug, not a tuning question. Then resample premultiplied and in linear
   light rather than on straight alpha in sRGB, and downsample the blocker mask
   separately with area coverage so a hard boundary stays hard. Generalize the
   254 snap in `vart/build_vart.py` to snap the body of a large near-opaque
   region while leaving rims alone. Re-encode, then re-census; the shipping
   clean rate should approach the sources' 90%.

3. Enforce the contract in the builder. Any eroded body of 200 to 254 fails
   the build unless the title is on an explicit exception list.

4. Emit opaque maps for the TATE crop. Per title and plane, a three-class map
   (clear, translucent, blocker) plus JSON with the blocker bounding box and
   the largest clear rect, in both orientations, so the 90CW and 90CCW crop is
   computed rather than probed. Ten of the 90 legacy images never reach alpha
   0, so the crop cannot be found by looking for a transparent hole.

5. Hand-repair what survives. Expect the twelve above, not the canonical forty.

6. Gate it. Add the contract check to the sweep, plus a two-point visual test
   at 100% and 30% ambient over a bright vector field, where a leak is obvious.

## Resampling to 240p

Generative models are not a pipeline stage here. They shift geometry by pixels
and have no concept of alpha as a control boundary; misregistering the frame
against the vector raster is worse than a soft stroke. The wins available are
premultiplied linear-light resampling (step 2), explicit thin-stroke
preservation that re-asserts a one-pixel minimum after reduction, and vision
review of the contact sheets to triage which titles need a hand-authored
180x240 plane. Exact-plane mode already exists for that last case.
