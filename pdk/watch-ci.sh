#!/usr/bin/env bash
# Poll a GitHub Actions run until it finishes, appending one line per change.
#
#   ./pdk/watch-ci.sh <run-id> [status-file]
#
# The GDS job takes ~1 h: the runner downloads the sky130 PDK, then runs the
# whole place-and-route flow. Polling it by hand burns turns, so this writes a
# line only when the status or conclusion changes, and exits when the run is
# done. Run it in the background and read the file.
set -uo pipefail
RUN_ID="${1:?usage: watch-ci.sh <run-id> [status-file]}"
OUT="${2:-/tmp/ci-watch.log}"
TOK=$(cat /tmp/tok)
REPO=pryzmatpl/ttsky26e-pryzm-cordic

prev=""
for _ in $(seq 1 240); do
  curl -s -H "Authorization: Bearer $TOK" \
    "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID" -o /tmp/ci-run.json
  cur=$(python3 -c "
import json,datetime as dt
d=json.loads(open('/tmp/ci-run.json').read(),strict=False)
s=dt.datetime.fromisoformat(d['run_started_at'].replace('Z','+00:00'))
mins=round((dt.datetime.now(dt.timezone.utc)-s).total_seconds()/60,1)
print(f\"{d.get('status')} {d.get('conclusion')} elapsed={mins}min\")
" 2>/dev/null)

  if [ "$cur" != "$prev" ]; then
    echo "$(date -u +%H:%M:%S) $cur" >> "$OUT"
    prev="$cur"
  fi

  case "$cur" in
    completed\ *) echo "$(date -u +%H:%M:%S) DONE" >> "$OUT"; exit 0 ;;
  esac
  sleep 60
done
echo "$(date -u +%H:%M:%S) gave up after 240 polls" >> "$OUT"
