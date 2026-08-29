#!/usr/bin/env python3
"""Give every cartridge a same-named Normal .art copy so auto-load finds it.

Main's addon mechanism (the "f1,ART;" CONF_STR entry) loads
"<rom name>.art" from the ROM's own folder after a cartridge load, which
is how master's .OVR auto-load worked. This matches each ROM filename
against the generated overlay set and emits the copy commands.

Matching is by normalized title key: exact key match first, then unique
containment either way (so "pole" matches "Pole Position (1983)(GCE)"). Ambiguous
containment - a key that fits several overlays - is reported and skipped
rather than guessed.

Usage:
    name_for_roms.py --roms roms.txt [--art artwork/generated] [--sh out.sh]

roms.txt is one ROM filename per line (e.g. from
`ssh mister ls /media/fat/games/VECTREX/Games`). The emitted script
copies from the deployed overlay dir to the ROM dir; edit the two
prefixes at the top if the layout differs.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ART_PREFIX = "/media/fat/games/VECTREX"
ROM_PREFIX = "/media/fat/games/VECTREX/Games"


def title_key(stem: str) -> str:
    s = stem.lower()
    s = re.sub(r"(overlay|-vgo|_small|\(.*?\)|\[.*?\])", "", s)
    return re.sub(r"[^a-z0-9]", "", s)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--roms", type=Path, required=True,
                        help="file with one ROM filename per line")
    parser.add_argument("--art", type=Path, default=Path("artwork/generated"))
    parser.add_argument("--sh", type=Path, default=Path("-"),
                        help="write copy script here ('-' for stdout)")
    args = parser.parse_args()

    art = {}
    for p in sorted(args.art.glob("*.art")):
        if p.stem.endswith(("_90CW", "_90CCW")):
            continue
        k = title_key(p.stem)
        if k:
            art.setdefault(k, p.name)

    lines = []
    matched = skipped = ambiguous = 0
    for rom in args.roms.read_text().splitlines():
        rom = rom.strip()
        if not rom or not rom.lower().endswith((".bin", ".vec", ".rom")):
            continue
        stem = rom.rsplit(".", 1)[0]
        rk = title_key(stem)
        hit = art.get(rk)
        if hit is None:
            cands = {v for k, v in art.items()
                     if len(rk) >= 4 and (rk in k or k in rk)}
            if len(cands) == 1:
                hit = cands.pop()
            elif len(cands) > 1:
                print(f"AMBIGUOUS {rom}: {sorted(cands)}", file=sys.stderr)
                ambiguous += 1
                continue
        if hit is None:
            skipped += 1
            continue
        matched += 1
        lines.append(f"cp '{ART_PREFIX}/{hit}' '{ROM_PREFIX}/{stem}.art'")

    out = "\n".join(lines) + "\n"
    if str(args.sh) == "-":
        sys.stdout.write(out)
    else:
        args.sh.write_text(out)
    print(f"{matched} matched, {skipped} without overlay, "
          f"{ambiguous} ambiguous", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
