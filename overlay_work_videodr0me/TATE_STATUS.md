# TATE generation status

The current core loader already whitelists both portrait and rotated renderer
planes:

- portrait: 810x1080, 540x720, 360x480, 180x240
- rotated: 1080x810, 720x540, 480x360, 240x180

The current `tools/overlays/build_vart.py` generator emits only the four
portrait planes. Therefore the present generator does **not** produce usable
90CW/90CCW artwork variants by itself.

No code was changed during this cleanup pass. Before final TATE production we
need to settle two separate coordinate spaces:

1. The requested approximately 1360x1080 artwork real estate (Videodr0me's
   suggested slightly-narrower-than-1376 canvas).
2. The core's actual rotated artwork plane, currently 1080x810.

The final pack still needs one normal file and two rotation-specific files
(`90CW` and `90CCW`) per canonical title. Rotation must preserve text/readable
orientation and cannot be treated as two identical byte-for-byte files.
