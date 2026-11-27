#!/usr/bin/env bash
# Show the LibreLane options this image actually has.
#
# The flow passed --threads, which LibreLane 3.1 does not accept ("No such
# option"), so the run exited immediately. This prints the real options and the
# config variables that control threading, so the flag is chosen from evidence.
#
#   ./pdk/probe-options.sh
set -euo pipefail
IMAGE="${IMAGE:-photonip/openlane2:ihp-v3.0.0.dev23-klayout}"
VOL="${VOL:-tt26e-cfgtest}"

docker run --rm -v "$VOL":/w --entrypoint /bin/bash "$IMAGE" -lc '
cd /w
echo "=== CLI options mentioning thread/job/parallel"
librelane --help 2>&1 | grep -iE "thread|job|parallel|cores" || echo "  (none)"

echo
echo "=== config variables mentioning THREAD"
python3 - <<"PY"
import inspect
import librelane.config.variable as V

hits = []
for name in dir(V):
    obj = getattr(V, name)
    if not inspect.isclass(obj):
        continue
    key = obj.__dict__.get("name", "")
    if isinstance(key, str) and "THREAD" in key.upper():
        hits.append(key)
print("  " + ("\n  ".join(sorted(hits)) if hits else "(none)"))
PY

echo
echo "=== version"
librelane --version 2>&1 | head -2
'
