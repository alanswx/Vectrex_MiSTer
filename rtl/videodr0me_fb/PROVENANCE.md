# videodr0me_fb

Tile-based sparse vector framebuffer and CRT effect pipeline, written 2026 by
Videodr0me. Licensed GPL v2, matching this repository.

Vendored unmodified from
[Arcade-MajorHavoc_MiSTer](https://github.com/MiSTer-devel/Arcade-MajorHavoc_MiSTer)
at commit `6933b85` (2026-07-31, initial release).

Major Havoc rather than Asteroids because it is the newest of his vector cores
and the framebuffer had moved on considerably in the week between them: 4295
changed lines across every file, plus `vfb_layout_pkg.sv` which did not exist
before. Starting from Asteroids would have meant porting against a version
already stale.

The same pipeline also ships in his Asteroids, Tempest, Star Wars and
Battlezone cores.

## Keeping this in sync

These files are a vendored copy, not a fork. Local changes belong in the
wiring around them (`Vectrex.sv`, the geometry and beam mapping) rather than
here, so that picking up his later releases stays a copy rather than a merge.

If a change to these files turns out to be unavoidable, note it here.
