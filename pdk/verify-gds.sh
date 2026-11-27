#!/usr/bin/env bash
# Verify the shipped GDS is real geometry and matches the LEF.
#
#   ./pdk/verify-gds.sh [gds-path] [lef-path]
#
# A `.gds` that some tool wrote is not evidence by itself: this reads it back
# and checks the top cell, die bbox, layer count and shape count, then compares
# the bbox against the LEF's SIZE. A mismatch means the abstract and the layout
# describe different dies — which is exactly the trap the earlier tile-size
# shuffling in this project set.
#
# The tree is exported with tar into a named volume, not bind-mounted: the
# Docker daemon lives on the host while this tree lives in the gateway
# container, so a bind mount of $PWD arrives empty.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
cd "$ROOT"
IMAGE="${IMAGE:-photonip/openlane2:ihp-v3.0.0.dev23-klayout}"
VOL="${VOL:-tt26e-verify}"
GDS="${1:-gds/tt_um_pryzm_cordic.gds}"
LEF="${2:-lef/tt_um_pryzm_cordic.lef}"

for f in "$GDS" "$LEF"; do
  [ -f "$f" ] || { echo "missing: $f"; exit 1; }
done

docker volume create "$VOL" >/dev/null
tar -cf - "$GDS" "$LEF" | docker run --rm -i -v "$VOL":/w alpine sh -lc \
  'rm -rf /w/*; mkdir -p /w/gds /w/lef
   tar -xf - -C /tmp
   cp "/tmp/'"$GDS"'" /w/gds/ ; cp "/tmp/'"$LEF"'" /w/lef/ ; ls -la /w/gds /w/lef'

docker run --rm -v "$VOL":/w --entrypoint /bin/bash "$IMAGE" -lc '
cd /w
python3 - <<"PY"
import re
import pya

gds = "gds/" + __import__("os").listdir("gds")[0]
lef = "lef/" + __import__("os").listdir("lef")[0]

l = pya.Layout()
l.read(gds)
top = l.top_cell()
b = top.bbox()
d = l.dbu
w = (b.right - b.left) * d
h = (b.top - b.bottom) * d

print("file     :", gds)
print("top cell :", top.name)
print("dbu      :", d)
print("bbox um  : %.3f %.3f %.3f %.3f" % (b.left*d, b.bottom*d, b.right*d, b.top*d))
print("size um  : %.3f x %.3f" % (w, h))
print("cells    :", l.cells())
print("layers   :", l.layers())

count = 0
for li in l.layer_indexes():
    it = top.begin_shapes_rec(li)
    while not it.at_end():
        count += 1
        it.next()
print("shapes   :", count)

text = open(lef).read()
m = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", text)
if not m:
    print("LEF      : no SIZE found")
    raise SystemExit(1)
lw, lh = float(m.group(1)), float(m.group(2))
print("LEF size : %.3f x %.3f" % (lw, lh))
ok = abs(w - lw) < 0.01 and abs(h - lh) < 0.01
print("MATCH    :", "yes" if ok else "NO")
raise SystemExit(0 if ok else 1)
PY
'
