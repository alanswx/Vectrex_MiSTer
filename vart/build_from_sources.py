#!/usr/bin/env python3
"""Build Normal, 90CW, and 90CCW VART packages from portrait source PNGs.

This uses the newer ``vart/build_vart.py`` framing policy. Source artwork is
read as RGBA, placed into the authored full-raster canvases, quantized only
inside the VART encoder, and verified before each package is written.

Usage from the repository root:

    python3 vart/build_from_sources.py --all
    python3 vart/build_from_sources.py path/to/source.png -o artwork/generated_tate
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

import build_vart
from PIL import Image


TATE_SCALE = 1360 / 1080
FULL_RASTER = (1360, 1080)


def output_name(source: Path) -> str:
    stem = source.stem.replace("_Small", "")
    return "_".join(stem.split())


def tate_full_raster(source: Path) -> Image.Image:
    """Scale rotated native art to full 1360x1080 TATE raster."""
    with Image.open(source) as image:
        turned = image.convert("RGBA").transpose(Image.Transpose.ROTATE_270)
    height = round(turned.height * TATE_SCALE)
    scaled = turned.resize((FULL_RASTER[0], height), Image.Resampling.HAMMING)
    canvas = Image.new("RGBA", FULL_RASTER, (0, 0, 0, 0))
    canvas.alpha_composite(scaled, (0, (FULL_RASTER[1] - height) // 2))
    return canvas


def tate_orientations(source: Path) -> tuple[dict[str, Image.Image], dict[str, Image.Image]]:
    """Create normal framing and upscaled full-screen TATE framing."""
    normal, _ = build_vart.portrait_fallback(source)
    tate = tate_full_raster(source)
    clockwise = {
        label: tate.resize(raster, Image.Resampling.HAMMING)
        for label, (raster, _, _) in build_vart.RASTERS.items()
    }
    return normal, clockwise


def build_one(job: tuple[str, str]) -> dict[str, object]:
    source_text, outdir_text = job
    source = Path(source_text)
    outdir = Path(outdir_text)
    name = output_name(source)
    normal, clockwise = tate_orientations(source)
    with tempfile.TemporaryDirectory(prefix="vart-source-") as workdir:
        packages = build_vart.encode_orientations(normal, clockwise, Path(workdir))
    sizes = build_vart.write_packages(packages, name, outdir, verbose=False)
    return {
        "source": str(source),
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "name": name,
        "packages": sizes,
    }


def main() -> int:
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", nargs="*", type=Path)
    parser.add_argument("--all", action="store_true", help="scan the high-resolution source pack")
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path("overlay_work_videodr0me/source_review/overlay_pack_846x1080"),
    )
    parser.add_argument("-o", "--outdir", type=Path, default=Path("artwork/generated_tate"))
    parser.add_argument("-j", "--jobs", type=int, default=min(8, os.cpu_count() or 1))
    args = parser.parse_args()

    sources = list(args.images)
    if args.all:
        root = args.source_root if args.source_root.is_absolute() else repo / args.source_root
        sources.extend(sorted(root.glob("*.png")))
    sources = sorted({p.resolve() for p in sources})
    if not sources:
        parser.error("no input PNGs (pass images or --all)")
    if args.jobs < 1:
        parser.error("--jobs must be at least one")

    outdir = args.outdir if args.outdir.is_absolute() else repo / args.outdir
    outdir.mkdir(parents=True, exist_ok=True)
    jobs = [(str(source), str(outdir)) for source in sources]
    results: list[dict[str, object]] = []
    failures = 0
    with concurrent.futures.ProcessPoolExecutor(max_workers=args.jobs) as pool:
        pending = {pool.submit(build_one, job): job[0] for job in jobs}
        for index, future in enumerate(concurrent.futures.as_completed(pending), 1):
            source = pending[future]
            try:
                result = future.result()
            except Exception as error:
                print(f"[{index}/{len(jobs)}] FAILED {source}: {error}", file=sys.stderr)
                failures += 1
                continue
            results.append(result)
            packages = result["packages"]
            total = sum(int(size) for size in packages.values())
            print(f"[{index}/{len(jobs)}] {result['name']}: 3 packages, {total:,} bytes")

    results.sort(key=lambda result: str(result["name"]).lower())
    manifest = {
        "format": "VART",
        "source_count": len(results),
        "package_count": len(results) * 3,
        "failures": failures,
        "framing": "native portrait rotated CW, scaled 1360/1080, centered with transparent alpha, then downsampled",
        "packages": results,
    }
    (outdir / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"generated {len(results) * 3} packages for {len(results)} sources")
    print(f"manifest -> {outdir / 'MANIFEST.json'}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
