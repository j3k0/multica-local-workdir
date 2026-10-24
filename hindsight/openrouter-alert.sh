#!/usr/bin/env bash
# Alert when Hindsight's OpenRouter credit runs low or out (FOV-2242).
#  1. Always: any "402 Payment Required" from openrouter.ai in the hindsight logs (last 20 min) = out of credit.
#  2. If $OPENROUTER_MGMT_KEY is set (management key; only it can read the account balance):
#     balance below $OPENROUTER_MIN_USD (default 10) = low credit.
# Alert = one open Multica issue assigned to JC (found by metadata alert_key); no repeat while it is open.
# Usage: openrouter-alert.sh [--dry-run]
set -uo pipefail
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
MIN="${OPENROUTER_MIN_USD:-10}"
export MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID:-7253250f-2139-4450-811b-2f08dd69a242}"
problem=""

n402=$(docker logs --since 20m hindsight 2>&1 | grep -c "402 Payment Required' for url 'https://openrouter.ai" || true)
(( n402 > 0 )) && problem="OpenRouter is refusing requests for lack of credit: $n402 HTTP 402 error(s) in the Hindsight logs in the last 20 min. Every agent is running without memory until credit is added."

if [[ -z "$problem" && -n "${OPENROUTER_MGMT_KEY:-}" ]]; then
  resp=$(mktemp)
  code=$(curl -sS -m 20 -o "$resp" -w '%{http_code}' -H "Authorization: Bearer $OPENROUTER_MGMT_KEY" \
    https://openrouter.ai/api/v1/credits) || code=000
  case "$code" in
    200) bal=$(jq -r '.data.total_credits - .data.total_usage' "$resp")
         echo "balance: \$$bal (threshold \$$MIN)"
         if awk -v b="$bal" -v m="$MIN" 'BEGIN{exit !(b < m)}'; then
           problem="OpenRouter balance is \$$(printf '%.2f' "$bal"), below the \$$MIN threshold. Hindsight recall stops when it reaches zero."
         fi;;
    401) echo "credits check: authentication failed (management key rejected)" >&2;;
    403) echo "credits check: permission denied (key is not a management key?)" >&2;;
    *)   echo "credits check: HTTP $code $(head -c 300 "$resp")" >&2;;
  esac
  rm -f "$resp"
fi

[[ -z "$problem" ]] && { echo "ok (402s in last 20 min: $n402)"; exit 0; }
echo "ALERT: $problem"
(( DRY )) && exit 0

open=$(multica issue list --metadata "alert_key=openrouter-credit" --limit 50 --output json --fields id,status 2>/dev/null \
  | jq -r '(if type=="object" then .issues else . end)[] | select(.status|IN("cancelled","done","released")|not) | .id' | head -1)
[[ -n "$open" ]] && { echo "already open: $open"; exit 0; }
f=$(mktemp)
printf '%s\n\n%s\n\n%s\n' \
  "TL;DR: OpenRouter credit for Hindsight (shared agent memory) is low or exhausted. Top up at https://openrouter.ai/settings/credits." \
  "$problem" \
  "Raised by \`hindsight/openrouter-alert.sh\` on devbox3 (timer \`openrouter-alert.timer\`, FOV-2242). It stays quiet while this issue is open; close it once the credit is topped up." > "$f"
new=$(multica issue create --title "OPS: OpenRouter credit low for Hindsight" --description-file "$f" --allow-external-file \
  --assignee JC --priority urgent --output json | jq -r .id)
rm -f "$f"
[[ -n "$new" && "$new" != null ]] || { echo "FAILED to create alert issue" >&2; exit 1; }
multica issue metadata set "$new" --key alert_key --value openrouter-credit >/dev/null
echo "created alert issue $new"
