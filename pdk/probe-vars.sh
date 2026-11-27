#!/usr/bin/env bash
# Discover how the installed LibreLane exposes its variable registry.
#
# Run this when check-config.sh reports an implausible count (0 variables
# known): it means the discovery used the wrong module or attribute for this
# LibreLane version, not that the config is wrong.
#
#   ./pdk/probe-vars.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-photonip/openlane2:ihp-v3.0.0.dev23-klayout}"
VOL="${VOL:-tt26e-cfgtest}"

docker run --rm -v "$VOL":/w --entrypoint /bin/bash "$IMAGE" -lc '
cd /w
python3 - <<"PY"
import inspect
import librelane
import librelane.config as C

print("version:", librelane.__version__)
print()
print("librelane.config public names:")
for a in sorted(dir(C)):
    if not a.startswith("_"):
        print("  ", a)
print()
# Search the whole package for classes carrying a config-key attribute
cands = {}
import pkgutil
for mod in pkgutil.walk_packages(librelane.__path__, "librelane."):
    try:
        m = __import__(mod.name, fromlist=["x"])
    except Exception:
        continue
    for name, obj in vars(m).items():
        if not inspect.isclass(obj):
            continue
        for attr in ("name", "key", "variable"):
            v = obj.__dict__.get(attr)
            if isinstance(v, str) and v.isupper() and len(v) > 3:
                cands.setdefault(attr, set()).add(v)
for attr, vals in cands.items():
    print(f"attribute {attr!r}: {len(vals)} uppercase values, e.g. {sorted(vals)[:5]}")
PY
'
