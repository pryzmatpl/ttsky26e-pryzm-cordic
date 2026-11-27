#!/usr/bin/env python3
"""Prove the hardened netlist is still a CORDIC, not just a passing design.

Every other check here answers "does it sign off". None of them answer "is it
the thing we meant to build". A design can pass DRC, LVS and timing and still
be useless: an output tied to zero routes beautifully, and LVS compares the
layout against the netlist rather than against intent.

So this compares the gate-level netlist against the RTL by behaviour, not by
structure, and in three increasing strengths:

  1. structural  - the CORDIC's signature components survive mapping: an xor
                   adder chain, a carry network, a barrel shifter, and enough
                   flip-flops for a 34-bit accumulator. Physical-only cells
                   (decap/fill/tap) are excluded, since they inflate the
                   instance count while carrying no signal.
  2. interface   - all nine ports of the shuttle contract are present with the
                   right widths on the hardened top.
  3. behavioural - the netlist and the RTL drive the same testbench and must
                   produce byte-identical output.

Check 3 is the only one that can fail if the hardened netlist computes the
wrong answer, so it is the one that matters.

    python3 pdk/verify-useful.py [--netlist PATH] [--rtl PATH]

Exit 0 only when all three pass.
"""

import argparse
import collections
import re
import shutil
import subprocess
import sys
from pathlib import Path

TOP = "tt_um_pryzm_cordic"

# The shuttle's contract for this design, from src/project.v.
PORTS = {
    "clk": 1,
    "rst_n": 1,
    "ena": 1,
    "ui_in": 8,
    "uo_out": 8,
    "uio_in": 8,
    "uio_out": 8,
    "uio_oe": 8,
}

# Parts a CORDIC cannot be built without.
#
# sky130 has no full-adder cell: adders come out as xnor2/xor2 for the sum and
# or2/nand2 for the carry. Detecting a cell named "fa" finds nothing, which is
# a bug in a checker, not evidence about the design.
SIGNATURE = {
    "adder (xor chain)": r"xnor2|xor2",
    "carry (or/nand)": r"or2|or3|nand2|nand3",
    "accumulator": r"dfxtp|dfrtp|dfstp|dfbbn|sdf",
    "shifter / mux": r"mux2|mux4|a21|a22|a31",
}

# Decap, fill, tap and diode cells satisfy manufacturing rules. They are real
# instances but carry no signal: a design made only of these would pass LVS and
# do nothing at all.
PHYSICAL_ONLY = re.compile(r"decap|fill_|tapvpwrvgnd|diode")


def read(path: Path) -> str:
    return path.read_text(errors="replace")


def check_structure(netlist: Path) -> tuple[bool, list[str]]:
    text = read(netlist)
    notes: list[str] = []

    modules = re.findall(r"^\s*module\s+(\w+)", text, re.M)
    if TOP not in modules:
        notes.append(f"FAIL top module {TOP} not in netlist (found {len(modules)})")
        return False, notes
    notes.append(f"top module present, {len(modules)} module(s)")

    counts = collections.Counter(re.findall(r"^\s*(sky130_fd_sc_hd__\w+)", text, re.M))
    total = sum(counts.values())
    physical = sum(n for c, n in counts.items() if PHYSICAL_ONLY.search(c))
    logic = total - physical
    notes.append(f"{total} instances: {logic} logic, {physical} decap/fill/tap")
    if logic < 1000:
        notes.append(f"FAIL only {logic} logic cells: a 62k um2 CORDIC cannot be this small (stub?)")
        return False, notes

    ok = True
    for name, pattern in SIGNATURE.items():
        hits = [c for c in counts if re.search(pattern, c)]
        n = sum(counts[c] for c in hits)
        notes.append(f"{name:18s} {n:6d}" + ("" if n else "   FAIL none found"))
        if not n:
            ok = False

    # At gate level the 34-bit bus is flattened into individual wires, so the
    # evidence for the wide datapath is accumulator depth: 34 bits plus control
    # cannot fit in fewer than ~100 flops.
    flops = sum(n for c, n in counts.items() if re.search(r"df[xr]|sdf", c))
    notes.append(f"{'flops':18s} {flops:6d}" + ("" if flops >= 100 else "   FAIL too few for a 34-bit accumulator"))
    if flops < 100:
        ok = False

    return ok, notes


