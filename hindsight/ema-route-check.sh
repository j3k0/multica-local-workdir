#!/usr/bin/env bash
# Alert if Ema's Hindsight memory could be going to a hosted LLM again (FOV-2945, register row K2).
# The bank_llm_routes extension sends the bank's LLM calls in house; this catches the ways that
# silently stops (an upgrade, a compose edit, a bank rename):
#  1. Ema's bank (LiteLLM key $EMA_KEY_ALIAS, metadata hindsight_bank) is not in the route map.
#  2. The extension did not log its route map since the container last started.
#  3. Reranking is back on for the bank (that path goes to OpenRouter).
#  4. The bank had retain/consolidation activity in the last 20 min but no routed call in 60 min.
# LiteLLM_SpendLogs can't help here: Hindsight's rows carry no bank id, and other banks use the
# hosted `memory` alias with the same key all the time.
# Alert = one open urgent Multica issue (metadata alert_key=ema-hindsight-route), assigned to DSA.
# Usage: ema-route-check.sh [--dry-run]
set -uo pipefail
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
KEY_ALIAS="${EMA_KEY_ALIAS:-agent/ema}"
HS=http://127.0.0.1:18888/v1/default
DSA_ID=4c8d7afb-acdc-4f89-a96a-3ff709b2959c
export MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID:-7253250f-2139-4450-811b-2f08dd69a242}"
problems=()

# EMA_BANK overrides the lookup (tests only).
bank=${EMA_BANK:-$(docker exec litellm-postgres psql -U litellm -d litellm -Atc \
  "select metadata->>'hindsight_bank' from \"LiteLLM_VerificationToken\" where key_alias='$KEY_ALIAS'" 2>&1)}
if [[ ! "$bank" =~ ^[a-z0-9-]+$ ]]; then
  problems+=("cannot read the bank of key $KEY_ALIAS from LiteLLM (got: ${bank:0:100})"); bank=""
fi
routes=$(docker inspect hindsight --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | sed -n 's/^HINDSIGHT_API_LLM_REQUEST_BANK_MODELS=//p')
if [[ -n "$bank" ]] && ! tr ',' '\n' <<<"$routes" | grep -qx "$bank=[^=]*"; then
  problems+=("bank $bank is not in HINDSIGHT_API_LLM_REQUEST_BANK_MODELS (\"$routes\"): its LLM calls use the hosted server model")
fi

started=$(docker inspect hindsight --format '{{.State.StartedAt}}' 2>/dev/null)
if [[ -z "$started" ]]; then
  problems+=("cannot inspect the hindsight container")
elif [[ -n "$bank" ]]; then
  until=$(date -u -d "$started + 10 minutes" +%FT%TZ)
  # grep -c, not -q: -q exits early and pipefail would report docker's SIGPIPE as a miss.
  n=$(docker logs --since "$started" --until "$until" hindsight 2>&1 | grep -c "bank_llm_routes: routing .*'$bank'")
  if (( n == 0 )); then
    problems+=("the bank_llm_routes extension did not log a route for $bank when hindsight started ($started)")
  fi
fi

if [[ -n "$bank" ]]; then
  cfg=$(curl -s -m 20 -w '\n%{http_code}' "$HS/banks/$bank/config")
  code=${cfg##*$'\n'}
  if [[ "$code" != 200 ]]; then problems+=("reading $bank config: HTTP $code ${cfg:0:200}")
  elif [[ $(jq -r '.config.enable_reranking' <<<"${cfg%$'\n'*}") != false ]]; then
    problems+=("enable_reranking is not false on $bank: its recalls are reranked on OpenRouter")
  fi
  active=$(docker logs --since 20m hindsight 2>&1 | grep -cE "RETAIN_BATCH START: $bank\$|\[CONSOLIDATION\] bank=$bank llm_batch")
  routed=$(docker logs --since 60m hindsight 2>&1 | grep -c "bank_llm_routes: bank=$bank ")
  if (( active > 0 && routed == 0 )); then
    problems+=("$bank had $active retain/consolidation batch(es) in 20 min but no routed LLM call in 60 min")
  fi
fi

(( ${#problems[@]} == 0 )) && { echo "ok (bank=$bank)"; exit 0; }
problem=$(printf -- '- %s\n' "${problems[@]}")
echo "ALERT:"; echo "$problem"
(( DRY )) && exit 0

if ! list=$(multica issue list --metadata "alert_key=ema-hindsight-route" --limit 50 --output json --fields id,status); then
  echo "multica issue list failed; not creating an issue (would risk duplicates)" >&2; exit 1
fi
open=$(jq -r '(if type=="object" then .issues else . end)[] | select(.status|IN("cancelled","done","released")|not) | .id' <<<"$list" | head -1) \
  || { echo "cannot parse multica issue list output" >&2; exit 1; }
[[ -n "$open" ]] && { echo "already open: $open"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cd "$tmp"
printf '%s\n\n%s\n\n%s\n' \
  "TL;DR: Ema's Hindsight memory may be using hosted models again, which reopens register row K2 (FOV-2938). Fix the routing (runbook: multica-local-workdir hindsight/README.md, \"Per-bank LLM routing\")." \
  "$problem" \
  "Raised by \`hindsight/ema-route-check.sh\` on devbox3 (timer \`ema-route-check.timer\`, FOV-2945). It stays quiet while this issue is open." > description.md
out=$(multica issue create --title "OPS: Ema's Hindsight memory may be leaving the house" --description-file description.md \
  --assignee-id "$DSA_ID" --priority urgent --output json) || { echo "FAILED to create alert issue" >&2; exit 1; }
new=$(jq -er .id <<<"$out") || { echo "created an issue but cannot parse its id" >&2; exit 1; }
multica issue metadata set "$new" --key alert_key --value ema-hindsight-route >/dev/null \
  || { echo "created $new but metadata set failed: the next run may duplicate it" >&2; exit 1; }
echo "created alert issue $new"
