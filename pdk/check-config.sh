#!/usr/bin/env bash
# Check every key in src/config.json against the running LibreLane.
#
# The GDS job died with "Unknown key 'X' provided" on its first run. This makes
# that class of failure impossible to push: it asks LibreLane itself, through
# the same `Config.loads` path the CLI uses, whether each key is known.
#
#   ./pdk/check-config.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
IMAGE="${IMAGE:-photonip/openlane2:ihp-v3.0.0.dev23-klayout}"
VOL="${VOL:-tt26e-cfgtest}"

docker volume create "$VOL" >/dev/null
tar -C "$ROOT" -cf - . | docker run --rm -i -v "$VOL":/w alpine sh -lc 'rm -rf /w/*; tar -xf - -C /w'

docker run --rm -v "$VOL":/w --entrypoint /bin/bash "$IMAGE" -lc '
cd /w
python3 - <<"PY"
import json
import sys

from librelane.config import Config

cfg = json.load(open("src/config.json"))
cfg = {k: v for k, v in cfg.items() if not k.startswith("//")}
print(f"checking {len(cfg)} keys against LibreLane")

# Config.loads is the CLI path: it is what raises on an unknown key.
bad = []
for key in sorted(cfg):
    try:
        Config.loads({"DESIGN_NAME": "probe", key: cfg[key]})
    except Exception as exc:  # noqa: BLE001 - the message is the answer
        text = str(exc)
        if "Unknown key" in text or "unknown" in text.lower():
            bad.append((key, text.splitlines()[0][:100]))

if bad:
    print(f"REJECTED: {len(bad)} key(s)")
    for key, msg in bad:
        print(f"  {key}: {msg}")
    sys.exit(1)
print("RESULT: every key accepted")
PY
'
