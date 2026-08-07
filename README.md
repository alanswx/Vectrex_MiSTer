# [Vectrex](https://en.wikipedia.org/wiki/Vectrex) for [MiSTer Platform](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

Port of Vectrex by Dar (darfpga@aol.fr) http://darfpga.blogspot.fr

Supports both digital and analog joystick/gamepad

### Installation
Copy the *.rbf file to `_Console/` on the SD card. Copy *.vec/*.bin files to
`games/VECTREX/`.

### Overlays
Overlays are `.art` files (VART containers holding the artwork at several
resolutions). Ready-made overlays for 163 titles are in `artwork/generated/`;
copy them to `games/VECTREX/`.

An overlay loads two ways:

* **Automatically**: name it after the ROM (`Pole Position (1983)(GCE).art`
  next to `Pole Position (1983)(GCE).bin`) and it loads with the cartridge,
  as .ovr files did before. `tools/overlays/name_for_roms.py` generates
  these copies for a ROM library.
* **Manually**: the OSD's "Load Overlay" entry.

The overlay composites as the physical plastic did: the artwork acts as a
colored filter in front of the tube, so vectors take the overlay's color
where they pass behind it, and the unlit artwork shows as ambient
reflection. "Overlay Bright" in the OSD sets the ambient strength, and
"Overlay" turns compositing off.

To build an overlay from a PNG (portrait, with alpha), use
`tools/overlays/build_vart.py image.png`; `tools/overlays/merge_sources.py`
rebuilds the whole generated set from the source packs.

### Credits

Original Vectrex core by Dar (darfpga@aol.fr), http://darfpga.blogspot.fr
MiSTer port and rasteriser enhancements by Sorgelig.

The vector rendering rebuild follows the approach Videodr0me established in his
Atari vector cores — Major Havoc, Asteroids, Tempest, Star Wars and Battlezone —
whose `videodr0me_fb` framebuffer, phosphor model and CRT effects pipeline are
the reference this work is built against. If you enjoy these cores, please
consider supporting him:

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?style=flat-square&logo=buy-me-a-coffee)](https://buymeacoffee.com/Videodr0me)