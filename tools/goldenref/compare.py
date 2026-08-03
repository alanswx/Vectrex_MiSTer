#!/usr/bin/env python3
"""Compare FPGA-extracted beam segments against the vecx golden reference.

Renders both sides into the same 540x720 raster and reports how much of each
image the other one covers. Neither side is authoritative about exact pixels:
the point is to catch structural divergence such as missing vectors, wrong
orientation, or geometry that drifts across the screen.

  FPGA side   sim/tb_vectrex.vhd output, in integrator units
  golden side tools/goldenref/vecdump .vec output, in vecx units

Coordinate systems differ in more than scale. vectrex.vhd computes

    beam_v <= lim_x * video_height / (2*max_x)     -- integrator X drives ROWS
    beam_h <= lim_y * video_width  / (2*max_y)     -- integrator Y drives COLS

so the core's X axis is vertical and its Y axis is horizontal, the opposite of
vecx's convention. That swap is applied here rather than assumed away.

usage:
  compare.py --fpga seg.txt --golden frame0005.vec [--frame N] [--out cmp.png]
"""

import argparse
import struct
import sys
import zlib

W, H = 540, 720

# From rtl/vectrex.vhd
MAX_X = 5625 * 4 * 8      # 180000, integrator X full scale
MAX_Y = 5625 * 3 * 8      # 135000, integrator Y full scale

# From refs/vecx/vecx.h
ALG_MAX_X = 33000
ALG_MAX_Y = 41000

# The two full-scale conventions do not share an aspect ratio:
#
#   core   max_x / max_y     = 180000 / 135000 = 1.3333  (exactly 4:3, and it
#                                                         matches the 540x720
#                                                         framebuffer)
#   vecx   ALG_MAX_Y / ALG_MAX_X = 41000 / 33000 = 1.2424
#
# so normalising each against its own full scale stretches vecx by 1.0732
# relative to the core. Measured on the Test Cartridge title frame the two
# sides' height/width ratios differ by 1.0730, i.e. this factor accounts for
# all of it. It is a property of vecx's constants, not a geometry error in the
# core, so do not read an uncalibrated vertical mismatch as one.
ASPECT_SKEW = (MAX_X / MAX_Y) / (ALG_MAX_Y / ALG_MAX_X)   # 1.0732


def blank():
    return bytearray(W * H)


def draw(fb, x0, y0, x1, y1, c=255):
    """Additive Bresenham, clipped to the raster."""
    dx, sx = abs(x1 - x0), (1 if x0 < x1 else -1)
    dy, sy = -abs(y1 - y0), (1 if y0 < y1 else -1)
    err = dx + dy
    while True:
        if 0 <= x0 < W and 0 <= y0 < H:
            i = y0 * W + x0
            fb[i] = min(255, fb[i] + c)
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy


def load_fpga(path, frame=None):
    """Integrator units -> raster, following vectrex.vhd's own mapping."""
    # Segments before the first marker belong to frame 0, the partial period
    # between reset and the first 1/30s boundary. Treating "no marker seen
    # yet" as "matches any frame" silently added that block to every frame.
    segs, cur = [], 0
    for line in open(path):
        line = line.strip()
        if line.startswith("# frame"):
            cur = int(line.split()[-1])
            continue
        if not line or line.startswith("#"):
            continue
        if frame is not None and cur != frame:
            continue
        ix0, iy0, ix1, iy1, z = (int(v) for v in line.split())
        # integrator X -> row, integrator Y -> column
        r0 = (ix0 + MAX_X) * H // (2 * MAX_X)
        r1 = (ix1 + MAX_X) * H // (2 * MAX_X)
        c0 = (iy0 + MAX_Y) * W // (2 * MAX_Y)
        c1 = (iy1 + MAX_Y) * W // (2 * MAX_Y)
        segs.append((c0, r0, c1, r1, z))
    return segs


