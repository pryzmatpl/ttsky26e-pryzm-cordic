#!/usr/bin/env bash
# Report how far the running flow has got, and whether detailed routing is
# still making progress.
#
# A stalled DRT looks identical to a slow one from the outside, so this prints
# the log size and mtime alongside the violation count: a log growing across two
# samples means it is working.
#
#   ./pdk/progress.sh
set -euo pipefail
VOL="${VOL:-tt26e-sim}"
TAG="${1:-tt26e}"

docker run --rm -v "$VOL":/w -e TAG="$TAG" alpine sh -lc '
cd "/w/pdk/runs/$TAG" 2>/dev/null || { echo "no run $TAG"; exit 1; }

# The furthest stage reached is the HIGHEST NUMBERED directory, not the most
# recently written one: STA runs after detailed routing and writes its log in
# seconds, so ordering by mtime reports a stage the flow has already left.
D=$(ls -d [0-9][0-9]-*/ 2>/dev/null | sort | tail -1)
echo "stage: ${D%/}"
echo "--- reached: $(ls -d [0-9][0-9]-*/ 2>/dev/null | wc -l) stage dirs"

# Detailed routing keeps its log inside drt-run-N/, not at the stage root, and
# the stage-root log stays 0 bytes until the stage finishes.
L="$D"openroad-detailedrouting.log
if [ -s "$L" ]; then
  echo "--- log: $(stat -c %s "$L") bytes, mtime $(stat -c %y "$L" | cut -d. -f1)"
  tail -4 "$L" | sed "s/^/    /"
  grep -oE "Number of violations = [0-9]+" "$L" | tail -3 | sed "s/^/    /"
fi

# Any other stage: show the big log, which is the one being written.
if [ -z "$(ls -d "$D"drt-run-* 2>/dev/null)" ]; then
  L=$(ls -S "$D"*.log 2>/dev/null | head -1)
  if [ -n "$L" ] && [ -s "$L" ]; then
    echo "--- log: $(basename "$L"), $(stat -c %s "$L") bytes"
    tail -4 "$L" | sed "s/^/    /"
    grep -oE "Number of violations = [0-9]+" "$L" | tail -3 | sed "s/^/    /"
  fi
fi

if [ -f final/metrics.json ]; then
  echo
  echo "FINAL metrics present"
else
  echo
  echo "no final/metrics.json yet"
fi
'
