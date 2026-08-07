# Overlay source images

The 540x720 RGBA PNGs in this directory are the original overlay set from
the era when the core loaded raw `.ovr` files. They are kept as one of the
source packs for the current pipeline: `tools/overlays/merge_sources.py`
scans them alongside the higher-resolution packs in `refs/overlay_sources/`
and, per title, encodes the best source into a `.art` VART container in
`artwork/generated/`. Use a `_Small.png` from here only when no better
source exists.

To encode a single image: `tools/overlays/build_vart.py image.png` (portrait
PNG with an alpha channel; alpha is what makes the overlay act as a filter
rather than a backdrop).

`convert_image_alpha.py`, `makeswitch.py` and `shell_convert_alpha.sh` are
the legacy `.ovr` tooling (raw 4-bit RGBA, two pixels per byte). The core no
longer reads that format; they remain only as a record of how the old files
were made.

## Overlay sources

* https://github.com/libretro/overlay-borders (MIT license)
* https://github.com/thebezelproject/bezelproject-GCEVectrex/tree/master/retroarch/overlay/GameBezels/GCEVectrex
* https://github.com/raphkoster/vectrex-overlays
