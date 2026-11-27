#!/usr/bin/env bash
# RTL vs golden model, run inside the simulation container.
#
#   ./test/run.sh          # 50 vectors per operation
#   ./test/run.sh 2000     # 2000 per operation
#
# The tree is exported into a named volume because the Docker daemon lives on
# the host while this tree lives in the gateway container: a bind mount of the
# gateway path arrives empty. On a host that already has iverilog, run
# `python3 test/sim_compare.py` directly instead.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
N="${1:-50}"
IMAGE="${IMAGE:-photonip/cocotb:2.2.0}"
VOL="${VOL:-tt26e-sim}"

if command -v iverilog >/dev/null 2>&1; then
  exec python3 "$HERE/sim_compare.py" --vectors "$N"
fi

docker volume create "$VOL" >/dev/null
tar -C "$ROOT" -cf - . | docker run --rm -i -v "$VOL":/w alpine sh -lc 'rm -rf /w/*; tar -xf - -C /w'
docker run --rm -v "$VOL":/w -e N="$N" "$IMAGE" bash -lc '
  set -e
  cd /w
  python3 test/sim_compare.py --vectors "$N"
'
