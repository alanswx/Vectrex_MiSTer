#!/usr/bin/env python3
"""How far the beam moves between framebuffer writes.

vectrex.vhd writes at most one pixel per clken_12 tick, at the beam's current
position (see the phase machine around rtl/vectrex.vhd:534). So the renderer's
sampling adequacy comes down to one number per vector: pixels covered divided
by ticks spent.

  < 1   every pixel along the vector gets written; the line is solid
  > 1   the beam outruns the writer and the line comes out dashed

Well under 1 is not free either. It means many writes land on the same pixel,
which is what dac_ob compensates for by accumulating brightness and saturating
rather than modelling dwell time.

Needs a dump from sim/tb_vectrex.vhd carrying tick counts:

    x0 y0 x1 y1 z ticks

usage:
  beamspeed.py seg.txt [--frame N]
"""

import argparse
import collections
import sys

# From rtl/vectrex.vhd. Integrator X drives screen rows, Y drives columns.
MAX_X = 5625 * 4 * 8
MAX_Y = 5625 * 3 * 8
W, H = 540, 720


def load(path, frame=None):
    out, cur = [], 0
    for line in open(path):
        line = line.strip()
        if line.startswith("# frame"):
            cur = int(line.split()[-1])
            continue
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 6:
            continue                      # dump predates tick counts
        if frame is not None and cur != frame:
            continue
        x0, y0, x1, y1, z, ticks = (int(v) for v in parts)
        if ticks > 0:
            out.append((x0, y0, x1, y1, ticks))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump")
    ap.add_argument("--frame", type=int, default=None)
    args = ap.parse_args()

    segs = load(args.dump, args.frame)
    if not segs:
        print("no segments with tick counts; re-run the sim with a build that "
              "emits them")
        return 1

    hist = collections.Counter()
    total_px = total_ticks = gaps = 0
    worst = (0.0, None)

    for x0, y0, x1, y1, ticks in segs:
        rows = abs(x1 - x0) * H / (2 * MAX_X)
        cols = abs(y1 - y0) * W / (2 * MAX_Y)
        px = max(rows, cols)              # Chebyshev: pixels the line touches
        adv = px / ticks
        total_px += px
        total_ticks += ticks
        if adv > 1.0:
            gaps += 1
        if adv > worst[0]:
            worst = (adv, (px, ticks))
        hist[min(int(adv * 4), 12)] += 1

    n = len(segs)
    print(f"segments        {n}")
    print(f"vector length   {total_px:.0f} px over {total_ticks} ticks")
    print(f"mean advance    {total_px / total_ticks:.3f} px/tick "
          f"({total_ticks / max(total_px, 1):.1f} writes per pixel)")
    print(f"worst advance   {worst[0]:.3f} px/tick "
          f"({worst[1][0]:.1f}px over {worst[1][1]} ticks)")
    print(f"dashed vectors  {gaps} ({gaps / n:.2%}) advance more than 1 px/tick")

    print("\nadvance per write:")
    for k in sorted(hist):
        lo = k / 4
        label = f">{lo:.2f}" if k == 12 else f"{lo:.2f}-{(k + 1) / 4:.2f}"
        bar = "#" * max(1, int(60 * hist[k] / n))
        print(f"  {label:>11}  {hist[k]:6d}  {bar}")

    # Same content at a taller framebuffer scales the advance linearly, so this
    # says where point splatting stops being sufficient FOR THIS CONTENT. It is
    # not a general answer: a screen full of fast-moving vectors will move the
    # worst case, which is why this wants running against gameplay and not only
    # a static test pattern.
    print("\nprojected at other framebuffer heights (this content only):")
    for rows in (720, 1080, 1440, 2160):
        adv = worst[0] * rows / H
        print(f"  {rows:5d} rows   worst {adv:5.2f} px/tick   "
              f"{'solid' if adv < 1 else 'DASHED'}")
    if worst[0] > 0:
        print(f"\n  splatting stays solid up to ~{H / worst[0]:.0f} rows here")
    return 0


if __name__ == "__main__":
    sys.exit(main())
