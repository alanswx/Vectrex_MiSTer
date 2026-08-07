# videodr0me_fb

Tile-based sparse vector framebuffer and CRT effect pipeline, written 2026 by
Videodr0me. Licensed GPL v2, matching this repository.

Vendored unmodified from
[Arcade-Asteroids_MiSTer](https://github.com/MiSTer-devel/Arcade-Asteroids_MiSTer)
at commit `ab07109` (2026-08-05, "add Asteroids Deluxe artwork, expanded
controls, and refined CRT presentation"). This supersedes the earlier vendoring
from Major Havoc `6933b85` (2026-07-31): the Asteroids drop added
`vfb_overlay.sv` (the VART artwork loader and compositor this core's overlay
feature is built on), `vfb_async_fifo.sv`, and interface changes across
`vfb_top` (split clocks and resets, artwork and ioctl plumbing, and a
position-change dedup on the vector input that replaces `source_tick`).

The same pipeline also ships in his Asteroids, Tempest, Star Wars and
Battlezone cores.

## Keeping this in sync

These files are a vendored copy, not a fork. Local changes belong in the
wiring around them (`Vectrex.sv`, the geometry and beam mapping) rather than
here, so that picking up his later releases stays a copy rather than a merge.

If a change to these files turns out to be unavoidable, note it here.

## Local changes

- `vfb_overlay.sv`: `valid_dimensions` and `expected_pixels` whitelist the
  artwork plane sizes, and shipped with the Asteroids cabinet's rasters
  hardcoded (1360x1080, 916x720, 640x480, 640x240). Replaced with the
  Vectrex renderer's rasters in both orientations (810x1080, 540x720,
  360x480, 180x240 and their rotations). Found by simulating the upload:
  a valid container validated fully but package_valid never rose because
  every plane failed the dimension whitelist (2026-08-06).
- `vfb_overlay.sv`: upload writes are dropped once past `VFB_ARTWORK_LAST`.
  The Asteroids flow only ever streams an MRA part that fits the window;
  this core's F2 slot streams whatever file the user picked, and an
  oversized file must fail validation rather than write past the window
  over the rest of the DDR map.
- `vfb_overlay.sv`: the compositing stage is rewritten from a screen blend
  to a transmissive filter model. The screen blend is correct for Asteroids
  Deluxe, whose artwork is a backlit backdrop behind the CRT (light only
  adds; a white vector stays white over any art). A Vectrex overlay is
  colored plastic in front of the tube: the beam is multiplied by the
  filter's transmission color (white where alpha is zero, the art color
  where opaque), plus a faint ambient-reflection term, which is the
  original core's alphablend behavior. The blend selector now sets the
  ambient strength (2026-08-06), and the `blend_weight` table is a straight
  brightness ladder (100% down to 30% in the OSD's menu order) instead of
  upstream's signed offsets around a profile default; 100% (64/64) is the
  default and reproduces the original core's full-strength alphablend.
