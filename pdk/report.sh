#!/usr/bin/env bash
# Pull the synthesis numbers out of a LibreLane run.
#
#   ./pdk/report.sh [run-tag]
#
# Prints the chip area LibreLane actually synthesised, the cell mix, and the
# utilisation it would see in a 1x1 and a 1x2 Tiny Tapeout tile. The point is
# to compare LibreLane's mapper with the bare-yosys figure — they disagree, and
# the flow's own number is the one that decides whether the design closes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
VOL="${VOL:-tt26e-sim}"
TAG="${1:-tt26e}"

docker run --rm -v "$VOL":/w -e TAG="$TAG" alpine sh -lc '
cd /w/pdk/runs/$TAG 2>/dev/null || { echo "no run $TAG"; exit 1; }
D=$(ls -d *yosys-synthesis* 2>/dev/null | head -1)
[ -n "$D" ] || { echo "no synthesis directory"; exit 1; }

echo "=== synthesis directory: $D"
grep -E "Chip area for module|of which used for sequential" $D/*.log | tail -4

echo
echo "=== cells by count (top 12)"
grep -E "^ +sky130_fd_sc_hd__[a-z0-9_]+ +[0-9]+$" $D/*.log \
  | awk "{print \$2, \$1}" | sort -rn | head -12

echo
echo "=== utilisation against the tapeout tiles"
grep -oE "Chip area for module .\\\\tt_um_pryzm_cordic.: [0-9.]+" $D/*.log \
  | tail -1 | awk -F": " "{a=\$2; printf \"core area      : %.0f um2\\n\", a;
    printf \"1x1 tile 18036 : %.0f %%\\n\", 100*a/18036;
    printf \"1x2 tile 36072 : %.0f %%\\n\", 100*a/36072;
    printf \"2x2 tile 72144 : %.0f %%\\n\", 100*a/72144}"
'
