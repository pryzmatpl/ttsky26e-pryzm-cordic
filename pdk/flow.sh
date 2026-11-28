#!/usr/bin/env bash
# Place, route and stream out tt_um_pryzm_cordic on sky130A with LibreLane.
#
#   ./pdk/flow.sh              # the shuttle's floorplan, 20 MHz
#   CLOCK_NS=40 ./pdk/flow.sh  # tighter clock
#
# The config is src/config.json merged with the keys tt_tool.py would generate,
# in exactly the order the shuttle merges them. That ordering is the whole
# point: the shuttle's generated keys WIN over src/config.json, so anything this
# script set differently would be a different chip.
#
# Two things this script used to get wrong, both of which made a green local run
# meaningless:
#
#  1. It invented its own floorplan (DIE_AREA 334x216, no template). The shuttle
#     uses 334.88x225.76 with FP_DEF_TEMPLATE=tt_block_2x2_pg.def, and that
#     template is what puts the core boundary 10.64 um inside the die - so a
#     local run could never reproduce a precheck failure caused by the template.
#
#  2. It dropped VDD_PIN/GND_PIN/RT_MAX_LAYER, so the power net names and the
#     top routing layer differed from the shuttle's.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
IMAGE="${IMAGE:-photonip/openlane2:ihp-v3.0.0.dev23-klayout}"
VOL="${VOL:-tt26e-sim}"
PDKVOL="${PDKVOL:-tt26e-pdk}"
CLOCK_NS="${CLOCK_NS:-20}"
TT="${TT_SUPPORT_TOOLS:-/tmp/ttst}"

[ -d "$TT/tech/sky130A/def" ] || {
  echo "no shuttle templates at $TT/tech (set TT_SUPPORT_TOOLS)"; exit 1; }

docker volume create "$VOL" >/dev/null
tar -C "$ROOT" -cf - . | docker run --rm -i -v "$VOL":/w alpine sh -lc 'rm -rf /w/*; tar -xf - -C /w'
# The shuttle's tech/ tree (the .def floorplans) is not in this repo, so it is
# exported next to the design the way tt-gds-action lays it out.
tar -C "$(dirname "$TT")" -cf - "$(basename "$TT")/tech" \
  | docker run --rm -i -v "$VOL":/w alpine sh -lc 'tar -xf - -C /w; rm -rf /w/tt_tech; mv /w/*/tech /w/tt_tech'

# DETACHED, not `--rm` in the foreground.
#
# The build host's session can end while detailed routing is still going (it
# runs ~50 minutes on this die), and when the parent shell dies the foreground
# container is killed mid-route — leaving a half-written run that looks like a
# silent failure. A named container with `--rm` semantics restored by an
# explicit rm survives the session and can be re-attached.
RUNNER="${RUNNER:-tt26e-flow}"
docker rm -f "$RUNNER" >/dev/null 2>&1 || true
docker run -d --name "$RUNNER" -v "$VOL":/w -v "$PDKVOL":/pdk -e CLOCK_NS="$CLOCK_NS" \
  --entrypoint /bin/bash "$IMAGE" -lc '
set -e
cd /w
export PDK_ROOT=/pdk
export PDK=sky130A
mkdir -p pdk/runs

python3 - <<"PY" > pdk/config.json
import json, os
clock = float(os.environ.get("CLOCK_NS", "20"))

# The design own config, exactly as committed. Comments are "//" keys, which
# LibreLane would reject, so they are dropped - which is what read_config does
# on the shuttle side too.
user = {k: v for k, v in json.load(open("src/config.json")).items()
        if not k.startswith("//")}

