#!/usr/bin/env bash
# Trace one operation through the FSM, inside the sim container.
#   ./test/dbg.sh 0 0 0 60           # tb_dbg: per-cycle state trace
#   TB=tb_dbg2 NBYTES=2 ./test/dbg.sh 0 2972 0 4    # tb_dbg2: byte protocol
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
OP="${1:-0}"; A="${2:-0}"; B="${3:-0}"; N="${4:-60}"
TB="${TB:-tb_dbg}"
NBYTES="${NBYTES:-2}"
IMAGE="${IMAGE:-photonip/cocotb:2.2.0}"
# Its own volume. Sharing the flow's volume would delete a routed run.
VOL="${VOL:-tt26e-dbg}"

docker volume create "$VOL" >/dev/null
tar -C "$ROOT" -cf - . | docker run --rm -i -v "$VOL":/w alpine sh -lc 'rm -rf /w/*; tar -xf - -C /w'
docker run --rm -v "$VOL":/w -e TB="$TB" -e OP="$OP" -e A="$A" -e B="$B" \
  -e N="$N" -e NBYTES="$NBYTES" "$IMAGE" bash -lc '
  cd /w &&
  iverilog -g2012 -o /tmp/d.vvp "test/$TB.v" src/project.v &&
  vvp /tmp/d.vvp +OP=$OP +A=$A +B=$B +N=$N +NBYTES=$NBYTES
'
