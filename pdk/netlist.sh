#!/usr/bin/env bash
# Count cells in the netlist LibreLane actually mapped, and price them.
#
# The yosys stat block is not in the flow log, but the mapped netlist is on
# disk: `<design>.nl.v`. Counting its cell instances is a direct measurement of
# the structure that has to be placed and routed.
#
#   ./pdk/netlist.sh [run-tag]
set -euo pipefail
VOL="${VOL:-tt26e-sim}"
TAG="${1:-tt26e}"

docker run --rm -v "$VOL":/w -e TAG="$TAG" alpine sh -lc '
cd /w/pdk/runs/$TAG || exit 1
NL=$(ls */tt_um_pryzm_cordic.nl.v 2>/dev/null | head -1)
[ -n "$NL" ] || { echo "no netlist"; exit 1; }
echo "netlist: $NL"
echo
echo "=== instance count by cell (top 20)"
grep -oE "sky130_fd_sc_hd__[a-z0-9_]+" "$NL" | sort | uniq -c | sort -rn | head -20
echo
echo "total instances: $(grep -cE "sky130_fd_sc_hd__[a-z0-9_]+ +\\\\?[a-zA-Z_]" "$NL" || true)"
'
