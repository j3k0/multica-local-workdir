#!/usr/bin/env bash
# FOV-2242: keep trigger.refresh_after_consolidation=false on every Hindsight mental model.
# Run by hindsight-refresh.service before each refresh run, because omp clients still seed new
# banks with refresh_after_consolidation=true (e.g. agent-dsa, 2026-10-25).
# Usage: refresh-off.sh [--apply] [--only BANK/ID] [false|true]
#   default: dry run, value=false. --only limits to one model (canary).
#   "true" = rollback; it re-enables the refresh spend this issue removed.
# Sends the model's full existing trigger with only the flag changed, so mode/filters are preserved.
# Hindsight >= 1.1: banks are paginated (limit up to 1000) and model lists omit `trigger` unless
# detail=content. A model whose trigger is still null is reported and never PATCHed.
set -euo pipefail
A="${HINDSIGHT_API:-http://127.0.0.1:18888}"
APPLY=0; ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift;;
    --only) ONLY="$2"; shift 2;;
    *) break;;
  esac
done
(( $# <= 1 )) || { echo "unexpected arguments: $* (options go before the value)" >&2; exit 2; }
VAL="${1:-false}"
[[ "$VAL" == false || "$VAL" == true ]] || { echo "value must be true or false (options go first: --apply true)" >&2; exit 2; }
[[ -z "$ONLY" || "$ONLY" =~ ^[^/]+/[^/]+$ ]] || { echo "--only expects BANK/ID" >&2; exit 2; }
ok=0; skip=0; fail=0; dry=0
# Fails (exit 1) if the server returned fewer rows than its own .total (page capped below limit).
banks=$(curl -fsS -m 30 "$A/v1/default/banks?limit=1000" | jq -er 'if (.banks|length) == .total then .banks[].bank_id else error("bank list truncated") end')
[[ -n "$ONLY" ]] && banks="${ONLY%%/*}"
for b in $banks; do
  models=$(curl -fsS -m 30 "$A/v1/default/banks/$b/mental-models?detail=content&limit=1000" | jq -ec 'if (.items|length) == .total then [.items[] | {id, trigger}] else error("model list truncated") end')
  while read -r m; do
    id=$(jq -r .id <<<"$m")
    [[ -n "$ONLY" && "$b/$id" != "$ONLY" ]] && continue
    if [[ $(jq -r '.trigger|type' <<<"$m") != object ]]; then
      echo "FAIL $b/$id trigger not returned; not patching"; fail=$((fail+1)); continue
    fi
    cur=$(jq -r .trigger.refresh_after_consolidation <<<"$m")
    if [[ "$cur" == "$VAL" ]]; then skip=$((skip+1)); continue; fi
    body=$(jq -c --argjson v "$VAL" '{trigger: (.trigger + {refresh_after_consolidation: $v})}' <<<"$m")
    if (( ! APPLY )); then echo "DRY  $b/$id $cur -> $VAL"; dry=$((dry+1)); continue; fi
    resp=$(mktemp); code=$(curl -sS -m 30 -o "$resp" -w '%{http_code}' -X PATCH \
      -H 'Content-Type: application/json' --data "$body" "$A/v1/default/banks/$b/mental-models/$id") || code=000
    case "$code" in
      200) echo "OK   $b/$id $cur -> $VAL"; ok=$((ok+1));;
      401) echo "FAIL $b/$id authentication failed"; fail=$((fail+1));;
      403) echo "FAIL $b/$id permission denied"; fail=$((fail+1));;
      *)   echo "FAIL $b/$id HTTP $code $(head -c 300 "$resp")"; fail=$((fail+1));;
    esac; rm -f "$resp"
  done < <(jq -c '.[]' <<<"$models")
done
echo "TOTAL ok=$ok dry=$dry already=$skip fail=$fail"
(( fail == 0 ))
