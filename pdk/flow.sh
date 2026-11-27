#!/usr/bin/env bash
# Place, route and stream out tt_um_pryzm_cordic on sky130A with LibreLane.
#
# This is the gate that synthesis alone cannot answer: does the design close at
# the target clock, does it route with no DRC violations, and does LVS agree
# with the netlist? The Tiny Tapeout shuttle does exactly this in CI; running
# it here means a failure is found before submission rather than after.
#
#   ./pdk/flow.sh              # default 50 MHz
#   CLOCK_NS=25 ./pdk/flow.sh  # 40 MHz
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
IMAGE="${IMAGE:-photonip/openlane2:ihp-v3.0.0.dev23-klayout}"
VOL="${VOL:-tt26e-sim}"
PDKVOL="${PDKVOL:-tt26e-pdk}"
CLOCK_NS="${CLOCK_NS:-20}"

docker volume create "$VOL" >/dev/null
tar -C "$ROOT" -cf - . | docker run --rm -i -v "$VOL":/w alpine sh -lc 'rm -rf /w/*; tar -xf - -C /w'

# The image's entrypoint is the iic-osic-tools launcher; `--skip` runs the
# command directly instead of starting a desktop session.
docker run --rm -v "$VOL":/w -v "$PDKVOL":/pdk -e CLOCK_NS="$CLOCK_NS" \
  --entrypoint /bin/bash "$IMAGE" -lc '
set -e
cd /w
export PDK_ROOT=/pdk
export PDK=sky130A
mkdir -p pdk/runs

python3 - <<"PY" > pdk/config.json
import json, os
clock = float(os.environ.get("CLOCK_NS", "20"))
cfg = {
  "DESIGN_NAME": "tt_um_pryzm_cordic",
  "VERILOG_FILES": ["dir::../src/project.v"],
  "CLOCK_PORT": "clk",
  "CLOCK_PERIOD": clock,
  "PDK": "sky130A",
  "STD_CELL_LIBRARY": "sky130_fd_sc_hd",
  # The die here is the user core; the shuttle adds its own pad ring and
  # multiplexer around it.
  # The full 2x2 tile: 334 x 216 um. An earlier run used 320 x 202 um and hit
  # 2,779 detailed-route violations at 85.7 % density — the design fits the
  # area but not the routing budget. At the real tile it is 76.8 %, which is
  # where the clean run was measured. Do not shrink this to "make it fit":
  # density is a routing constraint, not just an area one.
  "FP_SIZING": "absolute",
  "DIE_AREA": [0, 0, 334, 216],
  "PL_TARGET_DENSITY_PCT": 45,
  # A transition limit of 1.5 ns is 7.5 % of a 20 ns period, which is far
  # tighter than the 3 ns the 20 MHz target needs and forces cell upsizing that
  # doubles the area. 3 ns is ~15 % of the period and still closes timing.
  "MAX_FANOUT_CONSTRAINT": 6,
  "MAX_TRANSITION_CONSTRAINT": 3.0,
  # LibreLane 3.x names these as resizer design limits; the older
  # PL_RESIZER_* keys do not exist in this version and are rejected outright.
  "DESIGN_REPAIR_MAX_SLEW_PCT": 20,
  "DESIGN_REPAIR_MAX_CAP_PCT": 20,
  "pdk::sky130*": {
    "FP_CORE_UTIL": 45,
    "scl::sky130_fd_sc_hd": {"CLOCK_PERIOD": clock}
  },
  "pdk::sky130A": {"SYNTH_STRATEGY": "AREA 1"},
  "meta": {"version": 3},
}
print(json.dumps(cfg, indent=2))
PY

echo "--- LibreLane version"
librelane --version 2>/dev/null || python3 -c "import librelane; print(librelane.__version__)"

echo "--- running the flow (this takes minutes)"
# -j is the job count (`librelane --help`: "-j, --jobs INTEGER"). There is no
# --threads option in this version: passing it makes LibreLane exit before it
# reads the config, which is what happened on the first attempt at this script.
#
# Pinning it also fixes a real reproducibility problem. Left unset, LibreLane
# hands OpenROAD an empty thread count ([ORD-0032]), OpenROAD sizes its pool
# from the host core count, and the detailed router is not reproducible across
# pool sizes: the same RTL and config produced 0 and then 2779 DRC violations
# on two runs. With the count pinned, a DRC result is a statement about the
# design rather than about the machine.
librelane pdk/config.json --run-tag tt26e -j "${JOBS:-8}" --condensed 2>&1 | tail -60 || true
'
