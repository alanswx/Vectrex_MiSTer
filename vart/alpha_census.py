#!/usr/bin/env python3
"""Alpha census for Vectrex overlay artwork.

Two questions block the opaque-brightness feature and the TATE crop:

  1. Is there a de facto community standard for "this pixel blocks the beam"?
     If most artwork already lands on one level, the feature and the crop work
     as soon as the stragglers are redone.
  2. Where a blocking region is not exactly alpha 255, is that a real defect
     (a large body of near-opaque pixels) or just the antialias rim around a
     hard edge, which is correct and wanted?

A flat histogram cannot separate 2, so every band is measured twice: once over
all pixels, and once over the *body* -- what survives an N-pixel erosion.
Thin rims erode away; a mis-authored region does not.

Severity is quantified with the compositor's own arithmetic
(rtl/videodr0me_fb/vfb_overlay.sv):

    transmission = 255 - (255 - art_colour) * alpha / 256

so a black blocker at alpha 255 passes 1/255 of the beam and one at alpha 232
passes 24/255. That leak is what shows through a frame that was meant to be
solid.

Usage:
    alpha_census.py overlays overlay_work_videodr0me/canonical -o OUTDIR
    alpha_census.py artwork/generated -o OUTDIR --label generated
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vart_encoder as vart


# Alpha bands. The boundaries are policy, not measurement: 255 is the only
# value the compositor treats as a full blocker, 254 is what Pillow's octree
# quantizer collapses opaque pixels into, and 200 is a deliberately generous
# floor for "the author clearly meant this to be solid".
CLEAR = 0
FAINT_MAX = 15
MID_MAX = 199
NEAR_MIN = 200
NEAR_MAX = 253
SNAPPED = 254
OPAQUE = 255

BANDS = {
    "clear": (0, 0),
    "faint": (1, FAINT_MAX),
    "mid": (FAINT_MAX + 1, MID_MAX),
    "near": (NEAR_MIN, NEAR_MAX),
    "snapped": (SNAPPED, SNAPPED),
    "opaque": (OPAQUE, OPAQUE),
}


def erode(mask: np.ndarray, iterations: int) -> np.ndarray:
    """Erode a boolean mask with a 4-connected kernel.

    The pad replicates the border so a frame that runs to the edge of the
    plane is not eaten from outside; only genuinely thin structures vanish.
    """
    result = mask
    for _ in range(iterations):
        padded = np.pad(result, 1, mode="edge")
        result = (
            padded[1:-1, 1:-1]
            & padded[:-2, 1:-1]
            & padded[2:, 1:-1]
            & padded[1:-1, :-2]
            & padded[1:-1, 2:]
        )
    return result


def transmission(colour: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    """The compositor's transmission term, in integer arithmetic."""
    gap = ((255 - colour.astype(np.int32)) * alpha.astype(np.int32)) // 256
    return 255 - gap


def ladder(values: np.ndarray) -> str:
    """Name the alpha quantization the image was authored or decoded with."""
    distinct = values.size
    if distinct <= 2:
        return "binary"
    if distinct <= 16:
        if np.all(values % 17 == 0):
            return "4bit_x17"
        if np.all(values % 16 == 0):
            return "4bit_x16"
        return "4bit_other"
    return "8bit"


