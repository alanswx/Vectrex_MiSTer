#!/usr/bin/env python3
"""Render overlay proof sheets using the core's own compositing arithmetic.

The point is to see what the FPGA will show, not what an image viewer thinks
the PNG looks like, so the beam columns run the integer pipeline from
``rtl/videodr0me_fb/vfb_overlay.sv`` pixel for pixel:

    w = alpha * blend_weight + 128
    effective    = (w + (w >> 8)) >> 8
    ambient      = ((art * effective) + 32) >> 6
    transmission = 255 - (((255 - art) * alpha) >> 8)
    p            = beam * transmission
    out          = ambient + ((p + (p >> 8) + 128) >> 8)      saturating

Columns, left to right:

    artwork   the art over a checkerboard, so alpha is visible as alpha
    alpha     three classes -- clear, partial filter, full filter. Alpha is
              filter strength, not opacity: at 255 the beam arrives tinted to
              the artwork's own colour, so a pale region still passes light
              and only a dark one blocks. This is the map the TATE crop and
              the opaque-brightness option both key off
    dark      what the overlay looks like with the beam off
    beam      a full-white raster through the overlay at 100% ambient
    beam 30%  the same raster at 30% ambient, where a blocker that is not
              exactly 255 stops hiding: the leak holds still while the
              artwork covering it is dialled down

Usage:
    proofsheet.py artwork/generated -o proofsheets
    proofsheet.py artwork/generated -o proofsheets --orientation 90CW --plane 240p
    proofsheet.py artwork/generated -o proofsheets --compare artwork/generated.bak
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_vart
import rgba_ops
import vart_encoder as vart


# The OSD's ambient ladder, 100% down to 30% (vfb_overlay.sv blend_weight).
BLEND_WEIGHTS = {100: 64, 90: 58, 80: 51, 70: 45, 60: 38, 50: 32, 40: 26, 30: 19}

TILE_HEIGHT = 190
# A 720x240 rotated plane is 3:1, so height alone would make the sheet 3000px
# wide. Cap the width and let those tiles be shorter instead.
TILE_MAX_WIDTH = 300
GUTTER = 10
LABEL_WIDTH = 168
MARGIN = 18
ROWS_PER_SHEET = 11

INK = (28, 32, 33)
PAPER = (247, 249, 248)
RULE = (214, 222, 220)
MUTED = (110, 124, 124)

# Alpha map classes. Alpha is filter strength, not opacity: at 255 the beam
# comes through tinted to the artwork's own colour, so a pale region at 255
# still passes light and only a dark one blocks.
CLEAR_COLOR = (236, 240, 239)   # alpha 0, the beam passes white
TINT_COLOR = (32, 122, 116)     # partial filter
FULL_COLOR = (176, 82, 32)      # alpha 255, the beam takes the artwork colour
NEAR_COLOR = (222, 60, 60)      # off 255 where it should not be


def composite(art: np.ndarray, beam: np.ndarray, percent: int) -> np.ndarray:
    """The compositor, in integers, exactly as the RTL evaluates it."""
    rgb = art[:, :, :3].astype(np.int32)
    alpha = art[:, :, 3].astype(np.int32)[:, :, None]
    weight = BLEND_WEIGHTS[percent]

    rounded = alpha * weight + 128
    effective = (rounded + (rounded >> 8)) >> 8
    ambient = ((rgb * effective) + 32) >> 6

    transmission = 255 - (((255 - rgb) * alpha) >> 8)
    product = beam.astype(np.int32) * transmission
    scaled = (product + (product >> 8) + 128) >> 8

    return np.clip(ambient + scaled, 0, 255).astype(np.uint8)


def checkerboard(shape: tuple[int, int], size: int = 8) -> np.ndarray:
    rows, cols = shape
    y, x = np.mgrid[0:rows, 0:cols]
    tile = (((y // size) + (x // size)) % 2).astype(np.uint8)
    return np.where(tile[:, :, None] == 1, np.uint8(228), np.uint8(196)) * np.ones(
        (1, 1, 3), dtype=np.uint8
    )


def over_checker(art: np.ndarray) -> np.ndarray:
    """Plain source-over onto a checkerboard: shows the art and its alpha."""
    ground = checkerboard(art.shape[:2]).astype(np.int32)
    rgb = art[:, :, :3].astype(np.int32)
    alpha = art[:, :, 3].astype(np.int32)[:, :, None]
    return np.clip((rgb * alpha + ground * (255 - alpha)) // 255, 0, 255).astype(np.uint8)


def alpha_map(art: np.ndarray) -> np.ndarray:
    """Clear / tint / full filter, with contract violations called out in red."""
    alpha = art[:, :, 3]
    out = np.empty(alpha.shape + (3,), dtype=np.uint8)
    out[:] = TINT_COLOR
    out[alpha == 0] = CLEAR_COLOR
    out[alpha == rgba_ops.OPAQUE] = FULL_COLOR
    out[rgba_ops.solid_body(alpha)] = NEAR_COLOR
    return out


def plane_rgba(package: Path, label: str) -> np.ndarray:
    raster = build_vart.RASTERS[label][0]
    for plane in vart.decode_container(package.read_bytes()):
        if (plane["width"], plane["height"]) == raster:
            return np.asarray(plane["image"].convert("RGBA"), dtype=np.uint8)
    raise vart.ArtworkError(f"{package}: no {raster[0]}x{raster[1]} plane")


def fit(array: np.ndarray, height: int) -> Image.Image:
    image = Image.fromarray(array)
    scale = min(height / image.height, TILE_MAX_WIDTH / image.width)
    size = (max(1, round(image.width * scale)), max(1, round(image.height * scale)))
    return image.resize(size, Image.Resampling.LANCZOS)


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    names = (
        ["/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/System/Library/Fonts/Helvetica.ttc"]
        if bold
        else ["/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Helvetica.ttc"]
    )
    for name in names:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def build_row(art: np.ndarray, compare: np.ndarray | None) -> list[tuple[str, np.ndarray]]:
    beam = np.full(art.shape[:2] + (3,), 255, dtype=np.uint8)
    views = [
        ("artwork", over_checker(art)),
        ("alpha", alpha_map(art)),
        ("dark", composite(art, np.zeros_like(beam), 100)),
        ("beam", composite(art, beam, 100)),
        ("beam 30%", composite(art, beam, 30)),
    ]
    if compare is not None:
        views.insert(4, ("beam (was)", composite(compare, np.full(compare.shape[:2] + (3,), 255, np.uint8), 100)))
    return views


def render_sheet(
    rows: list[tuple[str, list[tuple[str, np.ndarray]], int, bool]],
    title: str,
    target: Path,
    quality: int = 82,
) -> None:
    columns = [name for name, _ in rows[0][1]]
    widths = [fit(view, TILE_HEIGHT).width for _, view in rows[0][1]]
    row_width = sum(width + GUTTER for width in widths) - GUTTER
    width = MARGIN * 2 + LABEL_WIDTH + row_width
    header = 74
    row_height = TILE_HEIGHT + 30
    height = header + len(rows) * row_height + MARGIN

    sheet = Image.new("RGB", (width, height), PAPER)
    draw = ImageDraw.Draw(sheet)
    title_font, head_font, name_font, small_font = (
        load_font(19, bold=True), load_font(12, bold=True), load_font(13), load_font(11)
    )

    draw.text((MARGIN, MARGIN), title, font=title_font, fill=INK)

    x = MARGIN + LABEL_WIDTH
    for column, tile_width in zip(columns, widths):
        draw.text((x, MARGIN + 36), column.upper(), font=head_font, fill=MUTED)
        x += tile_width + GUTTER

    y = header
    for name, views, violations, opaque in rows:
        draw.line([(MARGIN, y - 6), (width - MARGIN, y - 6)], fill=RULE)
        draw.text((MARGIN, y + 6), name[:26], font=name_font, fill=INK)
        if violations:
            note, tint = f"{violations:,} px off 255", NEAR_COLOR
        elif opaque:
            note, tint = "no transparency anywhere", FULL_COLOR
        else:
            note, tint = "clean", MUTED
        draw.text((MARGIN, y + 26), note, font=small_font, fill=tint)
        x = MARGIN + LABEL_WIDTH
        for _, view in views:
            tile = fit(view, TILE_HEIGHT)
            sheet.paste(tile, (x, y))
            x += tile.width + GUTTER
        y += row_height

    if target.suffix.lower() in (".jpg", ".jpeg"):
        sheet.save(target, quality=quality, subsampling=2, optimize=True)
    else:
        sheet.save(target, optimize=True)


def write_index(
    outdir: Path,
    stem: str,
    sheets: list[Path],
    rows: list[tuple[str, list[tuple[str, np.ndarray]], int, bool]],
    args: argparse.Namespace,
) -> Path:
    """A scrollable index of the sheets, so review does not mean opening 15 PNGs."""
    dirty = [(name, violations) for name, _, violations, _ in rows if violations]
    opaque = [name for name, _, _, blocked in rows if blocked]
    parts = [
        "<!doctype html><meta charset='utf-8'>",
        f"<title>Overlay proof sheets - {args.orientation} {args.plane}</title>",
        "<style>",
        "body{margin:0;background:#f7f9f8;color:#1c2021;",
        "font:14px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}",
        "main{max-width:1500px;margin:0 auto;padding:28px 20px 64px}",
        "h1{font-size:22px;margin:0 0 4px} p{margin:0 0 14px;color:#5c6b6b}",
        "img{width:100%;height:auto;display:block;margin:0 0 22px;",
        "border:1px solid #d6dedc;border-radius:5px;background:#fff}",
        "ul{margin:0 0 20px;padding-left:18px;columns:3;font-size:13px}",
        "code{font-family:ui-monospace,Menlo,monospace}",
        ".bad{color:#a8471a}",
        "</style><main>",
        f"<h1>Overlay proof sheets</h1>",
        f"<p><code>{args.orientation}</code> orientation, <code>{args.plane}</code> plane, "
        f"{len(rows)} titles across {len(sheets)} sheets. "
        f"Columns: artwork over a checkerboard, the three-class alpha map, the overlay "
        f"with the beam off, a full-white raster at 100% ambient, and the same at 30% "
        f"ambient. In the alpha map, cream is clear, teal is a partial filter, "
        f"orange is a full filter (alpha 255, where the beam takes the artwork's "
        f"own colour) and red is a body that should be 255 and is not.</p>",
    ]
    if dirty:
        parts.append(f"<p class='bad'>{len(dirty)} titles break the contract:</p><ul>")
        parts += [f"<li>{name} - {count:,} px</li>" for name, count in dirty]
        parts.append("</ul>")
    if opaque:
        parts.append(f"<p class='bad'>{len(opaque)} titles are fully opaque:</p><ul>")
        parts += [f"<li>{name}</li>" for name in opaque]
        parts.append("</ul>")
    parts += [f"<img src='{sheet.name}' alt='{sheet.stem}' loading='lazy'>" for sheet in sheets]
    parts.append("</main>")

    target = outdir / f"{stem}.html"
    target.write_text("\n".join(parts))
    print(f"{target.name}: index for {len(sheets)} sheets")
    return target


def main() -> int:
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("art", type=Path, help="directory of .art packages")
    parser.add_argument("-o", "--outdir", type=Path, required=True)
    parser.add_argument("--orientation", choices=("normal", "90CW", "90CCW"), default="normal")
    parser.add_argument("--plane", choices=tuple(build_vart.RASTERS), default="1080p")
    parser.add_argument("--compare", type=Path, help="second .art directory to show beside it")
    parser.add_argument("--only", help="comma-separated title names")
    parser.add_argument("--rows", type=int, default=ROWS_PER_SHEET)
    parser.add_argument("--format", choices=("jpg", "png"), default="jpg",
                        help="jpg keeps a full set of sheets small enough to track")
    args = parser.parse_args()

    art = args.art if args.art.is_absolute() else repo / args.art
    outdir = args.outdir if args.outdir.is_absolute() else repo / args.outdir
    outdir.mkdir(parents=True, exist_ok=True)
    suffix = "" if args.orientation == "normal" else f"_{args.orientation}"

    names = sorted(
        {p.stem for p in art.glob("*.art") if "_90CW" not in p.stem and "_90CCW" not in p.stem}
    )
    if args.only:
        wanted = {n.strip() for n in args.only.split(",") if n.strip()}
        names = [n for n in names if n in wanted]
    if not names:
        parser.error("no packages found")

    rows: list[tuple[str, list[tuple[str, np.ndarray]], int, bool]] = []
    for name in names:
        package = art / f"{name}{suffix}.art"
        if not package.is_file():
            print(f"skipped {package.name}: missing", file=sys.stderr)
            continue
        try:
            plane = plane_rgba(package, args.plane)
        except Exception as error:  # noqa: BLE001
            print(f"skipped {package.name}: {error}", file=sys.stderr)
            continue
        other = None
        if args.compare:
            root = args.compare if args.compare.is_absolute() else repo / args.compare
            candidate = root / f"{name}{suffix}.art"
            if candidate.is_file():
                try:
                    other = plane_rgba(candidate, args.plane)
                except Exception:  # noqa: BLE001
                    other = None
        violations = int(rgba_ops.solid_body(plane[:, :, 3]).sum())
        opaque = bool(plane[:, :, 3].min() == rgba_ops.OPAQUE)
        rows.append((name, build_row(plane, other), violations, opaque))

    stem = f"proof_{args.orientation}_{args.plane}"
    pages = [rows[i:i + args.rows] for i in range(0, len(rows), args.rows)]
    written = []
    for number, page in enumerate(pages, 1):
        target = outdir / f"{stem}_{number:02d}.{args.format}"
        render_sheet(page, f"{args.orientation} · {args.plane} · sheet {number} of {len(pages)}", target)
        written.append(target)
        print(f"{target.name}: {len(page)} titles")

    write_index(outdir, stem, written, rows, args)
    dirty = [name for name, _, violations, _ in rows if violations]
    blocked = [name for name, _, _, opaque in rows if opaque]
    print(f"\n{len(rows)} titles, {len(dirty)} with contract violations, "
          f"{len(blocked)} fully opaque")
    if blocked:
        print("  opaque: " + ", ".join(blocked))
    if dirty:
        print("  " + ", ".join(dirty[:20]) + (" ..." if len(dirty) > 20 else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