def load_golden(path):
    segs = []
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        x0, y0, x1, y1, z = (int(v) for v in line.split())
        segs.append((x0 * W // ALG_MAX_X, y0 * H // ALG_MAX_Y,
                     x1 * W // ALG_MAX_X, y1 * H // ALG_MAX_Y, z))
    return segs


def render(segs):
    fb = blank()
    for x0, y0, x1, y1, _ in segs:
        draw(fb, x0, y0, x1, y1)
    return fb


def bbox(segs):
    xs = [v for s in segs for v in (s[0], s[2])]
    ys = [v for s in segs for v in (s[1], s[3])]
    return min(xs), min(ys), max(xs), max(ys)


def calibrate(src, ref):
    """Fit a per-axis scale+offset taking src onto ref by matching extents.

    vecx's 33000x41000 space and the core's +/-180000 x +/-135000 are
    independent conventions, chosen so that a typical image fills the screen
    but with no guarantee the two agree on gain or centre. Comparing raw
    normalised coordinates therefore measures the difference between two
    arbitrary scales, not the renderer's geometry error. Aligning extents
    first removes that, so what is left is the part worth looking at:
    non-uniform stretch, rotation, and per-vector drift.

    This assumes both sides drew the same outermost figure, which holds for
    frames with a full-screen border and not much else.
    """
    sx0, sy0, sx1, sy1 = bbox(src)
    rx0, ry0, rx1, ry1 = bbox(ref)
    sw, sh = (sx1 - sx0) or 1, (sy1 - sy0) or 1
    ax, ay = (rx1 - rx0) / sw, (ry1 - ry0) / sh
    bx, by = rx0 - sx0 * ax, ry0 - sy0 * ay
    out = [(x0 * ax + bx, y0 * ay + by, x1 * ax + bx, y1 * ay + by, z)
           for x0, y0, x1, y1, z in src]
    return [(int(round(a)), int(round(b)), int(round(c)), int(round(d)), z)
            for a, b, c, d, z in out], (ax, ay, bx, by)


def dilate(fb, r=2):
    """Widen strokes so near-misses count as agreement."""
    out = bytearray(W * H)
    for y in range(H):
        base = y * W
        for x in range(W):
            if fb[base + x]:
                for dy in range(-r, r + 1):
                    yy = y + dy
                    if 0 <= yy < H:
                        b2 = yy * W
                        for dx in range(-r, r + 1):
                            xx = x + dx
                            if 0 <= xx < W:
                                out[b2 + xx] = 255
    return out


def coverage(a, b_dil):
    """Fraction of lit pixels in a that fall within the dilated b."""
    lit = hit = 0
    for i in range(W * H):
        if a[i]:
            lit += 1
            if b_dil[i]:
                hit += 1
    return (hit / lit) if lit else 0.0, lit


def write_png(path, planes):
    """planes: list of (fb, (r,g,b)) composited into one RGB image."""
    rgb = bytearray(W * H * 3)
    for fb, (cr, cg, cb) in planes:
        for i in range(W * H):
            if fb[i]:
                j = i * 3
                rgb[j] = min(255, rgb[j] + cr)
                rgb[j + 1] = min(255, rgb[j + 1] + cg)
                rgb[j + 2] = min(255, rgb[j + 2] + cb)
    raw = b"".join(b"\x00" + bytes(rgb[y * W * 3:(y + 1) * W * 3]) for y in range(H))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw))
           + chunk(b"IEND", b""))
    open(path, "wb").write(png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fpga", required=True)
    ap.add_argument("--golden", required=True)
    ap.add_argument("--frame", type=int, default=None,
                    help="only use this frame from the FPGA dump")
    ap.add_argument("--out", default=None, help="write an overlay PNG")
    ap.add_argument("--calibrate", action="store_true",
                    help="align extents first, so the residual reflects "
                         "geometry rather than the two arbitrary scales")
    args = ap.parse_args()

    f = load_fpga(args.fpga, args.frame)
    g = load_golden(args.golden)
    # Raw counts are not comparable. A 1/30s window spans about 1.67 display
    # redraws, and vecx collapses repeats via a hash on exact coordinates
    # (alg_addline). The core's integrator units are fine enough that its own
    # repeats differ slightly, so nothing collapses until both are quantised
    # to pixels. On a static screen that takes the ratio from 2.16 to 1.26.
    fq = {s[:4] for s in f}
    gq = {s[:4] for s in g}
    print(f"fpga   segments: {len(f):5d}  ({len(fq)} distinct at pixel resolution)")
    print(f"golden segments: {len(g):5d}  ({len(gq)} distinct at pixel resolution)")
    if not f or not g:
        print("nothing to compare")
        return 1

    if args.calibrate:
        f, (ax, ay, bx, by) = calibrate(f, g)
        print(f"calibration: x*{ax:.4f}{bx:+.1f}   y*{ay:.4f}{by:+.1f}")

    fa, ga = render(f), render(g)
    fcov, flit = coverage(fa, dilate(ga))
    gcov, glit = coverage(ga, dilate(fa))
    print(f"fpga   lit pixels: {flit:6d}   covered by golden: {fcov:6.1%}")
    print(f"golden lit pixels: {glit:6d}   covered by fpga:   {gcov:6.1%}")

    if args.out:
        # red = fpga only, green = golden only, yellow = both
        write_png(args.out, [(fa, (255, 0, 0)), (ga, (0, 255, 0))])
        print(f"wrote {args.out}  (red=fpga, green=golden, yellow=agreement)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
