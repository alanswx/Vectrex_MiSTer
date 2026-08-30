#!/usr/bin/env python3
"""Build, extract, and deploy Vectrex VART artwork packages.

Commands:
  main SOURCE              Build all orientations from one native portrait PNG.
  exact INPUT              Pack exact full-raster PNG sets in INPUT.
  extract INPUT.art        Extract every stored VART plane as RGBA PNG.
  copies                   Delegate ROM-name matching to name_for_roms.py.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

from PIL import Image

import build_vart
import rgba_ops


FULL_RASTER = (1360, 1080)
TATE_SCALE = 1360 / 1080


def name_for(source: Path) -> str:
    return "_".join(source.stem.replace("_Small", "").split())


def upscaled_tate(source: Path, clockwise: bool) -> Image.Image:
    with Image.open(source) as image:
        angle = Image.Transpose.ROTATE_270 if clockwise else Image.Transpose.ROTATE_90
        turned = image.convert("RGBA").transpose(angle)
    height = round(turned.height * TATE_SCALE)
    scaled = rgba_ops.resize_rgba(turned, (FULL_RASTER[0], height))
    canvas = Image.new("RGBA", FULL_RASTER, (0, 0, 0, 0))
    canvas.alpha_composite(scaled, (0, (FULL_RASTER[1] - height) // 2))
    return canvas


def from_native(source: Path, workdir: Path) -> dict[str, bytes]:
    normal, _ = build_vart.portrait_fallback(source)
    clockwise = {}
    for label, (raster, _, _) in build_vart.RASTERS.items():
        tate = upscaled_tate(source, clockwise=True)
        clockwise[label] = rgba_ops.resize_rgba(tate, raster)
    # encode_orientations derives CCW from CW with an exact 180-degree turn.
    return build_vart.encode_orientations(normal, clockwise, workdir)


def pack_exact(root: Path, workdir: Path) -> dict[str, bytes]:
    normal = build_vart.load_exact_set(root / "normal")
    clockwise = build_vart.load_exact_set(root / "90CW")
    ccw_root = root / "90CCW"
    if ccw_root.is_dir():
        counter = build_vart.load_exact_set(ccw_root)
        packages = {
            "": build_vart.encode_set(normal, workdir / "normal"),
            "_90CW": build_vart.encode_set(clockwise, workdir / "90CW"),
            "_90CCW": build_vart.encode_set(counter, workdir / "90CCW"),
        }
        return packages
    return build_vart.encode_orientations(normal, clockwise, workdir)


def write_packages(packages: dict[str, bytes], name: str, outdir: Path) -> dict[str, int]:
    return build_vart.write_packages(packages, name, outdir, verbose=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    native = commands.add_parser("main", help="build all orientations from one portrait PNG")
    native.add_argument("source", type=Path)
    native.add_argument("--name")
    native.add_argument("-o", "--outdir", type=Path, required=True)

    exact = commands.add_parser("exact", help="pack exact full-raster PNG planes")
    exact.add_argument("input", type=Path, help="directory containing normal/, 90CW/, optionally 90CCW/")
    exact.add_argument("--name")
    exact.add_argument("-o", "--outdir", type=Path, required=True)

    extract = commands.add_parser("extract", help="extract all VART planes as RGBA PNGs")
    extract.add_argument("input", type=Path)
    extract.add_argument("-o", "--outdir", type=Path, required=True)

    args = parser.parse_args()
    try:
        if args.command == "extract":
            planes = build_vart.vart.decode_container(args.input.read_bytes())
            args.outdir.mkdir(parents=True, exist_ok=True)
            manifest = []
            for index, plane in enumerate(planes):
                image = plane["image"]
                target = args.outdir / f"plane_{index}_{plane['width']}x{plane['height']}.png"
                image.save(target, format="PNG", optimize=True)
                manifest.append({"path": target.name, "width": plane["width"], "height": plane["height"], "role": plane["role"], "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
            (args.outdir / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
            print(f"extracted {len(planes)} planes -> {args.outdir}")
            return 0

        args.outdir.mkdir(parents=True, exist_ok=True)
        name = args.name or (name_for(args.source) if args.command == "main" else args.input.name)
        with tempfile.TemporaryDirectory(prefix="vart-tool-") as workdir:
            if args.command == "main":
                packages = from_native(args.source, Path(workdir))
            else:
                packages = pack_exact(args.input, Path(workdir))
        write_packages(packages, name, args.outdir)
        return 0
    except (OSError, build_vart.vart.ArtworkError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
