#!/usr/bin/env python3
"""Rebuild every shipping .art package with the alpha-correct pipeline.

Each title keeps its own artwork. The portrait art is recovered from the
1360x1080 plane of the existing package -- the highest-fidelity copy in the
file, and the frame the 1080p plane is authored at, so nothing is upscaled --
and all twelve planes are then built from it in one reduction each.

Eighteen titles cannot be rebuilt from themselves: their artwork is a fully
opaque scan with no alpha cut, so the overlay blocks the whole screen. Those
are re-sourced from a transmissive copy of the same title, preferring the
canonical scans, then the 846x1080 pack, then the legacy `overlays/` decode.
Two homebrew titles have no transmissive source anywhere and are reported
rather than silently shipped.

    rebuild_pack.py -o artwork/generated
    rebuild_pack.py --only starcastle,minestorm -o /tmp/probe
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_vart
import rgba_ops
import vart_encoder as vart


REPO = Path(__file__).resolve().parents[1]
PORTRAIT_RASTER, PORTRAIT_FRAME, _ = build_vart.RASTERS["1080p"]

# Searched in order; the first transmissive match wins.
SOURCE_POOLS = (
    ("canonical", Path("overlay_work_videodr0me/canonical")),
    ("pack846", Path("overlay_work_videodr0me/source_review/overlay_pack_846x1080")),
    ("overlays", Path("overlays")),
)

# Titles whose normalized key does not reach their own artwork.
ALIASES = {"spacewar": "spacewars"}


def title_key(stem: str) -> str:
    lowered = re.sub(r"(overlay|-vgo|_small|_200dpi|\(.*?\))", "", stem.lower())
    return re.sub(r"[^a-z0-9]", "", re.sub(r"\d+$", "", lowered))


def is_transmissive(image: Image.Image) -> bool:
    """True when anything at all can pass through the artwork."""
    return int(np.asarray(image.convert("RGBA"))[:, :, 3].min()) < rgba_ops.OPAQUE


def build_source_index() -> dict[str, list[tuple[str, Path]]]:
    index: dict[str, list[tuple[str, Path]]] = {}
    for pool, relative in SOURCE_POOLS:
        root = REPO / relative
        if not root.is_dir():
            continue
        for png in sorted(root.glob("*.png")):
            index.setdefault(title_key(png.stem), []).append((pool, png))
    return index


def portrait_from_package(path: Path) -> Image.Image:
    """Recover the authored 810x1080 portrait from a package's largest plane."""
    planes = [
        plane
        for plane in vart.decode_container(path.read_bytes())
        if plane["role"] == vart.ROLE_OVERLAY
    ]
    if not planes:
        raise vart.ArtworkError(f"{path}: no overlay plane")
    largest = max(planes, key=lambda plane: int(plane["width"]) * int(plane["height"]))
    image = largest["image"].convert("RGBA")
    if image.size == PORTRAIT_RASTER:
        x, y, width, height = PORTRAIT_FRAME
        return image.crop((x, y, x + width, y + height))
    return image


def resolve_portrait(
    name: str, package: Path, index: dict[str, list[tuple[str, Path]]]
) -> tuple[Image.Image, str]:
    own = portrait_from_package(package)
    if is_transmissive(own):
        return own, "self"

    key = ALIASES.get(title_key(name), title_key(name))
    for pool, png in index.get(key, []):
        with Image.open(png) as candidate:
            image = candidate.convert("RGBA").copy()
        if is_transmissive(image):
            return image, f"{pool}:{png.name}"
    return own, "self (opaque, no transmissive source found)"


def rebuild_one(job: tuple[str, str, str]) -> dict[str, object]:
    name, package_text, outdir_text = job
    package = Path(package_text)
    index = build_source_index()
    portrait, origin = resolve_portrait(name, package, index)
    normal, clockwise = build_vart.frame_orientations(portrait)
    with tempfile.TemporaryDirectory(prefix="vart-rebuild-") as workdir:
        packages = build_vart.encode_orientations(normal, clockwise, Path(workdir))
    sizes = build_vart.write_packages(packages, name, Path(outdir_text), verbose=False)

    violations = 0
    opaque_planes = 0
    for container in packages.values():
        for plane in vart.decode_container(container):
            alpha = np.asarray(plane["image"].convert("RGBA"))[:, :, 3]
            violations += int(rgba_ops.solid_body(alpha).sum())
            opaque_planes += int(alpha.min() == rgba_ops.OPAQUE)
    return {
        "name": name,
        "source": origin,
        "packages": sizes,
        "violations": violations,
        "opaque_planes": opaque_planes,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--outdir", type=Path, default=Path("artwork/generated"))
    parser.add_argument("--art", type=Path, default=Path("artwork/generated"),
                        help="packages to read the existing artwork from")
    parser.add_argument("--only", help="comma-separated title names, for spot checks")
    parser.add_argument("-j", "--jobs", type=int, default=min(8, os.cpu_count() or 1))
    args = parser.parse_args()

    art = args.art if args.art.is_absolute() else REPO / args.art
    outdir = args.outdir if args.outdir.is_absolute() else REPO / args.outdir
    outdir.mkdir(parents=True, exist_ok=True)

    names = sorted(
        {p.stem for p in art.glob("*.art") if "_90CW" not in p.stem and "_90CCW" not in p.stem}
    )
    if args.only:
        wanted = {n.strip() for n in args.only.split(",") if n.strip()}
        names = [n for n in names if n in wanted]
    if not names:
        parser.error("no packages to rebuild")

    jobs = [(name, str(art / f"{name}.art"), str(outdir)) for name in names]
    results: list[dict[str, object]] = []
    failures = 0
    with concurrent.futures.ProcessPoolExecutor(max_workers=args.jobs) as pool:
        pending = {pool.submit(rebuild_one, job): job[0] for job in jobs}
        for index, future in enumerate(concurrent.futures.as_completed(pending), 1):
            name = pending[future]
            try:
                results.append(future.result())
            except Exception as error:  # noqa: BLE001 - report and keep going
                print(f"[{index}/{len(jobs)}] FAILED {name}: {error}", file=sys.stderr)
                failures += 1
                continue
            print(f"[{index}/{len(jobs)}] {name}")

    results.sort(key=lambda result: str(result["name"]).lower())
    resourced = [r for r in results if r["source"] != "self"]
    unresolved = [r for r in results if r["opaque_planes"]]
    violating = [r for r in results if r["violations"]]

    (outdir / "REBUILD.json").write_text(
        json.dumps(
            {
                "titles": len(results),
                "failures": failures,
                "re_sourced": len(resourced),
                "still_opaque": [r["name"] for r in unresolved],
                "contract_violations": {r["name"]: r["violations"] for r in violating},
                "results": results,
            },
            indent=2,
        )
        + "\n"
    )

    print(f"\nrebuilt {len(results)} titles, {len(results) * 3} packages")
    print(f"re-sourced: {len(resourced)}")
    for result in resourced:
        print(f"   {result['name']:24s} <- {result['source']}")
    print(f"contract violations: {sum(int(r['violations']) for r in results)}")
    if unresolved:
        print(f"still fully opaque ({len(unresolved)}): "
              + ", ".join(str(r["name"]) for r in unresolved))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