def census_image(image: Image.Image, erosion: int) -> dict:
    rgba = np.asarray(image.convert("RGBA"), dtype=np.uint8)
    alpha = rgba[:, :, 3]
    rgb = rgba[:, :, :3]
    total = int(alpha.size)

    histogram = np.bincount(alpha.reshape(-1), minlength=256)
    distinct = np.flatnonzero(histogram).astype(np.int64)

    row: dict = {
        "width": int(image.width),
        "height": int(image.height),
        "pixels": total,
        "distinct_alphas": int(distinct.size),
        "ladder": ladder(distinct),
    }

    body_counts: dict[str, int] = {}
    for name, (low, high) in BANDS.items():
        band = (alpha >= low) & (alpha <= high)
        row[f"{name}_px"] = int(band.sum())
        if name in ("clear", "opaque"):
            continue
        body = erode(band, erosion) if erosion else band
        body_counts[name] = int(body.sum())
        row[f"{name}_body_px"] = body_counts[name]

    # The defect the opaque-brightness option trips over: a solid-looking area
    # whose alpha is close to, but not, 255.
    unsafe = erode((alpha >= NEAR_MIN) & (alpha <= SNAPPED), erosion)
    unsafe_px = int(unsafe.sum())
    row["unsafe_body_px"] = unsafe_px
    row["unsafe_body_pct"] = round(100.0 * unsafe_px / total, 4)

    if unsafe_px:
        unsafe_alpha = alpha[unsafe]
        leak = transmission(rgb[unsafe], unsafe_alpha[:, None]).max(axis=1)
        row["unsafe_modal_alpha"] = int(np.bincount(unsafe_alpha).argmax())
        row["unsafe_leak_mean_pct"] = round(float(leak.mean()) * 100.0 / 255.0, 2)
        row["unsafe_leak_max_pct"] = round(float(leak.max()) * 100.0 / 255.0, 2)
    else:
        row["unsafe_modal_alpha"] = ""
        row["unsafe_leak_mean_pct"] = ""
        row["unsafe_leak_max_pct"] = ""

    # Large genuinely translucent areas. These are what a global alpha
    # threshold in the core would wrongly promote to blockers.
    gel = erode((alpha > FAINT_MAX) & (alpha <= MID_MAX), erosion)
    gel_px = int(gel.sum())
    row["gel_body_px"] = gel_px
    row["gel_body_pct"] = round(100.0 * gel_px / total, 4)
    row["gel_modal_alpha"] = int(np.bincount(alpha[gel]).argmax()) if gel_px else ""

    # What level does this artwork actually use for its solid areas?
    solid = erode(alpha > MID_MAX, erosion)
    row["solid_modal_alpha"] = int(np.bincount(alpha[solid]).argmax()) if solid.any() else ""

    row["has_clear"] = int(row["clear_px"] > 0)

    if distinct.size == 1 and distinct[0] == OPAQUE:
        # Nothing can show through this at all; it is not a usable overlay.
        row["verdict"] = "opaque_only"
    elif unsafe_px == 0:
        row["verdict"] = "clean"
    elif row["unsafe_body_pct"] < 0.1:
        row["verdict"] = "minor"
    else:
        row["verdict"] = "defect"

    row["_histogram"] = histogram.tolist()
    return row


def iter_targets(paths: list[Path]):
    for path in paths:
        if path.is_dir():
            for child in sorted(path.iterdir()):
                if child.suffix.lower() in (".png", ".art"):
                    yield child
        elif path.suffix.lower() in (".png", ".art"):
            yield path


def census_target(path: Path, erosion: int) -> list[dict]:
    if path.suffix.lower() == ".art":
        rows = []
        for index, plane in enumerate(vart.decode_container(path.read_bytes())):
            row = census_image(plane["image"], erosion)
            row["source"] = str(path)
            row["plane"] = f"{index}:{plane['width']}x{plane['height']}"
            rows.append(row)
        return rows
    with Image.open(path) as image:
        row = census_image(image, erosion)
    row["source"] = str(path)
    row["plane"] = ""
    return [row]


FIELDS = [
    "source",
    "plane",
    "width",
    "height",
    "pixels",
    "distinct_alphas",
    "ladder",
    "verdict",
    "has_clear",
    "clear_px",
    "faint_px",
    "mid_px",
    "near_px",
    "snapped_px",
    "opaque_px",
    "faint_body_px",
    "mid_body_px",
    "near_body_px",
    "snapped_body_px",
    "unsafe_body_px",
    "unsafe_body_pct",
    "unsafe_modal_alpha",
    "unsafe_leak_mean_pct",
    "unsafe_leak_max_pct",
    "gel_body_px",
    "gel_body_pct",
    "gel_modal_alpha",
    "solid_modal_alpha",
]


