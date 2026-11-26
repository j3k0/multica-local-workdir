#!/usr/bin/env bash
# Alert if Ema's Hindsight memory could be going to a hosted LLM again (FOV-2945, register row K2).
# The bank_llm_routes extension sends the bank's LLM calls in house; this catches the ways that
# silently stops (an upgrade, a compose edit, a bank rename):
#  1. Ema's bank (LiteLLM key $EMA_KEY_ALIAS, metadata hindsight_bank) is not in the route map.
#  2. The extension did not log its route map since the container last started.
#  3. Reranking is back on for the bank (that path goes to OpenRouter), or one of the no-model
#     settings (FOV-2962) is undone: retain_extraction_mode=chunks, enable_observations=false,
#     enable_auto_consolidation=false.
#  4. Activity that means a model call (consolidation LLM batch, reflect, and retain outside
#     chunks mode) in the last 20 min but no routed call in 60 min.
#  5. Hindsight's own llm_requests log shows a call for the bank in the last 60 min on any model
#     other than its routed alias (hosted LLM or OpenRouter rerank). Rows carry the bank id;
#     LiteLLM_SpendLogs don't, so they can't be used for this. To trust this the server must be
#     seen writing llm_requests: the check recalls on a scratch bank, whose one query embedding
#     must land as a row. Quiet hours write no rows for ~70 min legitimately (FOV-3010), so a
#     row-count canary alone could not tell "quiet" from "tracing off".
# Alert = one open urgent Multica issue (metadata alert_key=$ALERT_KEY), assigned to DSA.
# Other banks: ROUTE_BANK=<bank> ALERT_KEY=<key> (no LiteLLM key lookup), e.g. agent-intern.
# Usage: ema-route-check.sh [--dry-run]
set -uo pipefail
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
KEY_ALIAS="${EMA_KEY_ALIAS:-agent/ema}"
HS=http://127.0.0.1:18888/v1/default
DSA_ID=4c8d7afb-acdc-4f89-a96a-3ff709b2959c
ALERT_KEY="${ALERT_KEY:-ema-hindsight-route}"
export MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID:-7253250f-2139-4450-811b-2f08dd69a242}"
problems=()

# ROUTE_BANK (or EMA_BANK, tests) skips the LiteLLM key lookup.
bank=${ROUTE_BANK:-${EMA_BANK:-}}
[[ -n "$bank" ]] || bank=$(docker exec litellm-postgres psql -U litellm -d litellm -Atc \
  "select metadata->>'hindsight_bank' from \"LiteLLM_VerificationToken\" where key_alias='$KEY_ALIAS'" 2>&1)
if [[ ! "$bank" =~ ^[a-z0-9-]+$ ]]; then
  problems+=("cannot read the bank of key $KEY_ALIAS from LiteLLM (got: ${bank:0:100})"); bank=""
