#!/usr/bin/env bash
# Find which LibreLane variable controls the power-strap inset.
#
# The shuttle precheck rejects a power port more than 10 um from the die edge.
# Our met4 straps sit 10.64 um in, so the question is which variable sets that
# number, not what the number should be. This greps the installed LibreLane for
# the strap geometry code so the fix is aimed at a real variable.
#
#   ./pdk/probe-pdn.sh
set -euo pipefail
IMAGE="${IMAGE:-photonip/openlane2:ihp-v3.0.0.dev23-klayout}"
VOL="${VOL:-tt26e-cfgtest}"

docker run --rm -v "$VOL":/w --entrypoint /bin/bash "$IMAGE" -lc '
cd /w
LL=$(python3 -c "import librelane,os;print(os.path.dirname(librelane.__file__))")
echo "librelane at $LL"
echo
echo "=== files mentioning HALO"
grep -rln "HALO" "$LL" 2>/dev/null | head -5
echo
echo "=== PDN halo / offset usage"
grep -rn "horizontal_halo\|HORIZONTAL_HALO" "$LL" 2>/dev/null | head -8
echo
echo "=== PDN_EXTEND_TO definition"
sed -n "315,340p" "$LL/steps/common_variables.py"
echo
echo "=== PDN_EXTEND_TO variable"
grep -n -B3 -A8 "\"PDN_EXTEND_TO\"" "$LL/steps/common_variables.py"
'
