#!/usr/bin/env bash
# Alert when Hindsight's OpenRouter credit runs low or out (FOV-2242).
#  1. Always: a new "402 Payment Required" from openrouter.ai in the hindsight logs = out of credit.
#     402 lines already alerted on are remembered (state file), so they never re-alert.
#  2. If $OPENROUTER_MGMT_KEY is set (management key; only it can read the account balance):
#     balance below $OPENROUTER_MIN_USD (default 10) = low credit.
#  If the logs can't be read, that is a separate alert ("logs unreadable", not a credit problem).
# Alert = one open Multica issue per kind, assigned to JC. Dedupe: the id saved in $STATE/open-<kind>
# right after create (checked with `issue get`), plus metadata alert_key. No repeat while it is open.
# Accepted residual risk: if this script itself fails on every run (e.g. Multica auth expired),
# nothing notices. Same class as the FOV-2067 dead-man; not built.
# Usage: openrouter-alert.sh [--dry-run]
set -uo pipefail
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
MIN="${OPENROUTER_MIN_USD:-10}"
JC_ID=315a9855-3e18-440e-b9bb-a5b4ed38bd54
export MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID:-7253250f-2139-4450-811b-2f08dd69a242}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/openrouter-alert"; mkdir -p "$STATE"
LAST="$STATE/last-402"   # docker timestamp of the newest 402 line already alerted on
# Compared at whole-second precision (first 19 chars, fixed width): docker trims trailing zeros
# from the fraction, so full strings don't sort. A second 402 in the same second is ignored.
problem=""; newest=""; kind=credit

if ! logs=$(docker logs --timestamps --since 20m hindsight 2>&1); then
  kind=logs
  problem="Cannot read the hindsight container logs, so the OpenRouter credit check is blind: $(head -c 200 <<<"$logs")"
else
  seen=$(cat "$LAST" 2>/dev/null || true)
  new402=$(grep "402 Payment Required' for url 'https://openrouter.ai" <<<"$logs" | awk -v s="${seen:0:19}" 'substr($1,1,19) > s' || true)
  if [[ -n "$new402" ]]; then
    newest=$(tail -1 <<<"$new402" | cut -d' ' -f1)
    problem="OpenRouter is refusing requests for lack of credit: $(wc -l <<<"$new402") new HTTP 402 error(s) in the Hindsight logs (latest $newest). Every agent is running without memory until credit is added."
  fi
fi

if [[ -z "$problem" && -n "${OPENROUTER_MGMT_KEY:-}" ]]; then
  resp=$(mktemp)
  # Header via stdin, so the key never appears in /proc/*/cmdline.
  code=$(printf 'Authorization: Bearer %s\n' "$OPENROUTER_MGMT_KEY" | curl -sS -m 20 -o "$resp" -w '%{http_code}' \
    -H @- https://openrouter.ai/api/v1/credits) || code=000
  case "$code" in
    200) bal=$(jq -er '.data.total_credits - .data.total_usage' "$resp" 2>/dev/null || true)
         if [[ ! "$bal" =~ ^-?[0-9.eE+-]+$ ]]; then
           echo "credits check: unreadable balance in HTTP 200 response" >&2
         else
           echo "balance: \$$bal (threshold \$$MIN)"
           if awk -v b="$bal" -v m="$MIN" 'BEGIN{exit !(b < m)}'; then
             problem="OpenRouter balance is \$$(printf '%.2f' "$bal"), below the \$$MIN threshold. Hindsight recall stops when it reaches zero."
           fi
         fi;;
    401) echo "credits check: authentication failed (management key rejected)" >&2;;
    403) echo "credits check: permission denied (key is not a management key?)" >&2;;
    *)   echo "credits check: HTTP $code $(head -c 300 "$resp")" >&2;;
  esac
  rm -f "$resp"
fi

[[ -z "$problem" ]] && { echo "ok"; exit 0; }
echo "ALERT: $problem"
(( DRY )) && exit 0

if [[ $kind == credit ]]; then
  KEY=openrouter-credit; TITLE="OPS: OpenRouter credit low for Hindsight"
  TLDR="TL;DR: OpenRouter credit for Hindsight (shared agent memory) is low or exhausted. Top up at https://openrouter.ai/settings/credits."
else
  KEY=hindsight-logs-unreadable; TITLE="OPS: Hindsight credit alert is blind (cannot read container logs)"
  TLDR="TL;DR: the OpenRouter credit alert cannot read the hindsight container logs. This is a docker/container problem on devbox3, not a credit problem."
fi
OPEN="$STATE/open-$kind"   # id of the alert issue we created ("pending" while create is in flight)

closed() { [[ "$1" =~ ^(cancelled|done|released)$ ]]; }
if [[ -f "$OPEN" ]]; then
  id=$(cat "$OPEN")
  if [[ "$id" == pending ]]; then
    if [[ -n "$(find "$OPEN" -mmin -360)" ]]; then
      echo "a previous create has unknown outcome ($OPEN = pending, <6 h old); not creating" >&2; exit 1
    fi
    rm -f "$OPEN"
  elif ! st=$(multica issue get "$id" --output json | jq -er .status); then
    echo "cannot read alert issue $id; not creating" >&2; exit 1
  elif closed "$st"; then rm -f "$OPEN"
  else echo "already open: $id"; [[ -n "$newest" ]] && echo "$newest" > "$LAST"; exit 0
  fi
fi
# Fallback by metadata. One page (50) of alert_key matches; enough while closed alerts stay few.
if ! list=$(multica issue list --metadata "alert_key=$KEY" --limit 50 --output json --fields id,status); then
  echo "multica issue list failed; not creating an issue (would risk duplicates)" >&2; exit 1
fi
open=$(jq -r '(if type=="object" then .issues else . end)[] | select(.status|IN("cancelled","done","released")|not) | .id' <<<"$list" | head -1) \
  || { echo "cannot parse multica issue list output; not creating an issue" >&2; exit 1; }
if [[ -n "$open" ]]; then
  echo "already open: $open"; echo "$open" > "$OPEN"
else
  cd "$STATE"
  printf '%s\n\n%s\n\n%s\n' "$TLDR" "$problem" \
    "Raised by \`hindsight/openrouter-alert.sh\` on devbox3 (timer \`openrouter-alert.timer\`, FOV-2242). It stays quiet while this issue is open; close it once fixed." > description.md
  echo pending > "$OPEN"
  out=$(multica issue create --title "$TITLE" --description-file description.md \
    --assignee-id "$JC_ID" --priority urgent --output json) || { rm -f description.md; echo "FAILED to create alert issue (outcome unknown, $OPEN left pending)" >&2; exit 1; }
  rm -f description.md
  new=$(jq -er .id <<<"$out") || { echo "created an issue but cannot parse its id ($OPEN left pending)" >&2; exit 1; }
  echo "$new" > "$OPEN"
  multica issue metadata set "$new" --key alert_key --value "$KEY" >/dev/null \
    || { echo "created $new but metadata set failed (deduped via $OPEN)" >&2; exit 1; }
  echo "created alert issue $new"
fi
[[ -n "$newest" ]] && echo "$newest" > "$LAST"
exit 0
