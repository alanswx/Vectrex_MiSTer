#!/usr/bin/env python3
"""Raise near-opaque bodies in source artwork to exactly alpha 255.

The builder enforces the contract at encode time, so the shipping packages are
correct either way. Repairing the sources as well means the next person to
build from them starts compliant, and the source census reads clean.

Only bodies are touched: alpha between 200 and 254 that survives a two-pixel
erosion of everything the artwork means as solid. Antialias rims and genuine
tint are left exactly as authored -- a gel at alpha 179 stays at 179.

    repair_sources.py overlays overlay_work_videodr0me/canonical
    repair_sources.py --dry-run overlays
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rgba_ops


def targets(paths: list[Path]):
    for path in paths:
        if path.is_dir():
            yield from sorted(p for p in path.iterdir() if p.suffix.lower() == ".png")
        elif path.suffix.lower() == ".png":
            yield path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    repaired = 0
    total = 0
    for path in targets(args.paths):
        with Image.open(path) as handle:
            original = handle.convert("RGBA").copy()
        fixed, raised = rgba_ops.snap_solid_body(original)
        if not raised:
            continue
        share = 100.0 * raised / (original.width * original.height)
        print(f"{path}: {raised:,} px ({share:.2f}% of the image) raised to 255")
        repaired += 1
        total += raised
        if not args.dry_run:
            fixed.save(path)

    verb = "would repair" if args.dry_run else "repaired"
    print(f"\n{verb} {repaired} images, {total:,} pixels")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
