#!/usr/bin/env bash
# Print the numbers that decide whether this die is shippable.
#
#   ./pdk/report.sh
#
# Deliberately reads only the artefacts the flow wrote, not the flow's own
# summary, so a stage that reported success but produced nothing is visible.
set -euo pipefail
VOL="${VOL:-tt26e-sim}"
TAG="${1:-tt26e}"

docker run --rm -v "$VOL":/w -e TAG="$TAG" alpine sh -lc '
R="/w/pdk/runs/$TAG"
cd "$R" || { echo "no run $TAG"; exit 1; }

echo "=== stages"
ls -d [0-9][0-9]-*/ | wc -l | sed "s/^/  stage dirs: /"

echo
echo "=== drc (magic)"
for f in *-magic-drc/*.log; do
  [ -f "$f" ] || continue
  echo "  $f"
  R="${f%/*}/reports/drc.magic.rpt"
  if [ -f "$R" ]; then
    grep -iE "COUNT|violation" "$R" | tail -3 | sed "s/^/    /"
  else
    grep -iE "total errors|violation" "$f" | tail -3 | sed "s/^/    /"
  fi
done

echo
echo "=== lvs (netgen)"
for f in *-netgen-lvs/*.log; do
  [ -f "$f" ] || continue
  echo "  $f"
  R="${f%/*}/reports/lvs.netgen.rpt"
  if [ -f "$R" ]; then
    grep -iE "Final result|do not match|failed" "$R" | tail -3 | sed "s/^/    /"
  else
    grep -iE "circuits match|do not match" "$f" | tail -3 | sed "s/^/    /"
  fi
done

echo
echo "=== final metrics"
if [ -f final/metrics.json ]; then
  # metrics.json is JSON; parse it with awk-free shell + jq if present, else
  # dump the keys we care about. python3 is not in the alpine volume image.
  if command -v jq >/dev/null 2>&1; then
    jq -r "to_entries[] | select(.key|test(\"die__area|core__area|instance__count\\$|utilization|setup__ws|setup__tns|hold__ws|hold__tns|drc_errors|wirelength\")) | \"  \\(.key) \\(.value)\"" final/metrics.json
  else
    tr "," "\n" < final/metrics.json | grep -E "die__area|core__area|instance__count|utilization|setup__ws|setup__tns|hold__ws|hold__tns|drc_errors|wirelength" | sed "s/^/  /"
  fi
  : <<"PYUNUSED"

m = json.load(open("final/metrics.json"))
def g(*names):
    for n in names:
        for k, v in m.items():
            if k == n or k.endswith(n):
                return v
    return None
keys = [
    ("die area um2",        ["design__die__area"]),
    ("core area um2",       ["design__core__area"]),
    ("cell count",          ["design__instance__count", "design__instance__count__stdcell"]),
    ("utilisation %",       ["design__instance__utilization"]),
    ("setup WS ns",         ["timing__setup__ws"]),
    ("setup TNS ns",        ["timing__setup__tns"]),
    ("hold WS ns",          ["timing__hold__ws"]),
    ("hold TNS ns",         ["timing__hold__tns"]),
    ("drc violations",      ["route__drc_errors", "detailedroute__route__drc_errors"]),
    ("total wirelength um", ["route__wirelength__estimated", "route__wirelength"]),
]
for label, cands in keys:
    v = g(*cands)
    if v is not None:
        print(f"  {label:22s} {v}")
PYUNUSED
else
  echo "  no final/metrics.json"
fi

echo
echo "=== output files"
for f in final/gds/*.gds final/lef/*.lef final/*.v; do
  [ -f "$f" ] || continue
  sz=$(stat -c %s "$f")
  printf "  %7.2f MB  %s\n" "$(echo "$sz" | sed "s/$//" | awk "{print \$1/1048576}")" "$f"
done
'
