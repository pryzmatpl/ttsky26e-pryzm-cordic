#!/usr/bin/env bash
# Run the self-test bench twice: once on the shipped ROM (must report PASS and
# hold it) and once on a deliberately corrupted ROM (must report FAIL).
#
# The second run is the point. A self-test that cannot fail is indistinguishable
# from one that never checks anything, and this bench is the entire basis of the
# claim that the die is verifiable on the demo board.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
IMAGE="${IMAGE:-photonip/cocotb:2.2.0}"
VOL="${VOL:-tt26e-selftest}"

run() {  # $1 = define, $2 = label
  docker run --rm -v "$VOL":/w "$IMAGE" sh -lc \
    "cd /w && iverilog -g2012 -I src -D$1 -o /tmp/t.vvp -s tb_selftest test/tb_selftest.v src/project.v && vvp /tmp/t.vvp"
}

seed() {
  docker volume create "$VOL" >/dev/null
  tar -C "$ROOT" -cf - src test | docker run --rm -i -v "$VOL":/w alpine \
    sh -lc 'rm -rf /w/*; tar -xf - -C /w'
}

seed
echo "=== shipped ROM: expect PASS held"
run EXPECT_PASS=1

echo
echo "=== corrupted ROM: expect FAIL"
python3 "$ROOT/bringup/gen-selftest-rom.py" --corrupt --out "$ROOT/src/selftest_rom.vh" >/dev/null
seed
run EXPECT_PASS=0
rc=$?

python3 "$ROOT/bringup/gen-selftest-rom.py" >/dev/null
echo
echo "shipshape ROM restored: $(sha256sum "$ROOT/src/selftest_rom.vh" | cut -c1-16)"
exit $rc
