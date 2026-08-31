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

A whole-plane test also flagged 36 files — 18 titles in both rotations — whose
720x480 and 720x240 planes are uniformly alpha 255. Tracing that back changed
the diagnosis: the pipeline did not flatten anything. The artwork of those 18
titles is a fully opaque scan with no alpha cut at all, and the pipeline
carried it through faithfully. Their portrait planes only looked correct
because the full raster keeps a transparent margin either side of the 810x1080
artwork frame; crop to the frame and every one of them is solid 255. The
overlay blocks the play area in every orientation. The rotated 480p and 240p
planes are simply where the artwork fills the whole raster, so a whole-plane
test could finally see it.

Affected: Armor Attack, Clean Sweep, Cosmic Chasm, Frogs'n'Fly, Hyper Chase,
Karl Quappe, Mine Storm, Mine Storm 2, Solar Quest, Space War, Space Wars,
Star Castle, Stunt Man Stories 2, Thrust, Vecman 1 and 2, Vector Patrol and
Web Wars. Fifteen have a transmissive copy of the same title elsewhere in the
tree — this is the `mine` good, `minestorm` bad split `ALPHA_AUDIT.md` already
recorded, and it turns out to run through eighteen titles rather than one.
Frogs'n'Fly and Karl Quappe have no transmissive source anywhere.

Step 2 still comes before artwork repair, because the resampling damage is
real and it is ours: 43% of shipping planes clean against 90% of sources.

## Decision

Fix the artwork, keep the core linear. The contract is:

- 255 means blocker. Exact, no tolerance.
- 0 means clear.
- 1 to 254 means genuine tint, allowed only for authored gels and for
  antialias rims within two pixels of a 255 or 0 region.

No threshold is needed in the core. The artwork is correct: every source is
clean and all 489 packages encode with no violation, so the classification the
opaque-brightness option keys off is already unambiguous at the only value
that matters. A core-side `alpha >= 250 -> 255` net would be harmless but is
redundant, and 127 was never in that category.

## Status, 2026-08-30

Steps 1, 2, 3 and 5 are done; the pack has been rebuilt and the sources
repaired.

    sources    before  118/123 solid at 255, 12 defects, 13 minor
               after   122/124 clean, plus Berzerk and Narzod, which have
                       one alpha value and no transparency at all

    planes     before  841 clean, 421 minor, 622 defect, 72 with no alpha
               after   1948 clean, 8 with no alpha -- the 480p and 240p
                       rotated planes of Frogs'n'Fly and Karl Quappe, the
                       two titles with no transmissive source anywhere

What changed, in `vart/rgba_ops.py` and its callers:

- Resampling is premultiplied and in linear light. Straight-alpha resampling
  in sRGB mixed colour across every alpha edge as though the transparent side
  had one.
- Each plane is reduced once, from the source. The rotated 240p plane used to
  be downscaled to 405x240 and then stretched back up to 720x240.
- `quantize_rgba` snaps solid bodies before quantizing and then re-checks the
  quantized result, lifting the palette entries responsible. Checking the
  output is the only way to know the boundary survived FASTOCTREE.
- `vart/repair_sources.py` applied the same rule to the sources: 94 images,
  700,341 pixels. Vector Blade was 18% of its own image and is visually
  identical afterwards.
- `tools/overlays/build_vart.py` emits the superseded portrait-only geometry
  but defaulted its output to `artwork/generated`. It now shares the snap rule
  and writes to `artwork/legacy_portrait` instead.

`vart/proofsheet.py` renders the review sheets, running the compositor's
integer pipeline op for op so the beam columns show what the FPGA shows.
Sheets and an HTML index are in `test_results/proofsheets/`.

One point of language, because it changes what the contract means. Alpha here
is filter strength, not opacity: at 255 the beam still arrives, tinted to the
artwork's own colour, so a pale region at 255 passes light and only a dark one
blocks. That is why raising Pipe Race's 214 body to 255 across 85% of its
plane is safe -- its artwork is pale, and the beam still gets through.

## Plan

1. Census. Done. `vart/alpha_census.py`, evidence in
   `test_results/alpha_census/`. Rerun it after every pipeline or artwork
   change; it is the gate for the rest.

2. Fix the pipeline before touching artwork. Done. Premultiplied linear-light
   resampling, one reduction per plane, and a snap that is verified on the
   quantized output rather than assumed from the input. A separate coverage
   downsample of the blocker mask turned out to be unnecessary: premultiplied
   resampling plus the body snap already holds the boundary.

3. Enforce the contract in the builder. Done, by correction rather than by
   refusal: the builder raises an offending body to 255 and reports how many
   pixels it had to move, so a regression shows up in the build log and in the
   census rather than blocking a rebuild.

4. Emit opaque maps for the TATE crop. Per title and plane, a three-class map
   (clear, translucent, blocker) plus JSON with the blocker bounding box and
   the largest clear rect, in both orientations, so the 90CW and 90CCW crop is
   computed rather than probed. Ten of the 90 legacy images never reach alpha
   0, so the crop cannot be found by looking for a transparent hole.

5. Hand-repair what survives. Done for alpha; `repair_sources.py` covered all
   94 affected images. What is left is not an alpha problem, and not ours to
   decide -- see the opaque-by-design titles below.

