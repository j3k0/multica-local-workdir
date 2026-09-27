#!/usr/bin/env bash
# Create/patch each selected agent's Hindsight bank, then import its mental models.
# Reads ./manifest.json (copy ./manifest.json.example and fill it in).
# Idempotent: PUT/PATCH are upserts, /import matches mental models by id.
#   ONLY=<name|bank regex> ./create-banks.sh   # restrict (canary)
#   MANIFEST=<path> ./create-banks.sh          # alternate manifest
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
MANIFEST="${MANIFEST:-manifest.json}"
[ -f "$MANIFEST" ] || { echo "$MANIFEST not found; copy manifest.json.example to manifest.json and fill it in" >&2; exit 1; }
API="${HINDSIGHT_API:-$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['hindsight_api'])" "$MANIFEST")}"
ONLY="${ONLY:-}"
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

n=0
while read -r row; do
  d() { echo "$row" | base64 --decode | jq -r "$1"; }
  bank="$(d .bank_id)"; reflect="$(d .reflect_mission)"; retain="$(d .retain_mission)"; obs="$(d .observations_mission)"
  printf '%-28s ' "$bank"
  code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X PUT "$API/v1/default/banks/$bank" \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg r "$reflect" --arg t "$retain" '{reflect_mission:$r,retain_mission:$t}')")
  pcode=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X PATCH "$API/v1/default/banks/$bank/config" \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg o "$obs" '{updates:{observations_mission:$o}}')")
  mm="$(echo "$row" | base64 --decode | jq -c '.mental_models')"
  icode=$(curl -sS -m 90 -o /dev/null -w '%{http_code}' -X POST "$API/v1/default/banks/$bank/import" \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --argjson mm "$mm" '{version:"1", mental_models:$mm}')")
  echo "PUT=$code PATCH=$pcode IMPORT=$icode"
  n=$((n+1))
done < <(jq -r --arg only "$ONLY" \
  '.agents[] | select(.selected)
   | select($only == "" or (.bank_id | test($only; "i")) or (.name | test($only; "i")))
   | @base64' "$MANIFEST")
echo "done: $n banks"
