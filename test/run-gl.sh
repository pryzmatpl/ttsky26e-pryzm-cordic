#!/usr/bin/env bash
# Golden-model equivalence for the HARDENED netlist, not just the RTL.
#
#   ./test/run-gl.sh [vectors-per-op]
#
# Why this is the check that matters: DRC, LVS and STA all compare a design
# against itself. They pass for a design whose outputs are tied to zero.
# This runs the post-place-and-route gate-level netlist through the same
# word-exact comparison against model/cordic16.py that the RTL passes, so a
# netlist that no longer computes the right answer fails here.
#
# It needs the sky130 standard-cell models (primitives + cells) on the same
# filesystem as the tree, which the test container has.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
N="${1:-100}"
IMAGE="${IMAGE:-photonip/cocotb:2.2.0}"
VOL="${VOL:-tt26e-gl}"
# The cocotb image has no PDK. The sky130 cell models come from the volume the
# flow itself used, mounted read-only at /pdk.
PDKVOL="${PDKVOL:-tt26e-pdk}"

NETLIST="${NETLIST:-tt_submission/tt_um_pryzm_cordic.v}"
[ -f "$ROOT/$NETLIST" ] || {
  echo "no hardened netlist at $NETLIST"
  echo "run: python3 pdk/tt-submission.py   (or ./pdk/flow.sh first)"
  exit 1
}

docker volume create "$VOL" >/dev/null
tar -C "$ROOT" -cf - . | docker run --rm -i -v "$VOL":/w alpine sh -lc 'rm -rf /w/*; tar -xf - -C /w'

docker run --rm -v "$VOL":/w -v "$PDKVOL":/pdk:ro -e N="$N" -e NETLIST="$NETLIST" "$IMAGE" bash -lc '
  set -e
  cd /w

  # The cocotb image ships the PDK models under PDK_ROOT.
  SC=/pdk/sky130A/libs.ref/sky130_fd_sc_hd/verilog
  if [ ! -f "$SC/sky130_fd_sc_hd.v" ]; then
    echo "no sky130 cell models at $SC"
    find / -name sky130_fd_sc_hd.v -not -path "*/proc/*" 2>/dev/null | head -3
    exit 1
  fi
  echo "cell models: $SC"

  # Gate level: the netlist replaces src/project.v, but the comparison and the
  # testbench are the same files the RTL run uses.
  GL_SIM=1 \
  PDK_SC_LIB="$SC" \
  SIM_SRC="$NETLIST" \
  SIM_LABEL="gate-level" \
  python3 test/sim_compare.py --vectors "$N"
'
