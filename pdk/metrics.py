#!/usr/bin/env python3
"""Render a LibreLane `metrics.json` into the signoff table.

    python3 pdk/metrics.py <run-dir>

The point is to read the flow's OWN numbers rather than a summary someone
wrote from memory: area, cell count, wirelength, DRC, LVS, and setup/hold
slack per corner.
"""

import json
import sys


def fmt(v):
    if isinstance(v, float):
        if abs(v) >= 1000:
            return f"{v:,.1f}"
        return f"{v:.4g}"
    return str(v)


def pick(d, *keys):
    for k in keys:
        if k in d:
            return d[k], k
    # fall back to a suffix match
    for k, v in d.items():
        for want in keys:
            if k.endswith(want):
                return v, k
    return None, None


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "final/metrics.json"
    d = json.load(open(path))

    rows = [
        ("die area (um2)", ("design__die__area",)),
        ("core area (um2)", ("design__core__area",)),
        ("instances", ("design__instance__count",)),
        ("instance area (um2)", ("design__instance__area",)),
        ("wirelength (um)", ("route__wirelength",)),
        ("DRC errors", ("route__drc_errors", "design__drc_error__count")),
        ("LVS errors", ("design__lvs_error__count", "design__lvs_unmatched__count")),
        ("setup WS (ns)", ("timing__setup__ws",)),
        ("setup TNS (ns)", ("timing__setup__tns",)),
        ("hold WS (ns)", ("timing__hold__ws",)),
        ("hold TNS (ns)", ("timing__hold__tns",)),
        ("max slew violations", ("design__max_slew_violation__count",)),
        ("max cap violations", ("design__max_cap_violation__count",)),
        ("max fanout violations", ("design__max_fanout_violation__count",)),
    ]

    for label, keys in rows:
        v, k = pick(d, *keys)
        if v is None:
            continue
        print(f"{label:24s} {fmt(v):>14s}   [{k}]")

    # per-corner timing, if the flow recorded it
    prefix = "timing__setup__ws__"
    corners = sorted(k[len(prefix):] for k in d if k.startswith(prefix))
    if corners:
        print("\nper-corner setup WS:")
        for c in corners:
            print(f"  {c:20s} {fmt(d[prefix + c])}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
