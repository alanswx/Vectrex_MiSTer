#!/usr/bin/env python3
"""Batch game regression: vecx attract-mode references vs hardware captures.

Three subcommands:

  gen-refs   Render every catalog title's hands-off attract sequence in
             vecx (tools/goldenref/vecbtn) to a per-game reference frame
             set. Uses the BIOS extracted from rtl/bios_rom.vhd so
             BIOS-dependent behavior matches the core. Offline.
  validate   Discrimination self-test, fully offline: one frame per game
             is scored against every game's reference set (its own exact
             frame excluded); reports top-1 accuracy and score margins.
             This is what justifies the pass threshold.
  run        The hardware sweep: launch each game on the MiSTer, capture
             framework screenshots, and score each against that game's
             reference set. A game passes when some capture matches some
             reference frame above threshold. TOUCHES THE MISTER - only
             run with the bench free.

Matching is structural (binarize + blur + normalize, from tc_sweep) with
an FFT cross-correlation peak searched over small translations. The
reference is a SET of frames sampled along the attract loop because
launch latency makes hardware phase unpredictable.

Frame sets live in refs/game_sweep/<slug>/ (gitignored). A manifest maps
slugs to local ROM and SD paths.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from tc_sweep import normbin, screenshot, BIOS_VHD, VECBTN  # noqa: E402

ROM_DIR = os.path.join(REPO, "refs/roms/sd")
SD_DIR = "/media/fat/games/VECTREX/Games"
REF_ROOT = os.path.join(REPO, "refs/game_sweep")
# attract sampling: past the BIOS announcement, ~0.83 s apart, ~70 s span
REF_FRAMES = list(range(420, 2520, 25))
SIZE = (128, 160)
SHIFT_MAX = 14


def slugify(title):
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")


def catalog():
    """One best dump per title: untagged beats [b]/[h]; shortest wins."""
    groups = {}
    for f in sorted(os.listdir(ROM_DIR)):
        if not f.endswith(".bin"):
            continue
        title = f.split(" (")[0]
        if "test" in title.lower():
            continue
        groups.setdefault(title, []).append(f)
    out = {}
    for title, files in groups.items():
        clean = [f for f in files if "[" not in f]
        pick = min(clean or files, key=len)
        if os.path.getsize(os.path.join(ROM_DIR, pick)) > 32768:
            continue                      # bank-switched; vecx can't run it
        out[slugify(title)] = {"title": title, "rom": pick,
                               "sd": f"{SD_DIR}/{pick}"}
    return out


def core_bios(dest):
    if not os.path.exists(dest):
        vals = re.findall(r'[xX]"([0-9a-fA-F]{2})"', open(BIOS_VHD).read())
        with open(dest, "wb") as f:
            f.write(bytes(int(v, 16) for v in vals))
    return dest


def gen_refs(games):
    os.makedirs(REF_ROOT, exist_ok=True)
    bios = core_bios(os.path.join(REF_ROOT, "core_bios.bin"))
    if not os.path.exists(VECBTN):
        subprocess.run(["make", "-C", os.path.dirname(VECBTN), "vecbtn"],
                       check=True)
    done = 0
    for slug, g in games.items():
        gdir = os.path.join(REF_ROOT, slug)
        if os.path.exists(os.path.join(gdir, "done")):
            done += 1
            continue
        os.makedirs(gdir, exist_ok=True)
        cmd = [VECBTN, "--bios", bios, "--cart",
               os.path.join(ROM_DIR, g["rom"]),
               "--until", str(REF_FRAMES[-1] + 5), "--out", gdir]
        for f in REF_FRAMES:
            cmd += ["--dump", str(f)]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        pgms = [f for f in os.listdir(gdir) if f.endswith(".pgm")]
        if r.returncode != 0 or len(pgms) < len(REF_FRAMES) // 2:
            print(f"  {slug}: FAILED to render ({len(pgms)} frames)")
            continue
        for p in pgms:
            Image.open(os.path.join(gdir, p)).save(
                os.path.join(gdir, p.replace(".pgm", ".png")))
            os.unlink(os.path.join(gdir, p))
        open(os.path.join(gdir, "done"), "w").close()
        done += 1
        print(f"  {slug}: {len(pgms)} frames")
    json.dump(catalog(), open(os.path.join(REF_ROOT, "manifest.json"), "w"),
              indent=1)
    print(f"{done}/{len(games)} reference sets ready in {REF_ROOT}")


# ---- matching ----------------------------------------------------------

def prep_fft(im):
    a = normbin(im, size=SIZE)
    return np.fft.rfft2(a), a.size


def peak_corr(capF, refF, n, m=SHIFT_MAX):
    """Peak of the cyclic cross-correlation within a +/-m shift window."""
    cc = np.fft.irfft2(capF * np.conj(refF), s=(SIZE[1], SIZE[0]))
    win = np.concatenate([r[np.r_[0:m + 1, -m:0]] for r in
                          cc[np.r_[0:m + 1, -m:0]]])
    return float(win.max() / n)


def mask_coverage(cap, ref, m=SHIFT_MAX):
    """Bidirectional whole-image coverage at the best small translation.

    Normalized correlation can match one local fragment while ignoring extra
    displaced copies. Keeping each image's full lit-pixel total in the
    denominator makes extra drawing reduce capture coverage and missing or
    clipped drawing reduce reference coverage.
    """
    def mask(im):
        a = np.asarray(im.convert("L").resize(SIZE, Image.BILINEAR), float)
        return a > max(8.0, a.max() * 0.15)

    c, r = mask(cap), mask(ref)
    cn, rn = int(c.sum()), int(r.sum())
    if not cn or not rn:
        return 0.0, 0.0, 0.0
    best_hit = 0
    for dy in range(-m, m + 1):
        for dx in range(-m, m + 1):
            cc = c[max(0, dy):c.shape[0] + min(0, dy),
                   max(0, dx):c.shape[1] + min(0, dx)]
            rr = r[max(0, -dy):r.shape[0] + min(0, -dy),
                   max(0, -dx):r.shape[1] + min(0, -dx)]
            best_hit = max(best_hit, int(np.count_nonzero(cc & rr)))
    return best_hit / cn, best_hit / rn, 2.0 * best_hit / (cn + rn)


class RefBank:
    def __init__(self, slugs=None):
        self.games = {}
        self.blank = []                 # nothing drawn hands-off: 3-D
        man = json.load(open(os.path.join(REF_ROOT, "manifest.json")))
        for slug in (slugs or man):     # imager titles, input-gated protos
            gdir = os.path.join(REF_ROOT, slug)
            if not os.path.exists(os.path.join(gdir, "done")):
                continue
            frames, lit = {}, 0
            for f in sorted(os.listdir(gdir)):
                if f.endswith(".png"):
                    im = Image.open(os.path.join(gdir, f))
                    lit += (np.asarray(im.convert("L")) > 30).any()
                    frames[f] = prep_fft(im)
            self.lit_frames = getattr(self, "lit_frames", {})
            self.lit_frames[slug] = int(lit)
            if lit:
                self.games[slug] = frames
            else:
                self.blank.append(slug)
        self.man = man
        if self.blank:
            print(f"skipping {len(self.blank)} title(s) with blank "
                  f"hands-off attract: {', '.join(self.blank)}")

    def score(self, im, slug, exclude=None):
        capF, n = prep_fft(im)
        best, best_f = -2.0, None
        for f, (refF, _) in self.games[slug].items():
            if f == exclude:
                continue
            r = peak_corr(capF, refF, n)
            if r > best:
                best, best_f = r, f
        return best, best_f


def pick_probe(slug, frames):
    """Most-lit reference frame - a blank mid-attract frame probes nothing."""
    best, best_f = -1.0, None
    for f in frames:
        a = np.asarray(Image.open(os.path.join(REF_ROOT, slug, f))
                       .convert("L"), float)
        lit = float((a > 30).mean())
        if lit > best:
            best, best_f = lit, f
    return best_f


def validate(threshold):
    """Pass criterion mirrors run mode: the probe must match the game's
    OWN reference set above threshold (exact frame excluded). Top-1 rank
    across the whole catalog is reported as diagnostics; same-game
    variants legitimately tie each other there."""
    bank = RefBank()
    slugs = list(bank.games)
    print(f"validating {len(slugs)} games...")
    ok_n, top1, margins = 0, 0, []
    for slug in slugs:
        probe = pick_probe(slug, sorted(bank.games[slug]))
        im = Image.open(os.path.join(REF_ROOT, slug, probe))
        own, _ = bank.score(im, slug, exclude=probe)
        rival, rival_slug = max(
            ((bank.score(im, s)[0], s) for s in slugs if s != slug))
        # a set with a single lit frame cannot self-match once that frame
        # is excluded; run mode has no exclusion, so count it usable
        ok = own > threshold or bank.lit_frames[slug] < 2
        ok_n += ok
        top1 += own >= rival
        margins.append(own - rival)
        flag = "" if own > threshold else (
            "  SINGLE-FRAME" if bank.lit_frames[slug] < 2 else "  WEAK-SELF")
        note = "" if own >= rival else f"  (top-1: {rival_slug} {rival:.2f})"
        print(f"  {slug:40s} self={own:.2f}{flag}{note}")
    print(f"\nself-match >{threshold}: {ok_n}/{len(slugs)}   "
          f"top-1: {top1}/{len(slugs)}   "
          f"median margin {np.median(margins):+.2f}")
    return 0 if ok_n == len(slugs) else 1


# ---- hardware run (touches the MiSTer) ---------------------------------

def launch(host, sd_path):
    import urllib.request
    req = urllib.request.Request(
        f"http://{host}:8182/api/games/launch",
        data=json.dumps({"path": sd_path}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(req, timeout=10).read()


def run(host, out, threshold, coverage, captures, only):
    bank = RefBank(only)
    os.makedirs(out, exist_ok=True)
    results = {}
    for slug in bank.games:
        g = bank.man[slug]
        print(f"{slug}: launching...", flush=True)
        launch(host, g["sd"])
        time.sleep(14)                   # BIOS announcement on hardware
        best_quality = -2.0
        best, best_png, best_cov = -2.0, None, (0.0, 0.0, 0.0)
        for k in range(captures):
            png = os.path.join(out, f"{slug}_{k}.png")
            screenshot(host, png)
            cap = Image.open(png)
            r, best_ref = bank.score(cap, slug)
            cov = mask_coverage(cap, Image.open(
                os.path.join(REF_ROOT, slug, best_ref)))
            quality = r * min(cov[0], cov[1])
            if quality > best_quality:
                best_quality, best, best_png, best_cov = quality, r, png, cov
            time.sleep(2.0)
        cap_cov, ref_cov, dice = best_cov
        ok = best > threshold and min(cap_cov, ref_cov) >= coverage
        results[slug] = (best, cap_cov, ref_cov, dice, ok, best_png)
        print(f"  {slug}: corr {best:.2f}  coverage "
              f"{cap_cov:.2f}/{ref_cov:.2f}  {'ok' if ok else 'FAIL'}")
    fails = [s for s, result in results.items() if not result[4]]
    print(f"\n{len(results) - len(fails)}/{len(results)} matched "
          f"(correlation {threshold}, coverage {coverage})")
    for s in fails:
        print(f"  FAIL {s}: corr {results[s][0]:.2f}, coverage "
              f"{results[s][1]:.2f}/{results[s][2]:.2f} ({results[s][5]})")
    json.dump({s: {"score": r, "capture_coverage": cc,
                   "reference_coverage": rc, "dice": dice, "ok": ok}
               for s, (r, cc, rc, dice, ok, _) in results.items()},
              open(os.path.join(out, "results.json"), "w"), indent=1)
    return 0 if not fails else 1


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("gen-refs")
    v = sub.add_parser("validate")
    v.add_argument("--threshold", type=float, default=0.4)
    r = sub.add_parser("run")
    r.add_argument("--host", default="192.168.1.75")
    r.add_argument("--out", default="game_sweep_out")
    r.add_argument("--threshold", type=float, default=0.4)
    r.add_argument("--coverage", type=float, default=0.48)
    r.add_argument("--captures", type=int, default=6)
    r.add_argument("--only", nargs="*", help="slugs to run (default all)")
    r.add_argument("--yes-touch-the-mister", action="store_true",
                   help="required: this mode launches cores on the bench")
    args = ap.parse_args()

    if args.cmd == "gen-refs":
        gen_refs(catalog())
        return 0
    if args.cmd == "validate":
        return validate(args.threshold)
    if not args.yes_touch_the_mister:
        ap.error("run mode drives the MiSTer; pass --yes-touch-the-mister "
                 "once the bench is free")
    return run(args.host, args.out, args.threshold, args.coverage, args.captures,
               args.only)


if __name__ == "__main__":
    sys.exit(main())
