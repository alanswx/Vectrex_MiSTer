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
