# [Vectrex](https://en.wikipedia.org/wiki/Vectrex) for [MiSTer Platform](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

Port of Vectrex by Dar (darfpga@aol.fr) http://darfpga.blogspot.fr

Supports both digital and analog joystick/gamepad

### Installation:
Copy the *.rbf file at the root of the SD card. Copy *.vec/*.bin files to Vectrex folder.

### Overlays
Overlay support is temporarily removed while the vector rendering engine is
rebuilt. The artwork in `overlays/` is retained and overlays will return once
the new renderer lands.

### Credits

Original Vectrex core by Dar (darfpga@aol.fr), http://darfpga.blogspot.fr
MiSTer port and rasteriser enhancements by Sorgelig.

The vector rendering rebuild follows the approach Videodr0me established in his
Atari vector cores — Major Havoc, Asteroids, Tempest, Star Wars and Battlezone —
whose `videodr0me_fb` framebuffer, phosphor model and CRT effects pipeline are
the reference this work is built against. If you enjoy these cores, please
consider supporting him:

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?style=flat-square&logo=buy-me-a-coffee)](https://buymeacoffee.com/Videodr0me)