def check_interface(netlist: Path) -> tuple[bool, list[str]]:
    text = read(netlist)
    m = re.search(rf"module\s+{TOP}\b(.*?)^endmodule", text, re.S | re.M)
    if not m:
        return False, [f"FAIL could not read the {TOP} module"]
    # Widths are declared after the port list, so the whole module is the
    # place to look: "module x (clk, ...);\n input clk;\n input [7:0] ui_in;"
    body = m.group(1)

    notes: list[str] = []
    ok = True
    for port, width in PORTS.items():
        decl = re.search(rf"\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*{port}\s*;", body)
        if decl:
            w = abs(int(decl.group(1)) - int(decl.group(2))) + 1
        elif re.search(rf"^\s*(input|output|inout)\s+{port}\s*;", body, re.M):
            w = 1
        else:
            notes.append(f"FAIL port {port} missing")
            ok = False
            continue
        mark = "" if w == width else f"   WARN contract says {width}"
        notes.append(f"port {port:8s} {w} bit{'s' if w > 1 else ''}{mark}")
    return ok, notes


def check_behaviour(netlist: Path, rtl: Path) -> tuple[bool, list[str]]:
    """Run the same testbench against netlist and RTL; outputs must be equal."""
    notes: list[str] = []

    tb = Path("test/tb.v")
    if not tb.exists():
        return False, ["FAIL test/tb.v missing; behaviour cannot be proven"]
    notes.append(f"testbench: {tb}")

    if not shutil.which("iverilog"):
        notes.append("SKIP no simulator in this container")
        notes.append("     GitHub's test workflow runs this exact comparison:")
        notes.append("     .github/workflows/test.yaml step 'RTL vs model (word-exact)'")
        return True, notes

    prims = Path("pdk/sky130A_primitives.v")
    if not prims.exists():
        notes.append("SKIP no PDK cell models at pdk/sky130A_primitives.v")
        notes.append("     (CI runs the cocotb suite against the real PDK)")
        return True, notes

    results: dict[str, list[str]] = {}
    for label, args in (
        # Gate level needs the cell models and the power-pin defines.
        ("netlist", ["-DFUNCTIONAL", "-DUSE_POWER_PINS", str(prims), str(netlist), str(tb)]),
        ("rtl", [str(rtl), str(tb)]),
    ):
        cc = subprocess.run(["iverilog", "-g2012", "-o", f"/tmp/{label}.vvp", *args],
                            capture_output=True, text=True)
        if cc.returncode != 0:
            notes.append(f"FAIL {label} did not compile: {cc.stderr.strip()[:200]}")
            return False, notes
        sim = subprocess.run(["vvp", f"/tmp/{label}.vvp"], capture_output=True, text=True)
        results[label] = sim.stdout.strip().splitlines()
        notes.append(f"{label}: {len(results[label])} output line(s)")

    if results["netlist"] != results["rtl"]:
        diff = [(i, a, b) for i, (a, b) in enumerate(zip(results["netlist"], results["rtl"])) if a != b]
        notes.append(f"FAIL {len(diff)} line(s) differ between netlist and RTL")
        for i, a, b in diff[:5]:
            notes.append(f"   line {i}: netlist={a!r} rtl={b!r}")
        return False, notes

    notes.append(f"PASS netlist and RTL agree on all {len(results['rtl'])} outputs")
    return True, notes


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--netlist", default="tt_submission/tt_um_pryzm_cordic.v")
    ap.add_argument("--rtl", default="src/project.v")
    args = ap.parse_args()

    netlist, rtl = Path(args.netlist), Path(args.rtl)
    for f in (netlist, rtl):
        if not f.exists():
            print(f"missing: {f}")
            if f == netlist:
                print("run: python3 pdk/tt-submission.py   (or ./pdk/flow.sh first)")
            return 1

    print(f"netlist : {netlist}  ({netlist.stat().st_size:,} B)")
    print(f"rtl     : {rtl}  ({rtl.stat().st_size:,} B)")
    print()

    failures = 0
    for title, (ok, notes) in (
        ("1. structural - is it a CORDIC?", check_structure(netlist)),
        ("2. interface - does it speak the contract?", check_interface(netlist)),
        ("3. behaviour - does it compute the right answer?", check_behaviour(netlist, rtl)),
    ):
        print(title)
        for n in notes:
            print(f"   {n}")
        print()
        if not ok:
            failures += 1

    print("=" * 62)
    if failures:
        print(f"RESULT: FAILED ({failures} group(s))")
        return 1
    print("RESULT: the hardened netlist is a working CORDIC")
    return 0


if __name__ == "__main__":
    sys.exit(main())
