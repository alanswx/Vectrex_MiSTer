#!/usr/bin/env python3
"""Prepare RGBA PNG artwork for the future TATE artwork converter.

The source artwork is kept untouched.  Each source is contained, without
distortion or cropping, in the current 810x1080 portrait artwork plane.  The
contained portrait is then rotated to make exact 1080x810 CW and CCW planes.
This deliberately stops before indexed quantization and VART/.art encoding.

Example:
    build_tate_pngs.py --all
    build_tate_pngs.py path/to/overlay.png -o overlay_work_videodr0me/tate_pngs
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image


PORTRAIT = (810, 1080)
ROTATED = (1080, 810)


def contain(source: Image.Image, size: tuple[int, int]) -> Image.Image:
    """Scale into size, preserving aspect ratio, on a transparent canvas."""
    source = source.convert("RGBA")
    source.thumbnail(size, Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    left = (size[0] - source.width) // 2
    top = (size[1] - source.height) // 2
    canvas.alpha_composite(source, (left, top))
    return canvas


def safe_stem(path: Path) -> str:
    return "_".join(path.stem.replace("_Small", "").split())


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", nargs="*", type=Path)
    parser.add_argument("--all", action="store_true", help="scan the high-resolution source pack")
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path("overlay_work_videodr0me/source_review/overlay_pack_846x1080"),
        help="directory scanned by --all",
    )
    parser.add_argument(
        "-o", "--outdir", type=Path,
        default=Path("overlay_work_videodr0me/tate_pngs"),
    )
    args = parser.parse_args()

    sources = list(args.images)
    if args.all:
        root = args.source_root if args.source_root.is_absolute() else repo / args.source_root
        sources.extend(sorted(root.glob("*.png")))
    sources = sorted({p.resolve() for p in sources})
    if not sources:
        parser.error("no input PNGs (pass images or --all)")

    outdir = args.outdir if args.outdir.is_absolute() else repo / args.outdir
    for variant in ("portrait", "90cw", "90ccw"):
        (outdir / variant).mkdir(parents=True, exist_ok=True)

    manifest: list[dict[str, object]] = []
    for source_path in sources:
        if source_path.suffix.lower() != ".png":
            continue
        with Image.open(source_path) as source:
            original_size = source.size
            portrait = contain(source, PORTRAIT)
        stem = safe_stem(source_path)
        outputs = {
            "portrait": portrait,
            "90cw": portrait.transpose(Image.Transpose.ROTATE_270),
            "90ccw": portrait.transpose(Image.Transpose.ROTATE_90),
        }
        record: dict[str, object] = {
            "source": str(source_path),
            "source_sha256": digest(source_path),
            "source_size": list(original_size),
            "canvas_policy": "contain-centered-transparent",
            "outputs": {},
        }
        for variant, image in outputs.items():
            target = outdir / variant / f"{stem}.png"
            image.save(target, format="PNG", optimize=True)
            record["outputs"][variant] = {
                "path": str(target.relative_to(repo)),
                "size": list(image.size),
                "sha256": digest(target),
                "mode": image.mode,
            }
        manifest.append(record)
        print(f"{source_path.name}: {original_size[0]}x{original_size[1]} -> {stem} (3 PNGs)")

    manifest_path = outdir / "MANIFEST.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"{len(manifest)} sources, {len(manifest) * 3} PNGs -> {outdir}")
    print(f"manifest -> {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
