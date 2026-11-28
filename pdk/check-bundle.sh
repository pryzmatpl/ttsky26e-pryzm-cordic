#!/usr/bin/env bash
# Gate the committed bundle against the RTL.
#
#   ./pdk/check-bundle.sh
#
# Why this exists: on 2026-11-28 `tt_submission/` was regenerated from a flow
# run that had not finished cleanly. The result passed a file-existence check
# and DRC/LVS/STA (all of which compare a design against itself), and the GDS
# read back as a plausible die — but the netlist inside it was not the CORDIC.
# It had 187 logic cells and 25 flip-flops, and every `uo_out` bit was driven
# by a `conb_1` tie cell. A 34-bit accumulator cannot be built from 25 flops.
#
# That is also the whole answer to "why is the GDS 2.6 MB instead of 7.7 MB?",
# which is a question about which build got packed, not about optimisation.
#
# So this checks the bundle is the design, not merely well-formed:
#   - the netlist has the flip-flops the RTL needs (>= 300, one build had 25)
#   - the netlist has the logic cells the RTL needs (>= 1000)
#   - no top-level output is tied to a constant from a tie cell
#   - the GDS instance count agrees with the netlist's
#
# Exit 0 only when all four hold.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
cd "$ROOT"

python3 - <<'PY'
import re
import struct
import sys
from pathlib import Path

TOP = "tt_um_pryzm_cordic"
NETLIST = Path(f"tt_submission/{TOP}.v")
GDS = Path(f"tt_submission/{TOP}.gds")

# Thresholds are deliberately loose. They are not a size measurement: they are
# the line between "a design" and "a stub that ties its outputs off". The
# broken bundle on 2026-11-28 had 187 logic / 25 flops; the real design has
# ~4,800 logic / ~340 flops. Anything near either threshold is a packaging bug.
MIN_LOGIC = 1000
MIN_FLOPS = 300

failures = []

for f in (NETLIST, GDS):
    if not f.exists():
        print(f"missing: {f}")
        sys.exit(1)

text = NETLIST.read_text(errors="replace")

if not re.search(rf"^\s*module\s+{TOP}\b", text, re.M):
    failures.append(f"netlist has no module {TOP}")

cells = re.findall(r"^\s*(sky130_fd_sc_hd__\w+)", text, re.M)
physical = {"decap", "fill", "tap"}
logic = [c for c in cells if not any(p in c for p in physical)]
flops = [c for c in cells if re.search(r"df[xr]|sdf", c)]

print(f"netlist   : {len(cells):6d} instances, {len(logic):5d} logic, {len(flops):4d} flops")
if len(logic) < MIN_LOGIC:
    failures.append(
        f"only {len(logic)} logic cells (need >= {MIN_LOGIC}): the bundle is a stub, not the design")
if len(flops) < MIN_FLOPS:
    failures.append(
        f"only {len(flops)} flip-flops (need >= {MIN_FLOPS}): a 34-bit accumulator cannot fit in these")

# A tie cell on an output means the port is a constant. That is the signature
# of packing a run whose logic was optimised away.
tie_outputs = []
for m in re.finditer(r"(sky130_fd_sc_hd__conb_1)\s+\S+\s*\(([^;]*?)\);", text, re.S):
    ports = dict(re.findall(r"\.(\w+)\(([^)]*)\)", m.group(2)))
    net = (ports.get("HI") or ports.get("LO") or "").strip()
    if not net:
        continue
    if re.search(rf"assign\s+uo_out\[\d\]\s*=\s*{re.escape(net)}\s*;", text):
        tie_outputs.append(net)
if tie_outputs:
    failures.append(
        f"top-level uo_out driven by a constant tie cell ({', '.join(tie_outputs)}): "
        "the packed design computes nothing")

# The GDS must be the physical form of the same netlist. Instance counts differ
# by the artefacts each side counts (fill/tap), so compare SREFs to instances
# with a tolerance rather than a hash.
d = GDS.read_bytes()
i = 0
srefs = 0
structs = []
while i + 4 <= len(d):
    ln, rt, _ = struct.unpack(">HBB", d[i:i + 4])
    if ln < 4:
        failures.append(f"GDS record length {ln} at byte {i}: file is corrupt")
        break
    if rt == 0x12:  # SNAME
        srefs += 1
    elif rt == 0x06:  # STRNAME
        structs.append(d[i + 4:i + ln].rstrip(b"\0").decode("latin1"))
    elif rt == 0x04:  # ENDLIB
        if i + ln != len(d):
            failures.append(f"GDS has {len(d) - (i + ln)} trailing bytes after ENDLIB")
        break
    i += ln
else:
    failures.append("GDS has no ENDLIB record: file is truncated")

if TOP not in structs:
    failures.append(f"GDS has no top cell {TOP}")

print(f"gds       : {len(d):,} B, {len(structs)} structures, {srefs:,} placements")
if cells and abs(srefs - len(cells)) > max(10, len(cells) // 100):
    failures.append(
        f"GDS places {srefs:,} cells but the netlist has {len(cells):,}: "
        "they are not the same build")

print()
if failures:
    print("RESULT: BUNDLE IS NOT THE DESIGN")
    for f in failures:
        print(f"  - {f}")
    print()
    print("Regenerate from a finished run: python3 pdk/tt-submission.py")
    sys.exit(1)

print("RESULT: bundle matches the design")
PY
