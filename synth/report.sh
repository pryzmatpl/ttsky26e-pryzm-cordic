#!/usr/bin/env bash
# Synthesise tt_um_pryzm_cordic against sky130_fd_sc_hd and report area.
#
# This is the "does it actually fit" gate: a 1x1 tile is 167 x 108 um, so the
# core area must be well under 18000 um2 to leave room for the pad ring and
# routing. The number this prints is the one the datasheet cites.
#
#   ./synth/report.sh
#
# Requires the sky130A PDK in a docker volume (see synth/README.md).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
IMAGE="${IMAGE:-ghcr.io/tinytapeout/openlane2:ihp-v3.0.0.dev23}"
VOL="${VOL:-tt26e-sim}"
PDKVOL="${PDKVOL:-tt26e-pdk}"

if ! docker volume inspect "$PDKVOL" >/dev/null 2>&1; then
  echo "PDK volume $PDKVOL is missing; see synth/README.md" >&2
  exit 2
fi

docker volume create "$VOL" >/dev/null
tar -C "$ROOT" -cf - . | docker run --rm -i -v "$VOL":/w alpine sh -lc 'rm -rf /w/*; tar -xf - -C /w'

docker run --rm -v "$VOL":/w -v "$PDKVOL":/pdk "$IMAGE" bash -lc '
  set -e
  cd /w
  export PDK_ROOT=/pdk
  LIB=$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
  mkdir -p synth

  # synthesis, mapping and the netlist the area report is taken from
  yosys -q -p "
    read_verilog -sv src/project.v
    hierarchy -top tt_um_pryzm_cordic
    synth -top tt_um_pryzm_cordic -flatten
    dfflibmap -liberty $LIB
    abc -liberty $LIB
    opt_clean
    write_verilog -noattr synth/netlist.v
  "

  # the statistics, written to a file so the parser never sees yosys noise
  yosys -q -p "
    read_verilog synth/netlist.v
    hierarchy -top tt_um_pryzm_cordic
    tee -o synth/stat.txt stat -liberty $LIB
  " >/dev/null

  cp synth/stat.txt synth/stat.last.txt
  python3 synth/area.py synth/stat.last.txt
  python3 synth/topcells.py synth/stat.last.txt $LIB
'
