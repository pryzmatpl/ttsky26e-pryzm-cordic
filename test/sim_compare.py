#!/usr/bin/env python3
"""Compare `src/project.v` (through Icarus) against the golden model.

This is the development loop: seconds per run, no cocotb.

Two ways to run it:

  * on a host that has `iverilog` on PATH — plain `python3 test/sim_compare.py`
  * inside the simulation container — `./test/run.sh [N]`

`test/run.sh` exports the tree into a named Docker volume first, because the
daemon lives on the host while this tree lives in the gateway container; a
bind mount of the gateway path would arrive empty.

Usage:
    python3 test/sim_compare.py [--vectors N] [--defect]
"""

import argparse
import os
import random
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "model"))
import cordic16 as M  # noqa: E402

NAMES = {0: "sincos", 1: "atan2", 2: "hypot", 3: "mul"}


def expected(op, a, b):
    if op == 0:
        sn, cs = M.sincos(a)
        return [sn & 0xFFFF, cs & 0xFFFF]
    if op == 1:
        return [M.atan2(a, b) & 0xFFFF]      # operands are (y, x) = (a, b)
    if op == 2:
        return [M.hypot(a, b) & 0xFFFF]
    return [M.mul(a, b) & 0xFFFF]


def build_vectors(n):
    random.seed(20261127)
    v = []
    for _ in range(n):
        v.append((0, random.randint(-32767, 32767), 0))
        v.append((1, random.randint(-32767, 32767), random.randint(-32767, 32767)))
        v.append((2, random.randint(-32767, 32767), random.randint(-32767, 32767)))
        v.append((3, random.randint(-32767, 32767), random.randint(-32767, 32767)))

    # Small-magnitude vectoring: where a relative algorithm has the least
    # absolute resolution, and where a prescale bug hides first.
    for x in range(-40, 41, 3):
        for y in range(-40, 41, 3):
            if x == 0 and y == 0:
                continue
            v.append((1, y, x))
            v.append((2, y, x))

    # Every phase, coarsely, plus the exact corners.
    for ph in range(-32768, 32768, 257):
        v.append((0, ph, 0))

    v += [
        (0, 0, 0), (0, 8192, 0), (0, 16384, 0), (0, -8192, 0), (0, 32767, 0),
        (0, -32768, 0), (0, 12345, 0), (0, -12345, 0),
        (1, 0, 32767), (1, 32767, 0), (1, 0, -32767), (1, -32767, 0),
        (1, 1, 1), (1, -1, -1), (1, 1, -1), (1, -1, 1),
        (2, 0, 32767), (2, 23170, 23170), (2, 3, 4),
        (3, 16384, 16384), (3, -32768, 32767), (3, 0, 1234),
    ]
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vectors", type=int, default=50)
    ap.add_argument("--defect", action="store_true",
                    help="flip one result bit, to prove the check can fail")
    ap.add_argument("--keep", action="store_true",
                    help="keep the work directory")
    args = ap.parse_args()

    if shutil.which("iverilog") is None:
        print("iverilog not found. Use ./test/run.sh (runs it in the container),"
              " or install iverilog.", file=sys.stderr)
        return 2

    work = os.path.join(ROOT, "test", "simwork")
    os.makedirs(work, exist_ok=True)
    src = os.path.join(ROOT, "src", "project.v")
    tb = os.path.join(HERE, "tb_sim.v")

    vecs = build_vectors(args.vectors)
    with open(os.path.join(work, "vectors.txt"), "w") as f:
        for op, a, b in vecs:
            f.write(f"{op} {a} {b}\n")

    rc = subprocess.run(["iverilog", "-g2012", "-o", "sim.vvp", tb, src],
                        cwd=work, capture_output=True, text=True)
    if rc.returncode != 0:
        print(rc.stdout, rc.stderr)
        return 1

    rc = subprocess.run(["vvp", "sim.vvp"], cwd=work, capture_output=True, text=True)
    if rc.returncode != 0:
        print(rc.stdout, rc.stderr)
        return 1

    rows = [ln.split() for ln in
            open(os.path.join(work, "results.txt")).read().split("\n") if ln.strip()]
    if len(rows) != len(vecs):
        print(f"vector count mismatch: sent {len(vecs)}, got {len(rows)}")
        return 1

    if args.defect:
        rows[0][3] = str(int(rows[0][3]) ^ 0x0001)

    fails = 0
    per_op = {}
    for (op, a, b), row in zip(vecs, rows):
        got0, got1 = int(row[3]), int(row[4])
        exp = expected(op, a, b)
        want1 = exp[1] if len(exp) > 1 else 0
        ok = got0 == exp[0] and got1 == want1
        st = per_op.setdefault(NAMES[op], [0, 0])
        st[0 if ok else 1] += 1
        if not ok:
            fails += 1
            if fails <= 12:
                print(f"FAIL {NAMES[op]:6s} a={a:6d} b={b:6d}  "
                      f"got={got0:#06x},{got1:#06x}  want={exp[0]:#06x},{want1:#06x}")

    print()
    for name, (ok, bad) in per_op.items():
        print(f"  {name:6s} {ok:5d} pass {bad:5d} fail")
    total = sum(sum(v) for v in per_op.values())
    print(f"\n{total - fails}/{total} vectors exact ({fails} fail)")

    if not args.keep:
        shutil.rmtree(work, ignore_errors=True)
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
