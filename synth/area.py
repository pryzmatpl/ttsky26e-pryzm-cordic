#!/usr/bin/env python3
"""Parse a yosys `stat` dump and report area against the tile budget.

    python3 synth/area.py synth/stat.txt

The tile figures are Tiny Tapeout's own: one tile is 167 x 108 um. The
comparison is to the *whole* tile, which is deliberately generous — the pad
ring, the multiplexer and the routing consume roughly a third of it, so a core
using more than ~60 % is a warning, not a pass.
"""

import re
import sys

TILE_W, TILE_H = 167.0, 108.0


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "synth/stat.txt"
    txt = open(path).read()

    def grab(pattern, cast=float):
        m = re.search(pattern, txt)
        return cast(m.group(1)) if m else None

    cells = grab(r"Number of cells:\s+(\d+)", int)
    area = grab(r"Chip area for module[^:]*:\s+([\d.]+)")
    seq = grab(r"of which used for sequential elements:\s+([\d.]+)")

    if area is None:
        print("could not find 'Chip area' in the stat file", file=sys.stderr)
        return 1

    print(f"cells      : {cells:,}" if cells else "cells      : ?")
    print(f"core area  : {area:.1f} um2")
    if seq is not None:
        print(f"sequential : {seq:.1f} um2 ({100 * seq / area:.1f} % of core)")

    for name, mult in (("1x1", 1), ("1x2", 2), ("2x2", 4)):
        w = TILE_W * (2 if mult == 4 else 1)
        h = TILE_H * (2 if mult in (2, 4) else 1)
        avail = w * h
        pct = 100 * area / avail
        verdict = "fits" if pct < 60 else ("tight" if pct < 85 else "does NOT fit")
        print(f"  {name}: {avail:7.0f} um2  core = {pct:5.1f} %  -> {verdict}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
