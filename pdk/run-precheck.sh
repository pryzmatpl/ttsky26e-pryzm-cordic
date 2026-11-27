#!/usr/bin/env bash
# Run the shuttle precheck locally, in ~2 minutes instead of an 11-minute CI
# cycle.
#
#   ./pdk/run-precheck.sh
#
# Uses a plain python container with the packages from
# precheck/requirements.txt rather than the shuttle's nix-shell: the pinned
# nixpkgs there does not carry the attribute names precheck wants
# (python3Packages.gdstk is absent), and chasing nix attribute names is not the
# job - knowing whether the GDS passes is.
#
# The precheck reads:
#   <submission>/../info.yaml            project metadata
#   <submission>/../tt/tech/sky130A/...  the floorplan template it compares to
#   $PDK_ROOT/sky130A/libs.tech/...      its DRC/LVS decks
# so the tree is staged to match, and the PDK comes from the flow's own volume.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TT="${TT_SUPPORT_TOOLS:-/tmp/ttst}"
VOL="${VOL:-tt26e-precheck}"

[ -d "$TT/precheck" ] || { echo "no precheck checkout at $TT (set TT_SUPPORT_TOOLS)"; exit 1; }
[ -d "$TT/tech" ] || { echo "no tech templates at $TT/tech"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Two different roots, deliberately:
#   work/  -> the submission the checks read (gds, lef, netlist) + info.yaml
#   tech/  -> the templates, because precheck.py resolves them as
#             f"../tech/{tech}/def" relative to its OWN working directory
mkdir -p "$STAGE/work/tt_submission" "$STAGE/tech"
# The GDS under test: gds/ first (the flow's output), then tt_submission/.
# Copy tt_submission/ FIRST, then let gds/ and lef/ override it. The other
# order silently tests the committed layout instead of the one just built - and
# the two have different die areas, so the check reports a mismatch that does
# not exist in the new GDS.
for f in "$ROOT"/tt_submission/*.gds "$ROOT"/tt_submission/*.lef; do
  [ -f "$f" ] && cp "$f" "$STAGE/work/tt_submission/"
done
for f in "$ROOT"/gds/*.gds "$ROOT"/lef/*.lef; do
  [ -f "$f" ] && cp "$f" "$STAGE/work/tt_submission/"
done
# The Verilog syntax check reads the netlist from beside the GDS.
for f in "$ROOT"/tt_submission/*.v; do
  [ -f "$f" ] && cp "$f" "$STAGE/work/tt_submission/"
done
cp "$ROOT/info.yaml" "$STAGE/work/"
cp -r "$TT/tech/"* "$STAGE/tech/" 2>/dev/null || true
cp -r "$TT/precheck" "$STAGE/precheck"

GDS="$STAGE/work/tt_submission/tt_um_pryzm_cordic.gds"
[ -f "$GDS" ] || { echo "no GDS to check"; exit 1; }
echo "checking $(basename "$GDS"): $(stat -c %s "$GDS") bytes"
echo

# The docker daemon is on the host; a bind mount of a gateway path arrives
# empty, so the tree goes into a named volume.
docker volume create "$VOL" >/dev/null
tar -C "$STAGE" -cf - . | docker run --rm -i -v "$VOL":/s alpine sh -lc 'rm -rf /s/*; tar -xf - -C /s'

docker run --rm \
  -v "$VOL":/s \
  -v tt26e-pdk:/pdk:ro \
  -e PDK_ROOT=/pdk \
  -e PDK=sky130A \
  -e PYTHONUNBUFFERED=1 \
  --entrypoint /bin/bash \
  "${PRECHECK_IMAGE:-python:3.11}" -lc '
set -e
# libexpat is what the layout library links against, and the stock python
# images do not all carry it; installing it is cheaper than hunting for an
# image that happens to.
apt-get update -qq && apt-get install -y -qq --no-install-recommends libexpat1
# Pinned to precheck/requirements.txt. numpy matters: gdstk 0.9.52 is built
# against numpy 1.x, and pip will otherwise pull numpy 2 and the import fails
# with "_ARRAY_API not found" before any check runs.
# klayout the python module gives the layout API; the klayout and magic
# BINARIES (which the DRC decks shell out to) come from PRECHECK_IMAGE.
pip install --quiet --no-cache-dir \
  "numpy==1.26.4" "gdstk==0.9.52" "klayout>=0.30.8,<0.31.0" "pyyaml==6.0.1" \
  "yowasp-yosys==0.63.0.0.post1107"
cd /s/precheck
exec python precheck.py --gds /s/work/tt_submission/tt_um_pryzm_cordic.gds --tech sky130A
'
