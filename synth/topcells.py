#!/usr/bin/env python3
"""Rank the cells by count in a mapped netlist, and price them from the liberty.

    python3 synth/topcells.py synth/stat.txt [liberty.lib]

The `stat` block lists `<cell> <count>`; area comes from the liberty file's
`cell ... area :` field, so the ranking is real um2 and not a proxy.
"""

import re
import sys


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "synth/stat.txt"
    lib = sys.argv[2] if len(sys.argv) > 2 else None
    txt = open(path).read()

    counts = {
        name: int(n)
        for name, n in re.findall(r"^\s+(sky130_fd_sc_hd__\S+)\s+(\d+)\s*$", txt, re.M)
    }
    if not counts:
        print("no cell counts found", file=sys.stderr)
        return 1

    areas = {}
    if lib:
        cur, a = None, None
        for line in open(lib):
            m = re.match(r"\s*cell\s*\(\s*\"?([\w]+)\"?\s*\)", line)
            if m:
                cur = m.group(1)
                continue
            m = re.match(r"\s*area\s*:\s*([\d.]+)\s*;", line)
            if m and cur:
                areas[cur] = float(m.group(1))
                cur = None

    rows = []
    for name, n in counts.items():
        rows.append((n, n * areas.get(name, 0.0), name))
    rows.sort(key=lambda r: (-r[1], -r[0]))
    total_area = sum(a for _, a, _ in rows) or 1.0
    total_cells = sum(n for n, _, _ in rows)

    print(f"{'count':>6} {'area um2':>10} {'%':>6}  cell")
    for n, a, name in rows[:12]:
        short = name.replace("sky130_fd_sc_hd__", "")
        print(f"{n:6d} {a:10.1f} {100 * a / total_area:5.1f}%  {short}")

    print(f"\n{total_cells} cells, {total_area:.1f} um2 (liberty areas)")

    # family roll-up
    fam = {}
    for n, a, name in rows:
        short = name.replace("sky130_fd_sc_hd__", "")
        short = re.sub(r"_\d+$", "", short)
        fam[short] = fam.get(short, 0.0) + a
    print("\ntop families:")
    for k, v in sorted(fam.items(), key=lambda kv: -kv[1])[:8]:
        print(f"  {v:10.1f} um2 {100 * v / total_area:5.1f}%  {k}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
