#!/usr/bin/env bash
# Refresh Hindsight mental models once a day instead of after every consolidation (FOV-2242).
# Run hourly. A model is refreshed only if its bank consolidated since its last refresh AND
# both its last refresh and our last attempt on it are older than MIN_AGE seconds
# (default 86400 = daily; 3600 = hourly). The attempt record (state dir) means a queued or
# failing refresh is not re-posted every hour: at most one attempt per model per MIN_AGE.
# Skips the whole run while recall is failing (any RECALL ERROR in the last 10 min), or if the
# logs can't be read, so models are never rebuilt from stale content.
# Usage: daily-refresh.sh [--apply]   (default: dry run)
set -euo pipefail
A="${HINDSIGHT_API:-http://127.0.0.1:18888}"
MIN_AGE="${MIN_AGE:-86400}"; now=$(date +%s)
APPLY=0; [[ "${1:-}" == "--apply" ]] && APPLY=1
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/hindsight-refresh"; mkdir -p "$STATE"
ts() { jq -r 'if . == null then 0 else sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | fromdateiso8601 end'; }

if ! logs=$(docker logs --since 10m hindsight 2>&1); then
  echo "SKIP RUN: cannot read hindsight logs: $(head -c 200 <<<"$logs")"; exit 1
fi
errs=$(grep -c 'RECALL ERROR' <<<"$logs" || true)
if (( errs > 0 )); then echo "SKIP RUN: $errs RECALL ERROR(s) in the last 10 min"; exit 0; fi

queued=0; fresh=0; fail=0
for b in $(curl -fsS -m 30 "$A/v1/default/banks" | jq -r '.banks[].bank_id'); do
  models=$(curl -fsS -m 30 "$A/v1/default/banks/$b/mental-models" | jq -c '.items')
  [[ "$models" == "[]" ]] && continue
  cons=$(curl -fsS -m 30 "$A/v1/default/banks/$b/stats" | jq '.last_consolidated_at' | ts)
  while read -r m; do
    id=$(jq -r .id <<<"$m"); last=$(jq '.last_refreshed_at' <<<"$m" | ts)
    tried=$(cat "$STATE/$b--$id" 2>/dev/null || echo 0)
    if (( last >= cons || now - last < MIN_AGE || now - tried < MIN_AGE )); then fresh=$((fresh+1)); continue; fi
    if (( ! APPLY )); then echo "DRY  $b/$id"; queued=$((queued+1)); continue; fi
    echo "$now" > "$STATE/$b--$id"
    resp=$(mktemp); code=$(curl -sS -m 30 -o "$resp" -w '%{http_code}' -X POST \
      "$A/v1/default/banks/$b/mental-models/$id/refresh")
    case "$code" in
      200|202) echo "OK   $b/$id"; queued=$((queued+1));;
      401) echo "FAIL $b/$id authentication failed"; fail=$((fail+1));;
      403) echo "FAIL $b/$id permission denied"; fail=$((fail+1));;
      *)   echo "FAIL $b/$id HTTP $code $(head -c 300 "$resp")"; fail=$((fail+1));;
    esac; rm -f "$resp"
  done < <(jq -c '.[] | {id, last_refreshed_at}' <<<"$models")
done
echo "TOTAL queued=$queued skipped=$fresh fail=$fail"
(( fail == 0 ))
