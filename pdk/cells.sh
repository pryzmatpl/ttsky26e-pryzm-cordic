#!/usr/bin/env bash
# Dump the cell mix of a LibreLane synthesis run, to find what dominates.
#
#   ./pdk/cells.sh [run-tag]
set -euo pipefail
VOL="${VOL:-tt26e-sim}"
TAG="${1:-tt26e}"

docker run --rm -v "$VOL":/w -e TAG="$TAG" alpine sh -lc '
cd /w/pdk/runs/$TAG || exit 1
D=$(ls -d *yosys-synthesis* | head -1)
LOG=$(ls $D/*.log | head -1)
echo "log: $LOG"
ls $D
echo
echo "=== every sky130 cell row in the log"
grep -oE "sky130_fd_sc_hd__[a-z0-9_]+ +[0-9]+" "$LOG" | sort -k2 -rn | head -25
echo
echo "=== totals"
grep -E "Number of cells|Number of wires|Chip area" "$LOG"
'
