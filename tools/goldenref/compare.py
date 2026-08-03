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
    segs, cur, seen_marker = [], 0, False
    for line in open(path):
        line = line.strip()
        if line.startswith("# frame"):
            seen_marker = True
            cur = int(line.split()[-1])
            continue
        if not line or line.startswith("#"):
            continue
        if frame is not None and seen_marker and cur != frame:
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
    args = ap.parse_args()

    f = load_fpga(args.fpga, args.frame)
    g = load_golden(args.golden)
    print(f"fpga   segments: {len(f)}")
    print(f"golden segments: {len(g)}")
    if not f or not g:
        print("nothing to compare")
        return 1

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
