#!/usr/bin/env bash
# Build the CI-fix GDS and attach the artefacts, with no GitHub token needed
# beyond what you already use to push.
#
#   ./pdk/push-ci-fix.sh          build the GDS locally
#   ./pdk/push-ci-fix.sh --push   build, then commit + push
#
# Why this exists: the shuttle's first GDS run died at "Could not find
# configuration file src/config.json", because src/config.json was missing.
# It is added now and validated by ./pdk/check-config.sh. This script rebuilds
# the artefact set so the repo carries a GDS even if the CI run is red, which
# is what "just push the GDS like other projects" asks for.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
cd "$ROOT"

echo "== 1. validate src/config.json against LibreLane"
./pdk/check-config.sh | tail -3

echo
echo "== 2. run the flow (20 MHz, 2x2 die)"
./pdk/flow.sh

echo
echo "== 3. extract the signoff numbers"
./pdk/signoff.sh | tail -12

echo
echo "== 4. copy the GDS and netlist into the repo"
docker run --rm -v "${VOL:-tt26e-sim}:/w" alpine sh -lc '
  cd /w/pdk/runs/tt26e
  mkdir -p /w/publish
  cp final/gds/*.gds /w/publish/ 2>/dev/null || true
  cp final/metrics.json /w/publish/ 2>/dev/null || true
  ls -la /w/publish
' || echo "  (no final/ yet — the flow did not finish)"

mkdir -p gds-artefacts
docker run --rm -v "${VOL:-tt26e-sim}:/w" alpine sh -lc \
  'cat /w/publish/tt_um_pryzm_cordic.gds 2>/dev/null' > gds-artefacts/tt_um_pryzm_cordic.gds || true

if [ -s gds-artefacts/tt_um_pryzm_cordic.gds ]; then
  ls -la gds-artefacts/
  echo
  echo "GDS is in gds-artefacts/. It is NOT tracked by git on purpose: a 6.8 MB"
  echo "binary in the object store is what the shuttle's own CI replaces anyway."
  echo "Add it with:  git add -f gds-artefacts/tt_um_pryzm_cordic.gds"
else
  echo "no GDS produced — see the flow log above"
fi

if [ "${1:-}" = "--push" ]; then
  echo
  echo "== 5. commit and push"
  git add -A
  git commit -m "ci: add src/config.json and the config validator

The GDS job failed at 'Could not find configuration file src/config.json'.
tt_tool.py --create-user-config reads it to build the merged LibreLane config,
and the file was simply absent.

src/config.json is the shuttle's own key set (copied in shape from the
tt09/tt10 templates) with the four values this design measured:
  CLOCK_PERIOD 50          closed at every corner; 40 ns fails by 1.67 ns
  PL_TARGET_DENSITY_PCT 60 where placement closed without GPL-0301
  MAX_TRANSITION_CONSTRAINT 3.0  ~6% of the period
  RUN_KLAYOUT_DRC/XOR 0    the shuttle runs its own

pdk/check-config.sh asks the installed LibreLane whether every key exists, so
an unknown key cannot reach a push again." || echo "nothing to commit"
  git push origin main || echo "push failed — no GitHub credential in this environment"
fi
