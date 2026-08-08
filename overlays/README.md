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

## How the core loads overlays

The OSD's "Load Overlay" is the `F2,ART` CONF_STR slot (extensions are
exactly three characters). Auto-load is main's generic addon mechanism:
the lowercase `f1,ART;` entry directly before the cart's F entry makes
main stream `<rom name>.ART` from the ROM's folder after every cartridge
load, including MGL loads. Addon uploads arrive with the addon number in
`ioctl_index[9:8]` (not index 2), so `vfb_overlay`'s `upload_active`
accepts both. Core reset gates on cartridge indexes only, so an overlay
upload never resets the machine. The compositor is a transmissive filter:
vectors multiply by the artwork color where they pass behind it, unlit
artwork shows as ambient reflection ("Overlay Bright" sets the strength,
default 100% = the original core's look).