# The keys tt_tool.py --create-user-config writes, in its own order. These take
# precedence over src/config.json in create_merged_config(override_config).
shuttle = {
    "DESIGN_NAME": "tt_um_pryzm_cordic",
    "VERILOG_FILES": ["dir::../src/project.v"],
    "DIE_AREA": "0 0 334.88 225.76",
    "FP_DEF_TEMPLATE": "dir::../tt_tech/sky130A/def/tt_block_2x2_pg.def",
    "VDD_PIN": "VPWR",
    "GND_PIN": "VGND",
    "RT_MAX_LAYER": "met4",
    # From the PDK librelane_config block, which the shuttle also applies.
    "PDK": "sky130A",
    "STD_CELL_LIBRARY": "sky130_fd_sc_hd",
    "FP_SIZING": "absolute",
    "CLOCK_PERIOD": clock,
}

merged = dict(user)
merged.update(shuttle)

# src/config.json is written the way the shuttle writes it: 0/1 for flags and a
# space-separated DIE_AREA. LibreLane 3 with meta.version 3 refuses to coerce
# those, so the types are fixed up here by meaning, not by guesswork:
#   DIE_AREA      "x0 y0 x1 y1"  -> [x0, y0, x1, y1]
#   any flag      0 / 1          -> False / True
_DIE = {"DIE_AREA", "CORE_AREA"}
_FLAGS = {k for k in merged if k.startswith(("RUN_", "FP_PDN", "PDN_", "MAGIC_",
                                             "LINTER_", "GRT_", "DESIGN_REPAIR_",
                                             "PL_RESIZER", "PL_" ) ) and isinstance(merged[k], int)}

fixed = {}
for k, v in merged.items():
    if k in _DIE and isinstance(v, str) and len(v.split()) == 4:
        v = [float(x) for x in v.split()]
    elif isinstance(v, int) and not isinstance(v, bool):
        # Only the keys that are genuinely boolean toggles, never a count.
        if k in ("RUN_CTS", "RUN_KLAYOUT_XOR", "RUN_KLAYOUT_DRC", "RUN_LINTER",
                 "LINTER_INCLUDE_PDK_MODELS", "MAGIC_DEF_LABELS",
                 "MAGIC_WRITE_LEF_PINONLY", "GRT_ALLOW_CONGESTION",
                 "DESIGN_REPAIR_BUFFER_OUTPUT_PORTS", "PDN_MULTILAYER",
                 "FP_PDN_MULTILAYER", "PDN_SKIPTRIM", "PDN_ENABLE_RAILS",
                 "PDN_ENABLE_PINS", "PDN_ENABLE_GLOBAL_CONNECTIONS"):
            v = bool(v)
    fixed[k] = v

print(json.dumps(fixed, indent=2))
PY

echo "--- effective floorplan"
python3 -c "
import json; c=json.load(open(\"pdk/config.json\"))
for k in (\"DIE_AREA\",\"FP_DEF_TEMPLATE\",\"VDD_PIN\",\"GND_PIN\",\"RT_MAX_LAYER\",\"PDN_EXTEND_TO\",\"CLOCK_PERIOD\",\"PL_TARGET_DENSITY_PCT\"):
    print(f\"  {k:20s} {c.get(k)}\")"

echo "--- running the flow (this takes minutes)"
# -j is the job count. There is no --threads option in this version: passing it
# makes LibreLane exit before it reads the config.
#
# Pinning it also fixes a real reproducibility problem. Left unset, LibreLane
# hands OpenROAD an empty thread count ([ORD-0032]), OpenROAD sizes its pool
# from the host core count, and the detailed router is not reproducible across
# pool sizes: the same RTL and config produced 0 and then 2779 DRC violations
# on two runs. With the count pinned, a DRC result is a statement about the
# design rather than about the machine.
librelane pdk/config.json --run-tag tt26e -j "${JOBS:-8}" --condensed 2>&1 > /w/pdk/flow.out || true
'

# Follow the detached runner to completion, printing its tail. `docker wait`
# survives; the container does not need this shell alive.
echo "[flow] waiting on $RUNNER (silence is normal: detailed routing is ~50 min)"
docker wait "$RUNNER" >/dev/null
echo "[flow] container finished"
docker logs --tail 40 "$RUNNER" 2>&1 || true
docker rm -f "$RUNNER" >/dev/null 2>&1 || true
