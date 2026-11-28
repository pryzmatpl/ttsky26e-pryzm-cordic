#!/usr/bin/env python3
"""Build the `tt_submission/` artifact locally, exactly as the shuttle does.

The shuttle's `tt_tool.py --create-tt-submission` packs a specific file set:
the GDS, a KLayout-converted OAS with the TT_PDK property, the LEF, the
gate-level netlist, SPEF corner files, metrics and synthesis stats. Its CI
produces this and uploads it, and the submission checker on
app.tinytapeout.com looks for it by commit.

Without a GitHub token we cannot make the shuttle's own job run, so this
reproduces the same bundle from a local LibreLane run. That is not a
substitute for the shuttle's run — the file is produced by a different
LibreLane version and does not include the mux/pad-ring assembly — and
`docs/EVIDENCE.md` says so. It is enough to inspect what the artifact will
contain and to check our run has every input the packer expects.

    python3 pdk/tt-submission.py [--out DIR] [--vol tt26e-sim]

Prints each expected input, whether it exists, and writes the bundle.
"""

import argparse
import json
import os
import subprocess
import sys

RUN = "pdk/runs/tt26e"
TOP = "tt_um_pryzm_cordic"


def sh(cmd: str) -> str:
    return subprocess.run(["sh", "-lc", cmd], capture_output=True, text=True).stdout


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="tt_submission")
    ap.add_argument("--vol", default="tt26e-sim")
    ap.add_argument("--tag", default="tt26e")
    args = ap.parse_args()

    run = f"pdk/runs/{args.tag}"
    final = f"{run}/final"

    # What create_tt_submission() copies, in its order.
    expected = [
        (f"{final}/gds/{TOP}.gds", "the streamed layout"),
        (f"{final}/lef/{TOP}.lef", "the design abstract"),
        (f"{final}/nl/{TOP}.nl.v", "gate-level netlist (sky130 uses PnL)"),
        (f"{final}/pnl/{TOP}.pnl.v", "gate-level netlist (power-annotated)"),
        (f"{final}/metrics.csv", "all flow metrics"),
        (f"{final}/commit_id.json", "the commit the flow ran on"),
        (f"{run}/pdk.json", "PDK version record"),
        (f"{run}/resolved.json", "resolved config, every key that was used"),
    ]

    print("=== inputs the shuttle packer expects")
    present = {}
    for path, what in expected:
        found = sh(f"docker run --rm -v {args.vol}:/w alpine test -f /w/{path} && echo yes").strip()
        ok = found == "yes"
        present[path] = ok
        print(f"  {'OK  ' if ok else 'MISS'}  {path:48s} {what}")

    spef = sh(f"docker run --rm -v {args.vol}:/w alpine sh -lc 'ls /w/{final}/spef/*/*.spef 2>/dev/null | head -5'").strip()
    print(f"  {'OK  ' if spef else 'MISS'}  {final}/spef/*/*.spef" + ("" if spef else " corner parasitics"))

    # The one input that is not optional.
    if not present.get(f"{final}/gds/{TOP}.gds"):
        print()
        print("No GDS: the flow has not finished. Run ./pdk/flow.sh first.")
        return 1

    # A finished GDS is not enough: check the netlist next to it is the design.
    # On 2026-11-28 this bundle was regenerated from a run whose netlist had 187
    # logic cells and every uo_out bit tied to a tie cell, and that shipped.
    # The size question ("2.6 MB instead of 7.7 MB") was the symptom of exactly
    # this. Refuse to pack a stub.
    nl = subprocess.run(
        ["docker", "run", "--rm", "-v", f"{args.vol}:/w", "alpine",
         "cat", f"/w/{final}/nl/{TOP}.nl.v"], capture_output=True, text=True).stdout
    if not nl:
        print()
        print(f"No netlist at {final}/nl/{TOP}.nl.v: the run did not finish.")
        return 1
    import re as _re
    _cells = _re.findall(r"^\s*(sky130_fd_sc_hd__\w+)", nl, _re.M)
    _logic = [c for c in _cells if not any(p in c for p in ("decap", "fill", "tap"))]
    _flops = [c for c in _cells if _re.search(r"df[xr]|sdf", c)]
    if len(_logic) < 1000 or len(_flops) < 300:
        print()
        print(f"REFUSING to pack: netlist has {len(_logic)} logic cells and "
              f"{len(_flops)} flops — that is a stub, not this design.")
        print("The flow's netlist was optimised away or the run did not finish.")
        print("Re-run ./pdk/flow.sh and check pdk/runs/tt26e/final/metrics.json.")
        return 1
    print(f"  netlist OK: {len(_logic)} logic cells, {len(_flops)} flops")

    out = os.path.abspath(args.out)
    os.makedirs(os.path.join(out, "stats"), exist_ok=True)
    print()
    print(f"=== writing {out}")

    copies = [
        f"{final}/gds/{TOP}.gds",
        f"{final}/lef/{TOP}.lef",
        f"{final}/metrics.csv",
        f"{run}/pdk.json",
        f"{run}/resolved.json",
    ]
    for src in copies:
        base = os.path.basename(src)
        data = subprocess.run(
            ["docker", "run", "--rm", "-v", f"{args.vol}:/w", "alpine",
             "cat", f"/w/{src}"], capture_output=True)
        if data.returncode == 0 and data.stdout:
            open(os.path.join(out, base), "wb").write(data.stdout)
            print(f"  wrote {base} ({len(data.stdout)} bytes)")

    # gate-level netlist: prefer pnl (sky130), fall back to nl
    for kind in ("pnl", "nl"):
        data = subprocess.run(
            ["docker", "run", "--rm", "-v", f"{args.vol}:/w", "alpine",
             "cat", f"/w/{final}/{kind}/{TOP}.{kind}.v"], capture_output=True)
        if data.returncode == 0 and data.stdout:
            open(os.path.join(out, f"{TOP}.v"), "wb").write(data.stdout)
            print(f"  wrote {TOP}.v from {kind}")
            break

    # synthesis stats: the shuttle puts the yosys stat block in stats/
    stats = sh(f"docker run --rm -v {args.vol}:/w alpine sh -lc "
               f"'cat /w/{run}/*yosys-synthesis/reports/stat.rpt 2>/dev/null'")
    if stats.strip():
        open(os.path.join(out, "stats", "synthesis-stats.txt"), "w").write(stats)
        print("  wrote stats/synthesis-stats.txt")

    print()
    print("=== bundle")
    for root, _, files in os.walk(out):
        for f in sorted(files):
            p = os.path.join(root, f)
            print(f"  {os.path.relpath(p, out):45s} {os.path.getsize(p):>10,} B")

    # The same gate the repo runs, so a bundle cannot leave this script broken.
    gate = subprocess.run(["bash", "pdk/check-bundle.sh"], capture_output=True, text=True)
    print()
    print(gate.stdout.rstrip())
    if gate.returncode != 0:
        print("Bundle written but does NOT match the design — do not submit it.")
        return 1

    print()
    print("NOTE: the shuttle's own job also writes an .oas with the TT_PDK")
    print("property and the mux/pad-ring assembly. This bundle does not, so it")
    print("is evidence about our die, not a submission artifact.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
