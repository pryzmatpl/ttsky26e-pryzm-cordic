#!/usr/bin/env bash
# The breadboard test, run against the netlist that actually ships.
#
#   ./test/run-selftest-gl.sh
#
# Why this is separate from run-selftest.sh: the RTL bench proves the LOGIC.
# This proves the HARDENED NETLIST still carries it — the same distinction that
# caught the stale-netlist incident on 2026-11-28, where a gate-level run
# reported 2/1976 vectors against a file from a previous flow run.
#
# Only ONE direction is meaningful here, and that is worth stating plainly.
# The expected words are baked into the netlist as a case statement, so
# "corrupt the ROM and watch it fail" is a test of the RTL, not of the netlist —
# `gen-selftest-rom.py --corrupt` rewrites src/selftest_rom.vh, which the
# already-synthesised netlist no longer reads. The corrupt leg stays in
# run-selftest.sh where it means something.
#
# What this run adds instead is the thing that matters for the kit: the verdict
# is reachable through the real placed-and-routed cells, on the real pinout,
# with the real power pins connected, and it HOLDS long enough for a human to
# look at the board.
#
# The sky130 cell models are vendored under pdk/models/ as gzip, so this needs
# neither docker nor network on the runner. Before that they were only reachable
# through the `photonip/cocotb` image, which is not published — CI failed with
# `pull access denied` and the step could never have passed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
NETLIST="${NETLIST:-tt_submission/tt_um_pryzm_cordic.v}"
MODELS="${MODELS:-$ROOT/pdk/models}"

[ -f "$ROOT/$NETLIST" ] || {
  echo "no hardened netlist at $NETLIST"
  echo "run: python3 pdk/tt-submission.py"
  exit 1
}

command -v iverilog >/dev/null 2>&1 || {
  echo "RESULT: SKIP — no iverilog here, so the netlist claim was NOT checked."
  echo "(apt-get install iverilog; CI's 'Install iverilog' step provides it.)"
  exit 2
}

# A GDS or netlist checked out through Git LFS without `lfs: true` is a 130-byte
# pointer file, and every check downstream then compares nothing to nothing.
if head -c 60 "$ROOT/$NETLIST" | grep -q "version https://git-lfs"; then
  echo "RESULT: FAIL — $NETLIST is a Git LFS pointer, not the file."
  echo "Check the workflow out with 'lfs: true'."
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Vendored models first, PDK second. Keeping the vendored copy authoritative
# means the gate cannot pass or fail on which PDK release a runner happens to
# have mounted.
SC=""
for cand in "$MODELS" /pdk/sky130A/libs.ref/sky130_fd_sc_hd/verilog; do
  if [ -f "$cand/sky130_fd_sc_hd.v" ]; then SC="$cand"; break; fi
  if [ -f "$cand/sky130_fd_sc_hd.v.gz" ]; then
    gunzip -c "$cand/sky130_fd_sc_hd.v.gz" > "$WORK/sky130_fd_sc_hd.v"
    gunzip -c "$cand/primitives.v.gz"       > "$WORK/primitives.v"
    SC="$WORK"; break
  fi
done

[ -n "$SC" ] || {
  echo "RESULT: SKIP — no sky130 cell models found, so the netlist claim was NOT checked."
  exit 2
}

echo "models: $SC"
echo "netlist: $NETLIST"

# -DGL_TEST brings in the VPWR/VGND connection. Without it every cell output is
# X and the bench reports "the sequencer never ran", which looks exactly like a
# broken design.
iverilog -g2012 -DGL_TEST -DEXPECT_PASS=1 -DFUNCTIONAL -DUSE_POWER_PINS \
         -DUNIT_DELAY=\#1 -I "$ROOT/src" -o "$WORK/st.vvp" -s tb_selftest \
         "$ROOT/test/tb_selftest.v" "$ROOT/$NETLIST" \
         "$SC/primitives.v" "$SC/sky130_fd_sc_hd.v" 2>&1 | grep -v UNIT_DELAY || true

out="$(cd "$ROOT" && vvp "$WORK/st.vvp" 2>&1 || true)"
echo "$out" | tail -4

echo "$out" | grep -q "PASS held" || {
  echo "RESULT: FAIL — the shipped netlist did not hold a PASS verdict"
  exit 1
}
echo "$out" | grep -q "verdict latched" || {
  echo "RESULT: FAIL — no verdict was ever latched"
  exit 1
}
echo
echo "RESULT: PASS — the shipped netlist proves itself on the demo board"
