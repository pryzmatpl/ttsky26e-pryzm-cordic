#!/usr/bin/env bash
# Extract the signoff numbers from a completed LibreLane run.
#
#   ./pdk/signoff.sh [run-tag]
#
# Prints the stage list, detailed-route violations, the metrics file location
# and the streamed GDS. The metrics are parsed outside the container by
# `python3 pdk/metrics.py`, because the flow image has no python3 on PATH.
set -euo pipefail
VOL="${VOL:-tt26e-sim}"
TAG="${1:-tt26e}"
DEST="${DEST:-pdk/metrics.last.json}"

docker run --rm -v "$VOL":/w -e TAG="$TAG" alpine sh -lc '
cd /w/pdk/runs/$TAG || exit 1

echo "=== stages run"
ls -d [0-9][0-9]-* | tail -10

echo
echo "=== detailed-route violations (last reported)"
grep -ohE "Number of violations = [0-9]+" */openroad-detailedrouting.log 2>/dev/null | tail -1

echo
echo "=== LVS"
for f in $(find . -path "*lvs*" -name "*.rpt" -o -path "*lvs*" -name "*.log" 2>/dev/null | head -4); do
  echo "--- $f"
  grep -iE "match|mismatch|unmatched|error|success" "$f" 2>/dev/null | head -6
done

echo
echo "=== GDS"
find . -name "tt_um_pryzm_cordic.gds" -exec ls -la {} \; 2>/dev/null | tail -3

echo
echo "=== metrics copied for parsing"
if [ -f final/metrics.json ]; then
  cp final/metrics.json /w/pdk/metrics.last.json
  echo "pdk/metrics.last.json"
else
  echo "no final/metrics.json"
fi
'