def write_csv(rows: list[dict], target: Path) -> None:
    with target.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def summarize(rows: list[dict], erosion: int, label: str) -> str:
    total = len(rows)
    verdicts = Counter(row["verdict"] for row in rows)
    ladders = Counter(row["ladder"] for row in rows)
    solids = Counter(row["solid_modal_alpha"] for row in rows if row["solid_modal_alpha"] != "")

    lines = [
        f"# Alpha census — {label}",
        "",
        f"{total} images. Body = what survives a {erosion}-pixel erosion, so "
        "antialias rims are excluded and only mis-authored areas are counted.",
        "",
        "## Verdicts",
        "",
        "| Verdict | Images | Meaning |",
        "|---|---:|---|",
    ]
    meanings = {
        "clean": "no near-opaque body pixels; the blocking areas are exactly 255",
        "minor": "under 0.1% of the plane is near-opaque body",
        "defect": "0.1% or more of the plane is near-opaque body",
        "opaque_only": "one alpha value, 255; blocks the whole screen",
    }
    for name in ("clean", "minor", "defect", "opaque_only"):
        if verdicts.get(name):
            lines.append(f"| {name} | {verdicts[name]} | {meanings[name]} |")

    no_clear = [row for row in rows if not row["has_clear"]]
    if no_clear:
        lines += [
            "",
            f"{len(no_clear)} of {total} images never reach alpha 0, so no part "
            "of the plane is fully clear. That is not a defect by itself, but "
            "the crop cannot be found by looking for a transparent hole:",
            "",
        ]
        for row in no_clear:
            lines.append(f"- `{Path(row['source']).name}` {row['plane']}".rstrip())

    lines += [
        "",
        "## Solid-area alpha actually used",
        "",
        "The modal alpha of every body pixel above 199 — the level this artwork "
        "treats as solid.",
        "",
        "| Alpha | Images |",
        "|---:|---:|",
    ]
    for value, count in sorted(solids.items(), key=lambda item: -item[1]):
        lines.append(f"| {value} | {count} |")

    lines += [
        "",
        "## Alpha quantization of the sources",
        "",
        "| Ladder | Images |",
        "|---|---:|",
    ]
    for name, count in ladders.most_common():
        lines.append(f"| {name} | {count} |")

    offenders = sorted(
        (row for row in rows if row["verdict"] in ("defect", "minor")),
        key=lambda row: -row["unsafe_body_pct"],
    )
    if offenders:
        lines += [
            "",
            "## Near-opaque bodies, worst first",
            "",
            "Leak is the fraction of a full-brightness vector that passes "
            "through the offending pixels, by the compositor's own arithmetic.",
            "",
            "| Image | Plane | Body px | % of plane | Modal alpha | Mean leak | Max leak |",
            "|---|---|---:|---:|---:|---:|---:|",
        ]
        for row in offenders[:60]:
            name = Path(row["source"]).name
            lines.append(
                f"| {name} | {row['plane']} | {row['unsafe_body_px']} | "
                f"{row['unsafe_body_pct']}% | {row['unsafe_modal_alpha']} | "
                f"{row['unsafe_leak_mean_pct']}% | {row['unsafe_leak_max_pct']}% |"
            )

    gels = sorted(
        (row for row in rows if row["gel_body_pct"] >= 0.5),
        key=lambda row: -row["gel_body_pct"],
    )
    lines += [
        "",
        "## Translucent bodies",
        "",
        f"{len(gels)} of {total} images carry a genuinely translucent area "
        "larger than 0.5% of the plane. A global alpha threshold in the core "
        "would promote these to blockers.",
        "",
    ]
    if gels:
        lines += [
            "| Image | Plane | Body px | % of plane | Modal alpha |",
            "|---|---|---:|---:|---:|",
        ]
        for row in gels[:40]:
            name = Path(row["source"]).name
            lines.append(
                f"| {name} | {row['plane']} | {row['gel_body_px']} | "
                f"{row['gel_body_pct']}% | {row['gel_modal_alpha']} |"
            )

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("-o", "--outdir", type=Path, required=True)
    parser.add_argument("--erode", type=int, default=2,
                        help="erosion depth separating rims from bodies")
    parser.add_argument("--label", default="overlay artwork")
    parser.add_argument("--name", default="census")
    args = parser.parse_args()

    rows: list[dict] = []
    for target in iter_targets(args.paths):
        try:
            rows.extend(census_target(target, args.erode))
        except Exception as error:  # noqa: BLE001 - report and continue
            print(f"skipped {target}: {error}", file=sys.stderr)

    if not rows:
        print("no images found", file=sys.stderr)
        return 1

    args.outdir.mkdir(parents=True, exist_ok=True)
    write_csv(rows, args.outdir / f"{args.name}.csv")
    for row in rows:
        row["histogram"] = row.pop("_histogram")
    (args.outdir / f"{args.name}.json").write_text(
        json.dumps(rows, indent=1) + "\n"
    )
    (args.outdir / f"{args.name}.md").write_text(
        summarize(rows, args.erode, args.label)
    )
    print(f"{len(rows)} images -> {args.outdir}/{args.name}.{{csv,json,md}}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
