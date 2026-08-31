#!/usr/bin/env python3
"""Emit the alpha map of every plane as data, for the TATE crop.

videodr0me's third point: adjusting the rotated crop by trial is guesswork, and
the alpha map is the thing to key off. So this writes, per package and plane:

  * a three-class PNG -- clear, partial filter, full filter -- to look at
  * the geometry the crop needs, as JSON:
      artwork_box   tight bounds of everything not fully clear: where the
                    overlay actually is inside its plane
      filter_box    tight bounds of alpha 255, the part that fully colours
                    the beam
      clear_box     the largest axis-aligned rectangle of alpha 0 *inside*
                    artwork_box, which is the play area on artwork that cuts
                    one. Searched inside the artwork because on the
                    full-raster geometry the transparent margins either side
                    of the frame are the biggest clear rectangle in the plane.
                    Computed on a min-pooled mask, so it is conservative:
                    never larger than the true rectangle, never covering a
                    non-clear pixel
      open_box      tight bounds, inside artwork_box, of everything below the
                    solid floor: the play area on gel artwork, which never
                    reaches alpha 0

Boxes are [x, y, width, height] in plane pixels, with a `_norm` copy in 0..1 so
a crop can be carried between plane sizes and between orientations. Where a
class is absent the box is null rather than a zero rectangle, so "no clear
pixel anywhere" cannot be mistaken for "clear rectangle at the origin".

    opaque_maps.py artwork/generated_native -o overlay_work_videodr0me/test_results/opaque_maps
    opaque_maps.py artwork/generated_native -o OUT --only starcastle --png
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rgba_ops
import vart_encoder as vart


CLEAR = (236, 240, 239)
PARTIAL = (32, 122, 116)
FULL = (176, 82, 32)
VIOLATION = (222, 60, 60)


def bounds(mask: np.ndarray) -> list[int] | None:
    """Tight [x, y, w, h] of a boolean mask, or None when it is empty."""
    if not mask.any():
        return None
    rows = np.flatnonzero(mask.any(axis=1))
    cols = np.flatnonzero(mask.any(axis=0))
    return [
        int(cols[0]),
        int(rows[0]),
        int(cols[-1] - cols[0] + 1),
        int(rows[-1] - rows[0] + 1),
    ]


def largest_rectangle(mask: np.ndarray) -> list[int] | None:
    """Largest axis-aligned all-true rectangle, by the histogram method.

    The tight bounds of the clear pixels are not the crop: a frame with clear
    notches in it would report a box covering the notches too. The largest
    inscribed rectangle is the part that is actually clear all the way across.
    """
    if not mask.any():
        return None
    height, width = mask.shape
    heights = [0] * width
    best_area = 0
    best_box: list[int] | None = None
    for y in range(height):
        row = mask[y]
        for x in range(width):
            heights[x] = heights[x] + 1 if row[x] else 0
        # Largest rectangle in the histogram of column heights at this row.
        stack: list[int] = []
        for x in range(width + 1):
            current = heights[x] if x < width else 0
            while stack and heights[stack[-1]] >= current:
                top = stack.pop()
                left = stack[-1] + 1 if stack else 0
                span = x - left
                area = heights[top] * span
                if area > best_area:
                    best_area = area
                    best_box = [left, y - heights[top] + 1, span, heights[top]]
            stack.append(x)
    return best_box


def largest_rectangle_pooled(mask: np.ndarray, max_dim: int = 240) -> list[int] | None:
    """Largest all-true rectangle, computed on a min-pooled copy.

    The exact scan is O(pixels) in Python, which is minutes per pack at
    1360x1080. Pooling by an integer factor and keeping only blocks that are
    entirely true makes the answer conservative -- never larger than the true
    rectangle, never containing a pixel that is not clear -- and fast. The box
    is scaled back to plane pixels.
    """
    height, width = mask.shape
    factor = max(1, -(-max(height, width) // max_dim))
    if factor == 1:
        return largest_rectangle(mask)

    pooled_h, pooled_w = height // factor, width // factor
    if pooled_h == 0 or pooled_w == 0:
        return largest_rectangle(mask)
    trimmed = mask[: pooled_h * factor, : pooled_w * factor]
    pooled = trimmed.reshape(pooled_h, factor, pooled_w, factor).all(axis=(1, 3))

    box = largest_rectangle(pooled)
    if box is None:
        return None
    return [box[0] * factor, box[1] * factor, box[2] * factor, box[3] * factor]


def normalize(box: list[int] | None, size: tuple[int, int]) -> list[float] | None:
    if box is None:
        return None
    width, height = size
    return [
        round(box[0] / width, 6),
        round(box[1] / height, 6),
        round(box[2] / width, 6),
        round(box[3] / height, 6),
    ]


def class_map(alpha: np.ndarray) -> Image.Image:
    out = np.empty(alpha.shape + (3,), dtype=np.uint8)
    out[:] = PARTIAL
    out[alpha == 0] = CLEAR
    out[alpha == rgba_ops.OPAQUE] = FULL
    out[rgba_ops.solid_body(alpha)] = VIOLATION
    return Image.fromarray(out)


def measure(image: Image.Image) -> dict:
    alpha = np.asarray(image.convert("RGBA"))[:, :, 3]
    size = (image.width, image.height)
    artwork = alpha > 0
    full = alpha == rgba_ops.OPAQUE
    artwork_box = bounds(artwork)

    # The play area has to be looked for inside the artwork. On the
    # full-raster geometry the transparent margins either side of the frame
    # are the largest clear rectangle in the plane by a wide margin, and
    # reporting those as the play area would point the crop at the letterbox.
    if artwork_box is None:
        inner_clear = inner_open = np.zeros((0, 0), dtype=bool)
        origin = (0, 0)
    else:
        x, y, width, height = artwork_box
        window = alpha[y:y + height, x:x + width]
        inner_clear = window == 0
        inner_open = window < rgba_ops.SOLID_FLOOR
        origin = (x, y)

    def offset(box: list[int] | None) -> list[int] | None:
        if box is None:
            return None
        return [box[0] + origin[0], box[1] + origin[1], box[2], box[3]]

    boxes = {
        "artwork_box": artwork_box,
        "filter_box": bounds(full),
        "clear_box": offset(largest_rectangle_pooled(inner_clear)),
        "open_box": offset(bounds(inner_open)),
    }
    record: dict = {"width": image.width, "height": image.height}
    for name, box in boxes.items():
        record[name] = box
        record[f"{name}_norm"] = normalize(box, size)
    record["clear_share"] = round(float((alpha == 0).mean()), 6)
    record["full_share"] = round(float(full.mean()), 6)
    record["violations"] = int(rgba_ops.solid_body(alpha).sum())
    return record


def main() -> int:
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("art", type=Path)
    parser.add_argument("-o", "--outdir", type=Path, required=True)
    parser.add_argument("--only", help="comma-separated title names")
    parser.add_argument("--png", action="store_true",
                        help="also write the three-class map of every plane")
    args = parser.parse_args()

    art = args.art if args.art.is_absolute() else repo / args.art
    outdir = args.outdir if args.outdir.is_absolute() else repo / args.outdir
    outdir.mkdir(parents=True, exist_ok=True)

    packages = sorted(art.glob("*.art"))
    if args.only:
        wanted = {n.strip() for n in args.only.split(",") if n.strip()}
        packages = [
            p for p in packages
            if p.stem.replace("_90CCW", "").replace("_90CW", "") in wanted
        ]
    if not packages:
        parser.error("no packages found")

    titles: dict[str, dict] = {}
    for package in packages:
        name = package.stem
        base = name.replace("_90CCW", "").replace("_90CW", "")
        orientation = (
            "90CCW" if name.endswith("_90CCW")
            else "90CW" if name.endswith("_90CW")
            else "normal"
        )
        planes = []
        for index, plane in enumerate(vart.decode_container(package.read_bytes())):
            image = plane["image"].convert("RGBA")
            planes.append(measure(image))
            if args.png:
                target = outdir / "maps" / f"{name}_{image.width}x{image.height}.png"
                target.parent.mkdir(parents=True, exist_ok=True)
                class_map(np.asarray(image)[:, :, 3]).save(target, optimize=True)
        titles.setdefault(base, {})[orientation] = planes

    no_clear = sorted(
        base for base, orientations in titles.items()
        if all(plane["clear_box"] is None
               for planes in orientations.values() for plane in planes)
    )
    document = {
        "source": str(args.art),
        "titles": len(titles),
        "packages": len(packages),
        "note": "boxes are [x, y, w, h] in plane pixels; _norm is the same in 0..1",
        "no_clear_pixel_anywhere": no_clear,
        "maps": titles,
    }
    target = outdir / "opaque_maps.json"
    target.write_text(json.dumps(document, indent=1) + "\n")
    print(f"{len(packages)} packages, {len(titles)} titles -> {target}")
    print(f"{len(no_clear)} titles have no fully clear pixel in any plane"
          + (": " + ", ".join(no_clear[:8]) if no_clear else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
