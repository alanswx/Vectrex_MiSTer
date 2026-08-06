#!/usr/bin/env python3
"""Pick the best-resolution source image per overlay title across packs.

Scans the known source packs, normalizes each filename to a title key
(dropping noise like "-overlay-vgo", "_Small", bracketed tags), keeps the
largest portrait image per key, and emits one .art per title via build_vart.

Source packs, in the order they were gathered (2026-08-06):
  1. Overlay_Packs.zip ("Individual Overlays - Unpacked", 113 titles at
     846x1080 RGBA) - extract it and pass with --pack
  2. refs/overlay_sources/raphkoster/  (classics at ~963x1241, homebrew up
     to ~3900x4900)
  3. refs/overlay_sources/slydc_homebrew/  (16 homebrew titles)
Landscape images are skipped: they are RetroArch bezels, not tube overlays.

Usage:
    merge_sources.py --pack /path/to/'Individual Overlays - Unpacked' \
        [-o artwork/generated]
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_vart


def title_key(stem: str) -> str:
    s = stem.lower()
    s = re.sub(r"(overlay|-vgo|_small|\(.*?\))", "", s)
    return re.sub(r"[^a-z0-9]", "", s)


def clean_name(stem: str) -> str:
    name = re.sub(r"(-overlay(2)?-vgo|_Small|-vgo)", "", stem)
    return re.sub(r"[^A-Za-z0-9_\-'\.]", "_", name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pack", type=Path, action="append", default=[],
                        help="extra source directory (e.g. the unpacked Overlay_Packs.zip)")
    parser.add_argument("-o", "--outdir", type=Path,
                        default=Path("artwork/generated"))
    args = parser.parse_args()

    repo = Path(__file__).resolve().parents[2]
    roots = list(args.pack) + [
        repo / "refs/overlay_sources/raphkoster",
        repo / "refs/overlay_sources/slydc_homebrew",
        repo / "overlays",
    ]

    best: dict[str, tuple[Path, int]] = {}
    for root in roots:
        if not root.is_dir():
            continue
        for p in root.rglob("*.png"):
            try:
                with Image.open(p) as im:
                    w, h = im.size
            except Exception:
                continue
            if w >= h:      # landscape: bezel or banner, not a tube overlay
                continue
            k = title_key(p.stem)
            if k and (k not in best or w * h > best[k][1]):
                best[k] = (p, w * h)

    outdir = args.outdir if args.outdir.is_absolute() else repo / args.outdir
    outdir.mkdir(parents=True, exist_ok=True)
    ok = fail = 0
    for k in sorted(best):
        src = best[k][0]
        try:
            with tempfile.TemporaryDirectory() as tmp:
                container = build_vart.encode_overlay(src, Path(tmp))
            (outdir / f"{clean_name(src.stem)}.art").write_bytes(container)
            ok += 1
        except Exception as error:
            print(f"FAIL {src}: {error}", file=sys.stderr)
            fail += 1
    print(f"{ok} written, {fail} failed, {len(best)} titles")
    return 1 if fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
