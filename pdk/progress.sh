#!/usr/bin/env bash
# Report how far the running flow has got, and whether detailed routing is
# still making progress.
#
# A stalled DRT looks identical to a slow one from the outside, so this prints
# the log's size and mtime alongside the violation count: a log growing across
# two samples means it is working.
#
#   ./pdk/progress.sh
set -euo pipefail
VOL="${VOL:-tt26e-sim}"
TAG="${1:-tt26e}"

docker run --rm -v "$VOL":/w -e TAG="$TAG" alpine sh -lc '
cd "/w/pdk/runs/$TAG" 2>/dev/null || { echo "no run $TAG"; exit 1; }
D=$(ls -dt [0-9][0-9]-*/ | head -1)
echo "stage: ${D%/}"
LOG=$(ls "$D"/*.log 2>/dev/null | head -1)
if [ -n "$LOG" ]; then
  echo "log: $LOG"
  echo "size: $(stat -c %s "$LOG") bytes   mtime: $(stat -c %y "$LOG")"
  echo "--- last lines"
  tail -4 "$LOG"
  echo "--- violation counts seen"
  grep -oE "Number of violations = [0-9]+" "$LOG" | tail -3
fi
if [ -f final/metrics.json ]; then
  echo
  echo "FINAL metrics present"
else
  echo
  echo "no final/metrics.json yet"
fi
'