6. Gate it. Add the contract check to the sweep, plus a two-point visual test
   at 100% and 30% ambient over a bright vector field, where a leak is obvious.

## The plane geometry does not match the core

Found while checking whether the rotated framing is stretched. It is not, but
the plane sizes are wrong for this core.

`rtl/videodr0me_fb/vfb_overlay.sv` accepts exactly eight plane sizes
(`valid_dimensions`, lines 112-119):

    portrait   810x1080   540x720   360x480   180x240
    rotated    1080x810   720x540   480x360   240x180

`artwork/generated/` ships 1360x1080, 916x720, 720x480 and 720x240. None of
those is on the list. `valid_dimensions` gates `metadata_valid` and then
`package_valid` (line 656), and `active_plane_ready` requires `package_valid`
(line 792), so an unlisted size does not degrade -- no overlay is drawn at all.

This is the failure `rtl/videodr0me_fb/PROVENANCE.md` records being fixed on
2026-08-06, when the whitelist was changed from the Asteroids cabinet rasters
to the Vectrex ones. The `vart/` converter added on 2026-08-29 reintroduced
Asteroids-shaped full-raster planes; `vart/README.md` documents them as
intended and `vart_encoder.py` validated only that set, so the two halves of
the tree have disagreed since.

`TATE_STATUS.md` already named this as unfinished: the requested approximately
1360x1080 artwork real estate against the core's actual 1080x810 rotated
plane. The pack is built for the first and the core implements the second.
That is a decision for videodr0me, not something to pick a side on quietly, so
both now exist:

- `artwork/generated/` keeps the full-raster geometry the converter targets.
- `artwork/generated_native/` is the same artwork at the sizes the core
  whitelists, built with `rebuild_pack.py --geometry native`.

`vart_encoder.validate_plane_set` accepts either set instead of only the
full-raster one.

The aspect worry that started this dissolves: at the whitelisted sizes every
portrait plane is exactly 3:4 and every rotated plane exactly 4:3, with no
margins and no stretch. The 3:1 look of the rotated 240p plane is the
full-raster framing, not a framing-policy error.

## Five titles are opaque because that is how they were drawn

Sly DC's overlay set (archive.org/details/vect-overlays) is the
`slydc_homebrew` pack `tools/overlays/merge_sources.py` refers to and that is
not in this tree. Its own descriptions label five of the files "no
transparency":

    Frogsnfly01       no transparency
    Karl_Quappe01     no transparency
    Vecman01          Pac-Man style, plain center, no transparency
    Vecman02          Pac-Man style, with blue & red power pellets, no transparency
    Vector_Patrol01   Moon Patrol style, no transparency

These are original designs drawn without an alpha cut, not damaged scans, so
there is no better version of them to find. That splits the eighteen opaque
titles cleanly. Thirteen were scans of a real overlay, and re-sourcing the
transmissive copy of the same design restores the artwork the author drew.
Three -- Vecman01, Vecman02 and Vector_Patrol01 -- were Sly DC designs, and
substituting another artist's overlay for the same game silently replaced
them. `rebuild_pack.py` now carries a `KEEP_OWN_ARTWORK` set covering all five
and reports them rather than substituting.

What to do with those five is a decision, not a defect: leave them blocking,
cut alpha into someone else's artwork, commission new art, or drop them. The
originals are on archive.org at higher resolution than our copies if the
answer is to keep them and cut alpha.

Berzerk and Narzod are not in this group. An earlier note here called them
unusable; that was about two redundant source files, not the titles.
`overlays/Berzerk_Small.png` and `overlays/Narzod_Small.png` are fully opaque
and superseded -- `Fortress_of_Narzod_Small.png` already replaces the latter --
while `canonical/Berzerk.png` and `canonical/Fortress of Narzod.png` are 70.5%
and 78.6% transmissive, and the shipping packages built from them measure
70.4% and 78.7% across the artwork frame. Both titles are fine.

## Opaque maps for the crop

`vart/opaque_maps.py` answers videodr0me's third point with data rather than
probing. Per package and plane it writes a three-class PNG and, in JSON:

    artwork_box   tight bounds of everything not fully clear
    filter_box    tight bounds of alpha 255
    clear_box     largest inscribed all-clear rectangle -- the play area on
                  artwork that cuts one. Not the bounding box: a frame with
                  clear notches would otherwise report a box covering them
    open_box      tight bounds of everything below the solid floor, which is
                  the play area on gel artwork that never reaches alpha 0

Each box is given in plane pixels and normalized to 0..1, so a crop carries
between plane sizes and between orientations. `clear_box` runs on a min-pooled
mask: conservative, never larger than the true rectangle and never covering a
non-clear pixel.

## Resampling to 240p

Generative models are not a pipeline stage here. They shift geometry by pixels
and have no concept of alpha as a control boundary; misregistering the frame
against the vector raster is worse than a soft stroke. The wins available are
premultiplied linear-light resampling (step 2), explicit thin-stroke
preservation that re-asserts a one-pixel minimum after reduction, and vision
review of the contact sheets to triage which titles need a hand-authored
180x240 plane. Exact-plane mode already exists for that last case.
