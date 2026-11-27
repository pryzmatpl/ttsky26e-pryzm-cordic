#!/usr/bin/env bash
# Compare src/project.v against the golden model, inside the sim container.
#
#   ./test/run.sh              # 50 vectors per operation + corners
#   ./test/run.sh 400          # 400 vectors per operation
#
# The workspace is exported into a named volume because the Docker daemon lives
# on the host while this tree lives in the gateway container; a bind mount of
# the gateway path would arrive empty.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
N="${1:-50}"
IMAGE="${IMAGE:-photonip/cocotb:2.2.0}"
VOL="${VOL:-tt26e-sim}"

docker volume create "$VOL" >/dev/null
tar -C "$ROOT" -cf - . | docker run --rm -i -v "$VOL":/w alpine sh -lc 'rm -rf /w/*; tar -xf - -C /w'
docker run --rm -v "$VOL":/w -e N="$N" "$IMAGE" bash -lc '
  set -e
  cd /w
  python3 test/sim_compare.py --vectors "$N"
'