fi
routes=$(docker inspect hindsight --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | sed -n 's/^HINDSIGHT_API_LLM_REQUEST_BANK_MODELS=//p')
alias=$(tr ',' '\n' <<<"$routes" | sed -n "s/^$bank=\([^=]*\)$/\1/p" | head -1)
if [[ -n "$bank" && -z "$alias" ]]; then
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
  if [[ "$code" == 401 ]]; then problems+=("reading $bank config: authentication failed (HTTP 401)")
  elif [[ "$code" == 403 ]]; then problems+=("reading $bank config: permission denied (HTTP 403)")
  elif [[ "$code" != 200 ]]; then problems+=("reading $bank config: HTTP $code ${cfg:0:200}")
  elif [[ $(jq -r '.config.enable_reranking' <<<"${cfg%$'\n'*}") != false ]]; then
    problems+=("enable_reranking is not false on $bank: its recalls are reranked on OpenRouter")
  fi
  mode=$(jq -r '.config.retain_extraction_mode' <<<"${cfg%$'\n'*}" 2>/dev/null)
  nomodel=$(jq -r '.config | "\(.retain_extraction_mode) \(.enable_observations) \(.enable_auto_consolidation)"' <<<"${cfg%$'\n'*}" 2>/dev/null)
  if [[ "$code" == 200 && "$nomodel" != "chunks false false" ]]; then
    problems+=("$bank no-model settings undone (mode/observations/auto-consolidation = $nomodel, want chunks false false; FOV-2962)")
  fi
  # Lines that mean a model call. Retain counts only outside chunks mode (chunks = no LLM).
  # Reflect's log id holds only 8 chars of the bank id, so reflect comes from llm_requests.
  pat="\[CONSOLIDATION\] bank=$bank llm_batch"
  [[ "$mode" != chunks ]] && pat+="|RETAIN_BATCH START: $bank\$"
  logs=$(docker logs --since 60m hindsight 2>&1)
  active=$(docker logs --since 20m hindsight 2>&1 | grep -cE "$pat")
  routed=$(grep -c "bank_llm_routes: bank=$bank " <<<"$logs")
  # Password stays inside the container.
  db=$(docker exec hindsight sh -c 'PGPASSWORD=$(python3 -c "import json;print(json.load(open(\"/home/hindsight/.pg0/instances/hindsight/instance.json\"))[\"password\"])") \
    /home/hindsight/.pg0/installation/*/bin/psql -h 127.0.0.1 -U hindsight -d hindsight -AtF" " -c "
    select count(*) filter (where operation='"'"'reflect'"'"' and started_at > now()-interval '"'"'20 minutes'"'"'),
           count(*) filter (where provider is distinct from '"'"'tei'"'"' and model is distinct from '"'"'$1'"'"')
    from llm_requests where bank_id='"'"'$0'"'"' and started_at > now()-interval '"'"'60 minutes'"'"'"' "$bank" "$alias" 2>&1)
  if [[ ! "$db" =~ ^[0-9]+\ [0-9]+$ ]]; then
    problems+=("cannot read Hindsight llm_requests for $bank (got: ${db:0:150})")
  else
    read -r reflects hosted <<<"$db"
    active=$((active + reflects))
    (( hosted > 0 )) && problems+=("$bank made $hosted LLM/rerank call(s) in 60 min on a model other than ${alias:-its route}: hosted model or OpenRouter rerank")
  fi
  if (( active > 0 && routed == 0 )); then
    problems+=("$bank had $active model-call event(s) (consolidation/reflect/retain) in 20 min but no routed LLM call in 60 min")
  fi
fi

# Tracing probe (FOV-3010): a recall on a scratch bank must leave one llm_requests row -- its
# query embedding. That proves the write path behind the hosted-call check regardless of traffic:
# server-wide row counts are legitimately zero for up to ~70 min in quiet hours (the old canary
# false-alerted at night), but a real recall always traces.
PROBE_BANK=route-check-probe   # scratch: no memories, rerank off; its rows are swept by retention
probe_rows() { docker exec hindsight sh -c 'PGPASSWORD=$(python3 -c "import json;print(json.load(open(\"/home/hindsight/.pg0/instances/hindsight/instance.json\"))[\"password\"])") \
  /home/hindsight/.pg0/installation/*/bin/psql -h 127.0.0.1 -U hindsight -d hindsight -Atc \
  "select count(*) from llm_requests where bank_id='"'"'$0'"'"' and started_at > now()-interval '"'"'5 minutes'"'"'"' "$PROBE_BANK" 2>&1; }
curl -s -m 20 -o /dev/null -X PUT "$HS/banks/$PROBE_BANK" -H 'content-type: application/json' -d "{\"name\":\"$PROBE_BANK\"}"
rcfg=$(curl -s -m 20 "$HS/banks/$PROBE_BANK/config" | jq -r '.config.enable_reranking')
[[ "$rcfg" == false ]] || curl -s -m 20 -o /dev/null -X PATCH "$HS/banks/$PROBE_BANK/config" \
  -H 'content-type: application/json' -d '{"updates":{"enable_reranking":false}}'
probe=$(curl -s -m 60 -w '\n%{http_code}' -X POST "$HS/banks/$PROBE_BANK/memories/recall" \
  -H 'content-type: application/json' -d '{"query":"route check tracing probe"}')
pcode=${probe##*$'\n'}
if [[ -z "$pcode" ]]; then
  problems+=("recall tracing probe got no response (recall endpoint unreachable or timed out)")
elif [[ "$pcode" == 401 ]]; then
  problems+=("recall tracing probe: authentication failed (HTTP 401)")
elif [[ "$pcode" == 403 ]]; then
  problems+=("recall tracing probe: permission denied (HTTP 403)")
elif [[ "$pcode" != 200 ]]; then
  pbody=${probe%$'\n'*}
  problems+=("recall tracing probe: HTTP $pcode ${pbody:0:200}")
else
  prow=$(probe_rows)   # the row lands with the query embedding, before the response
  if [[ "$prow" == 0 ]]; then sleep 3; prow=$(probe_rows); fi
  if [[ ! "$prow" =~ ^[0-9]+$ ]]; then
    problems+=("cannot read llm_requests for the tracing probe (got: ${prow:0:200})")
  elif (( prow == 0 )); then
    problems+=("recall tracing probe succeeded but wrote no llm_requests row: LLM tracing is off, so the hosted-call check is blind")
  fi
fi

(( ${#problems[@]} == 0 )) && { echo "ok (bank=$bank)"; exit 0; }
problem=$(printf -- '- %s\n' "${problems[@]}")
echo "ALERT:"; echo "$problem"
(( DRY )) && exit 0

if ! list=$(multica issue list --metadata "alert_key=$ALERT_KEY" --limit 50 --output json --fields id,status); then
  echo "multica issue list failed; not creating an issue (would risk duplicates)" >&2; exit 1
fi
open=$(jq -r '(if type=="object" then .issues else . end)[] | select(.status|IN("cancelled","done","released")|not) | .id' <<<"$list" | head -1) \
  || { echo "cannot parse multica issue list output" >&2; exit 1; }
[[ -n "$open" ]] && { echo "already open: $open"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cd "$tmp"
printf '%s\n\n%s\n\n%s\n' \
  "TL;DR: Hindsight bank $bank may be using hosted models again (Ema: register row K2, FOV-2938; Intern: FOV-2962). Fix the routing (runbook: multica-local-workdir hindsight/README.md, \"Per-bank LLM routing\")." \
  "$problem" \
  "Raised by \`hindsight/ema-route-check.sh\` on devbox3 (timer \`ema-route-check.timer\` or \`intern-route-check.timer\`, FOV-2945). It stays quiet while this issue is open." > description.md
out=$(multica issue create --title "OPS: Hindsight bank $bank may be leaving the house" --description-file description.md \
  --assignee-id "$DSA_ID" --priority urgent --output json) || { echo "FAILED to create alert issue" >&2; exit 1; }
new=$(jq -er .id <<<"$out") || { echo "created an issue but cannot parse its id" >&2; exit 1; }
multica issue metadata set "$new" --key alert_key --value "$ALERT_KEY" >/dev/null \
  || { echo "created $new but metadata set failed: the next run may duplicate it" >&2; exit 1; }
echo "created alert issue $new"
