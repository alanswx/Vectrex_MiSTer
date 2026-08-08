#!/usr/bin/env python3
"""Automated Test Cartridge sweep over the hardware loop.

Launches the rev 4 Test Cartridge on the MiSTer, walks every screen with
the uinput virtual pad (vpad.py, deployed at /media/fat/vpad.py), captures
a framework screenshot of each, and scores it:

  - screen identification: normalized cross-correlation against vecx
    reference renders (generated with tools/goldenref/vecbtn if missing).
    The walk is closed-loop: each step verifies the screen it landed on
    and re-presses when a press fell in one of the cart's dead windows
    (the scope screens and the sound test ignore buttons part-time).
  - checksum: the cart checksums the BIOS along with itself. The factory
    BIOS (vecx's rom.dat, crc32 ba13fb57) yields B796 - the value in the
    service manual; the Mine Storm bug-fix BIOS this core ships (crc32
    105afd6a, rtl/bios_rom.vhd) yields 6293. Both references are rendered
    and the capture must match the core-BIOS one, which makes this a
    BIOS-integrity check.
  - INTENSITY criteria (service manual p.19): lines 2-4 extinguished,
    line 5 visible, ladder graded and monotonic (the soft-knee check).

Usage: tc_sweep.py [--host 192.168.1.75] [--out DIR]
Exit code 0 = all checks pass.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CART = "/media/fat/games/VECTREX/Applications/Test rev4 (1982)(GCE)(proto).bin"
LOCAL_CART = os.path.join(REPO, "refs/roms/Test rev4 (1982)(GCE)(proto).bin")
VECX_BIOS = os.path.join(REPO, "refs/vecx/rom.dat")
BIOS_VHD = os.path.join(REPO, "rtl/bios_rom.vhd")
VECBTN = os.path.join(REPO, "tools/goldenref/vecbtn")

REF_FRAMES = {
    "grid": 550, "dac": 620, "intoff": 650, "checksum": 780,
    "deflect": 830, "cutoff": 900, "sound": 1000, "intensity": 1150,
    "focus": 1250, "dist1": 1350, "dist2": 1450, "keys": 1550,
}
VECX_PRESSES = ["600:8:8", "640:6:8", "660:6:8", "800:8:8", "950:8:8",
                "1050:8:8", "1200:8:8", "1300:8:8", "1400:8:8", "1500:8:8"]


def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def run_vecbtn(bios, out, dumps):
    cmd = [VECBTN, "--bios", bios, "--cart", LOCAL_CART,
           "--until", "1600", "--out", out]
    for p in VECX_PRESSES:
        cmd += ["--press", p]
    for f in dumps:
        cmd += ["--dump", str(f)]
    sh(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def gen_refs(refdir):
    os.makedirs(refdir, exist_ok=True)
    wanted = list(REF_FRAMES) + ["checksum_core"]
    if all(os.path.exists(f"{refdir}/{n}.png") for n in wanted):
        return
    if not os.path.exists(VECBTN):
        sh(["make", "-C", os.path.dirname(VECBTN), "vecbtn"])
    run_vecbtn(VECX_BIOS, refdir, REF_FRAMES.values())
    for n, f in REF_FRAMES.items():
        Image.open(f"{refdir}/f{f:05d}.pgm").save(f"{refdir}/{n}.png")
    # checksum render under the BIOS the core actually ships
    core_bios = os.path.join(refdir, "core_bios.bin")
    with open(core_bios, "wb") as f:
        vals = re.findall(r'[xX]"([0-9a-fA-F]{2})"', open(BIOS_VHD).read())
        f.write(bytes(int(v, 16) for v in vals))
    sub = os.path.join(refdir, "corebios")
    os.makedirs(sub, exist_ok=True)
    run_vecbtn(core_bios, sub, [REF_FRAMES["checksum"]])
    Image.open(f"{sub}/f{REF_FRAMES['checksum']:05d}.pgm").save(
        f"{refdir}/checksum_core.png")


def screenshot(host, dest):
    urllib.request.urlopen(
        urllib.request.Request(f"http://{host}:8182/api/screenshots",
                               method="POST"), timeout=10).read()
    time.sleep(1.5)
    shots = json.load(urllib.request.urlopen(
        f"http://{host}:8182/api/screenshots", timeout=10))
    path = sorted(shots, key=lambda e: e["modified"])[-1]["path"]
    url = (f"http://{host}:8182/api/screenshots/"
           + urllib.parse.quote(path, safe=""))
    with open(dest, "wb") as f:
        f.write(urllib.request.urlopen(url, timeout=10).read())


def vpad(host, *seq):
    sh(["ssh", f"root@{host}",
        "python3 /media/fat/vpad.py --hold 0.25 --gap 0 " + " ".join(seq)],
       stdout=subprocess.DEVNULL)


def norm(im, size=(128, 160)):
    a = np.asarray(im.convert("L").resize(size, Image.BILINEAR), float)
    a -= a.mean()
    s = a.std()
    return a / s if s > 0 else a


def normbin(im, size=(128, 160)):
    """Binarized, blurred, normalized: compares vector structure while
    ignoring the brightness model (the renderer grades lines the flat
    vecx render does not)."""
    a = np.asarray(im.convert("L").resize(size, Image.BILINEAR), float)
    b = (a > max(8.0, a.max() * 0.15)).astype(float)
    b = np.asarray(Image.fromarray((b * 255).astype("uint8"))
                   .filter(ImageFilter.GaussianBlur(1.5)), float)
    b -= b.mean()
    s = b.std()
    return b / s if s > 0 else b


def shiftcorr(cap, ref, m=14):
    """Peak correlation over small translations - capture framing and the
    vecx render do not align exactly."""
    best = -2.0
    for dy in range(-m, m + 1, 2):
        for dx in range(-m, m + 1, 2):
            c = cap[max(0, dy):cap.shape[0] + min(0, dy),
                    max(0, dx):cap.shape[1] + min(0, dx)]
            r = ref[max(0, -dy):ref.shape[0] + min(0, -dy),
                    max(0, -dx):ref.shape[1] + min(0, -dx)]
            v = float((c * r).mean())
            if v > best:
                best = v
    return best


class Walker:
    def __init__(self, host, refdir, outdir):
        self.host, self.refdir, self.outdir = host, refdir, outdir
        self.refs = {n: normbin(Image.open(f"{refdir}/{n}.png"))
                     for n in REF_FRAMES}
        self.shots = {}
        self.n = 0

    def identify(self, png):
        cap = normbin(Image.open(png))
        scored = sorted(((shiftcorr(cap, r), n)
                         for n, r in self.refs.items()), reverse=True)
        r, name = scored[0]
        return (name, r) if r > 0.3 else ("unknown", r)

    def matches(self, png, want, thr=0.38):
        cap = normbin(Image.open(png))
        return {n: shiftcorr(cap, self.refs[n]) for n in want
                if shiftcorr(cap, self.refs[n]) > thr}

    def capture(self):
        self.n += 1
        png = os.path.join(self.outdir, f"cap{self.n:02d}.png")
        screenshot(self.host, png)
        return png, *self.identify(png)

    def ensure(self, want, press=True, attempts=5, wait=1.2,
               press_on_retry=True):
        """Press (optionally) until the capture matches a screen in `want`
        above threshold; re-press on retries unless told not to."""
        got, r = "unknown", 0.0
        for _ in range(attempts):
            if press:
                vpad(self.host, "x")
                time.sleep(wait)
            png, got, r = self.capture()
            hit = self.matches(png, want)
            if hit:
                got = max(hit, key=hit.get)
                self.shots[got] = png
                return got, hit[got]
            press = press_on_retry
        raise RuntimeError(f"never reached {want}; last saw {got} ({r:.2f})")


def intensity_criteria(pngs):
    """Criteria over several captures of the same screen: a single frame
    catches each line at a different age since the beam drew it (intra-
    frame phosphor decay), so per-line brightness is the max across
    captures."""
    stack = [np.asarray(Image.open(p).convert("L"), float) for p in pngs]
    a = np.max(stack, axis=0)
    rows = a[:, 100:300].max(axis=1)
    cand = [r for r in range(3, len(rows) - 3)
            if rows[r] == rows[r - 3:r + 4].max() and rows[r] > 25]
    lines = []
    for r in cand:
        if lines and r - lines[-1] < 20:
            if rows[r] > rows[lines[-1]]:
                lines[-1] = r
        else:
            lines.append(r)
    peaks = [rows[r] for r in lines]
    ok_count = len(lines) == 14
    gaps = np.diff(lines)
    ok_gap = ok_count and gaps[0] > 2.5 * np.median(gaps)
    ramp = peaks[1:]
    ok_mono = all(ramp[i] <= ramp[i + 1] + 4 for i in range(len(ramp) - 1))
    ok_graded = ok_count and (max(ramp) - min(ramp)) > 40 and max(peaks) < 250
    return {"14 lines visible": ok_count,
            "lines 2-4 extinguished (gap)": bool(ok_gap),
            "ladder monotonic": ok_mono,
            "top graded, not clamped": bool(ok_graded)}, [round(p) for p in peaks]


def _prep_bin(im, size):
    a = np.asarray(im.convert("L").resize(size, Image.BILINEAR), float)
    a = (a > max(8.0, a.max() * 0.25)).astype(float)
    a -= a.mean()
    s = a.std()
    return a / s if s > 0 else a


def checksum_verdict(png, refdir):
    """Template-match only the four checksum digits - the rest of the
    screen is identical between BIOS variants. The digit box is located
    by diffing the two reference renders."""
    a = np.asarray(Image.open(f"{refdir}/checksum.png"), float)
    b = np.asarray(Image.open(f"{refdir}/checksum_core.png"), float)
    ys, xs = np.where(np.abs(a - b) > 30)
    box = (xs.min() - 4, ys.min() - 4, xs.max() + 5, ys.max() + 5)

    cap = Image.open(png)
    fx, fy = cap.width / 330.0, cap.height / 410.0
    cx0, cy0 = int(box[0] * fx) - 30, int(box[1] * fy) - 25
    cx1, cy1 = int(box[2] * fx) + 30, int(box[3] * fy) + 25
    W, H = 240, 60
    capn = _prep_bin(cap.crop((cx0, cy0, cx1, cy1)), (W, H))
    rw = int((box[2] - box[0]) * fx * W / (cx1 - cx0))
    rh = int((box[3] - box[1]) * fy * H / (cy1 - cy0))

    out = {}
    for label, ref in (("6293/core-bios", "checksum_core"),
                       ("B796/factory-bios", "checksum")):
        refn = _prep_bin(Image.open(f"{refdir}/{ref}.png").crop(box),
                         (rw, rh))
        best = -2.0
        for dy in range(0, H - rh, 2):
            for dx in range(0, W - rw, 2):
                best = max(best, float(
                    (capn[dy:dy + rh, dx:dx + rw] * refn).mean()))
        out[label] = best
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.1.75")
    ap.add_argument("--out", default="tc_sweep_out")
    args = ap.parse_args()

    refdir = os.path.join(args.out, "refs")
    os.makedirs(args.out, exist_ok=True)
    gen_refs(refdir)
    w = Walker(args.host, refdir, args.out)

    print("launching test cartridge...")
    req = urllib.request.Request(
        f"http://{args.host}:8182/api/games/launch",
        data=json.dumps({"path": CART}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(req, timeout=10).read()

    time.sleep(12)
    # boot wait: never press - a press on the grid would navigate away
    w.ensure({"grid"}, press=False, attempts=10, wait=2.0,
             press_on_retry=False)
    print("on the linearity grid; walking...")

    # the two scope screens accept presses only while their words show
    # (~3 s window every ~6 s); the proven open-loop chain crosses both,
    # and ensure() retries the whole tail if a press missed its window
    vpad(args.host, "x", "1.05", "x", "0.45", "x")
    time.sleep(5)                       # checksum forms
    w.ensure({"checksum"}, press=False)
    got, _ = w.ensure({"deflect", "cutoff"}, wait=0.8)
    if got == "deflect":                # auto-runs into the cutoff cycle
        w.ensure({"cutoff"}, press=False, wait=3.0)
    w.ensure({"sound"})
    w.ensure({"intensity"})
    int_shots = [w.shots["intensity"]]
    for k in (2, 3):                    # extra frames for the decay-proof max
        time.sleep(0.7)
        png = os.path.join(args.out, f"intensity_{k}.png")
        screenshot(args.host, png)
        int_shots.append(png)
    w.ensure({"focus"})
    w.ensure({"dist1"})
    w.ensure({"dist2"})
    w.ensure({"keys"})

    print(f"\n{'screen':10s} captured-as")
    fails = 0
    order = ["grid", "checksum", "deflect", "cutoff", "sound",
             "intensity", "focus", "dist1", "dist2", "keys"]
    for name in order:
        have = name in w.shots
        if name == "deflect" and not have:
            print(f"{name:10s} (skipped - auto-advanced)")
            continue
        fails += 0 if have else 1
        print(f"{name:10s} {os.path.basename(w.shots[name]) if have else 'MISSING'}")

    ck = checksum_verdict(w.shots["checksum"], refdir)
    best = max(ck, key=ck.get)
    ok = best.startswith("6293") and ck[best] > min(ck.values()) + 0.05
    fails += 0 if ok else 1
    print(f"\nchecksum: matches {best} "
          + " ".join(f"[{k} r={v:.2f}]" for k, v in ck.items())
          + ("  ok" if ok else "  FAIL"))

    crit, peaks = intensity_criteria(int_shots)
    print("\nINTENSITY criteria:")
    for k, v in crit.items():
        fails += 0 if v else 1
        print(f"  {k:30s} {'ok' if v else 'FAIL'}")
    print(f"  ladder peaks: {peaks}")

    print(f"\n{'PASS' if fails == 0 else f'{fails} FAILURE(S)'}")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
