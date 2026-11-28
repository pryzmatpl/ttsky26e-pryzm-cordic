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
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
IMAGE="${IMAGE:-photonip/cocotb:2.2.0}"
VOL="${VOL:-tt26e-selftest-gl}"
PDKVOL="${PDKVOL:-tt26e-pdk}"
NETLIST="${NETLIST:-tt_submission/tt_um_pryzm_cordic.v}"

[ -f "$ROOT/$NETLIST" ] || {
  echo "no hardened netlist at $NETLIST"
  echo "run: python3 pdk/tt-submission.py"
  exit 1
}

# CI has no docker and no local PDK. There the sky130 cell models are pulled by
# tt-gds-action into a known path, so the script looks for them on bare metal
# first and only falls back to the container. Telling "no models here" apart
# from "the design is broken" matters: on 2026-11-28 a missing prerequisite
# read as a passing check because nothing was asserted at all.
find_sc() {
  for p in "${SC_DIR:-}" \
           /pdk/sky130A/libs.ref/sky130_fd_sc_hd/verilog \
           /usr/share/pdk/sky130A/libs.ref/sky130_fd_sc_hd/verilog \
           "$ROOT"/pdk/sky130A/libs.ref/sky130_fd_sc_hd/verilog; do
    [ -n "$p" ] && [ -f "$p/sky130_fd_sc_hd.v" ] && { echo "$p"; return 0; }
  done
  return 1
}

if command -v iverilog >/dev/null 2>&1 && SC="$(find_sc)"; then
  echo "native: iverilog + $SC"
  iverilog -g2012 -DGL_TEST -DEXPECT_PASS=1 -DFUNCTIONAL -DUSE_POWER_PINS \
           -DUNIT_DELAY=\#1 -I "$ROOT/src" -o "$ROOT/.selftest-gl.vvp" -s tb_selftest \
           "$ROOT/test/tb_selftest.v" "$ROOT/$NETLIST" \
           "$SC/primitives.v" "$SC/sky130_fd_sc_hd.v" 2>&1 | grep -v UNIT_DELAY || true
  out=$(cd "$ROOT" && vvp .selftest-gl.vvp 2>&1); rm -f "$ROOT/.selftest-gl.vvp"
else
  echo "no native iverilog/sky130 models — using the container"
  docker volume create "$VOL" >/dev/null

tar -C "$ROOT" -cf - src test "$NETLIST" | docker run --rm -i -v "$VOL":/w alpine \
  sh -lc 'rm -rf /w/src /w/test /w/tt_submission; tar -xf - -C /w'

out=$(docker run --rm -v "$VOL":/w -v "$PDKVOL":/pdk:ro -e NETLIST="$NETLIST" "$IMAGE" bash -lc '
set -e
cd /w
SC=/pdk/sky130A/libs.ref/sky130_fd_sc_hd/verilog
[ -f "$SC/sky130_fd_sc_hd.v" ] || { echo "MISSING_MODELS"; exit 0; }

# -DGL_TEST brings in the VPWR/VGND connection. Without it every cell output
# is X and the bench reports "the sequencer never ran", which looks exactly
# like a broken design.
iverilog -g2012 -DGL_TEST -DEXPECT_PASS=1 -DFUNCTIONAL -DUSE_POWER_PINS \
         -DUNIT_DELAY=\#1 -I src -o /tmp/st.vvp -s tb_selftest \
         test/tb_selftest.v "$NETLIST" \
         "$SC/primitives.v" "$SC/sky130_fd_sc_hd.v" 2>&1 | grep -v UNIT_DELAY || true

vvp /tmp/st.vvp 2>&1 || true
')
fi

case "$out" in
  *MISSING_MODELS*)
    echo "RESULT: SKIP — no sky130 cell models in this environment."
    echo "This is a SKIP, not a pass: the netlist claim was NOT checked."
    exit 2 ;;
esac

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
