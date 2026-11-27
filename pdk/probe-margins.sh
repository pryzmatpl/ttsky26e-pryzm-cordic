#!/usr/bin/env bash
# Which variable actually sets the core margin (and therefore where the power
# straps end)?
#
# The precheck wants a power port within 10 um of the die edge. Our straps land
# 10.64 um in. PDN_EXTEND_TO=boundary moved them to the edge but caused
# detailed-route violations, so that was the wrong lever. The margins are:
#   BOTTOM_MARGIN_MULT 4   TOP_MARGIN_MULT 4
#   LEFT_MARGIN_MULT  12   RIGHT_MARGIN_MULT 12
# This finds the code that turns those into geometry, so the fix is arithmetic
# rather than guesswork.
#
#   ./pdk/probe-margins.sh
set -euo pipefail
IMAGE="${IMAGE:-photonip/openlane2:ihp-v3.0.0.dev23-klayout}"
VOL="${VOL:-tt26e-cfgtest}"

docker volume create "$VOL" >/dev/null
docker run --rm -v "$VOL":/w --entrypoint /bin/bash "$IMAGE" -lc '
LL=$(python3 -c "import librelane,os;print(os.path.dirname(librelane.__file__))")
cd /w

echo "=== MARGIN_MULT definitions"
grep -rn "MARGIN_MULT" "$LL" --include=*.py | head -10

echo
echo "=== the variable declarations"
sed -n "1150,1190p" "$LL/steps/openroad.py"
echo
echo "=== where they are CONSUMED"
grep -rn "BOTTOM_MARGIN_MULT" "$LL" --include=*.py | grep -v "Variable" | head

echo
echo "=== unithd site height (the unit these mults are probably in)"
grep -rn "unithd" "$LL" --include=*.py | head -5
'
