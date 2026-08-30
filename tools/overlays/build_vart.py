#!/usr/bin/env python3
"""Convert Vectrex overlay PNGs into VART containers for the F2 menu slot.

The renderer's rasters are portrait: 810x1080, 540x720, 360x480 and 180x240,
one per output mode, and vfb_overlay picks the plane matching the active
resolution. The overlays in overlays/ are single 540x720 RGBA images, so each
one is resampled to all four sizes, quantized to an indexed palette with
alpha preserved (a Vectrex overlay is a translucent filter, so alpha is the
whole point), and packed with the vendored VART encoder.

The output extension is .art because MiSTer CONF_STR extensions are three
characters; the container inside is VART regardless. Legacy .ovr overlays are
a different format and deliberately do not share the extension.

Usage:
    build_vart.py overlays/'Mine Storm_Small.png' [more.png ...] [-o outdir]
    build_vart.py --all                # every PNG in overlays/

Unlike the Asteroids flow there is no MRA: the .vart file is loaded from the
OSD (F2), which feeds ioctl index 2 exactly as an embedded MRA part would.
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

from PIL import Image

import vart_encoder as vart

# One plane per renderer raster; see vectrex_video.sv's mode table.
PLANE_SIZES = [(810, 1080), (540, 720), (360, 480), (180, 240)]
MAX_COLORS = 255


def quantize_rgba(image: Image.Image, colors: int = MAX_COLORS) -> Image.Image:
    """Quantize RGBA while keeping the opaque control boundary exact."""
    image = image.convert("RGBA")
    alpha = image.getchannel("A").point(lambda value: 255 if value >= 254 else value)
    image.putalpha(alpha)
    quantized = image.quantize(colors=colors, method=Image.Quantize.FASTOCTREE)
    mapped = quantized.convert("RGBA")
    table = bytearray([255] * 256)
    seen = set()
    for index, pixel in zip(quantized.tobytes(), mapped.getdata()):
        if index not in seen:
            table[index] = 255 if pixel[3] >= 254 else pixel[3]
            seen.add(index)
    quantized.info["transparency"] = bytes(table)
    return quantized


def encode_overlay(source: Path, workdir: Path) -> bytes:
    with Image.open(source) as im:
        im = im.convert("RGBA")
        planes = []
        for width, height in PLANE_SIZES:
            resampled = (
                im if im.size == (width, height)
                else im.resize((width, height), Image.Resampling.HAMMING)
            )
            indexed = quantize_rgba(resampled)
            plane_png = workdir / f"plane_{width}x{height}.png"
            indexed.save(plane_png)
            planes.append(vart.encode_plane(vart.ROLE_BACKGROUND, plane_png))

    planes.sort(key=lambda p: (int(p["role"]), -int(p["height"]), -int(p["width"])))
    container = vart.build_container(planes)
    vart.verify_container(container, planes)
    return container


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", nargs="*", type=Path, help="overlay PNGs")
    parser.add_argument("--all", action="store_true",
                        help="convert every PNG in overlays/")
    parser.add_argument("-o", "--outdir", type=Path,
                        default=Path("artwork/generated"))
    args = parser.parse_args()

    repo = Path(__file__).resolve().parents[2]
    sources = list(args.images)
    if args.all:
        sources += sorted((repo / "overlays").glob("*.png"))
    if not sources:
        parser.error("no input images (pass PNGs or --all)")

    outdir = args.outdir if args.outdir.is_absolute() else repo / args.outdir
    outdir.mkdir(parents=True, exist_ok=True)

    failures = 0
    for source in sources:
        name = source.stem.removesuffix("_Small").replace(" ", "_")
        target = outdir / f"{name}.art"
        try:
            with tempfile.TemporaryDirectory() as tmp:
                container = encode_overlay(source, Path(tmp))
            target.write_bytes(container)
            print(f"{source.name}: {len(container)} bytes -> {target}")
        except vart.ArtworkError as error:
            print(f"{source.name}: FAILED: {error}", file=sys.stderr)
            failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
