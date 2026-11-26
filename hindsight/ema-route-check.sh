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
#     row-count canary alone could not tell "quiet" from "tracing off". The probe itself never
#     spends: its bank is held in the no-model set with rerank off, the recall runs only when
#     rerank=false is verified (FOV-3011), and connectivity blips alert only after two consecutive
#     runs (FOV-3011).
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
cenv=$(docker inspect hindsight --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)
routes=$(sed -n 's/^HINDSIGHT_API_LLM_REQUEST_BANK_MODELS=//p' <<<"$cenv")
alias=$(tr ',' '\n' <<<"$routes" | sed -n "s/^$bank=\([^=]*\)$/\1/p" | head -1)
# Tracing must reach llm_requests unfiltered, or calls stop landing in the table while the probe
# keeps tracing its own scope: every check that reads the table goes blind (FOV-3011). Unset is
# enabled and traces all scopes; only a value that turns it off or narrows scopes is a problem.
if [[ -n "$cenv" ]]; then
  tstate=$(sed -n 's/^HINDSIGHT_API_LLM_TRACE_ENABLED=//p' <<<"$cenv")
  tscopes=$(sed -n 's/^HINDSIGHT_API_LLM_TRACE_SCOPES=//p' <<<"$cenv")
  txscopes=$(sed -n 's/^HINDSIGHT_API_LLM_TRACE_EXCLUDE_SCOPES=//p' <<<"$cenv")
  if [[ -n "$(tr -d '[:space:]' <<<"$tscopes$txscopes")" ]]; then
    problems+=("HINDSIGHT_API_LLM_TRACE{,_EXCLUDE}_SCOPES are set (scopes=$tscopes exclude=$txscopes): calls outside those scopes stop landing in llm_requests and the hosted-call check can go blind")
  elif [[ -n "$tstate" && "$(tr -d '[:space:]' <<<"$tstate" | tr '[:upper:]' '[:lower:]')" != true ]]; then
    problems+=("HINDSIGHT_API_LLM_TRACE_ENABLED=$tstate (want unset or true): llm_requests tracing is off, the hosted-call check is blind")
  fi
fi
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

# Tracing probe (FOV-3010, hardened in FOV-3011): a recall on a scratch bank must leave a NEW
# llm_requests row since this run started -- its query embedding. That proves the write path
# behind the hosted-call check regardless of traffic: server-wide row counts are legitimately
# zero for up to ~70 min in quiet hours (the old canary false-alerted at night), but a real
# recall always traces. Rows are written by the tracing buffer (flushed every 0.5 s), so they
# can land after the 200 response: counting a baseline first and requiring an increase, with the
# 3 s retry, is what makes the check sound -- and it keeps a same-minute sibling timer run from
# passing on the other run's row (both timers fire on *:0/15, FOV-3011).
PROBE_BANK=route-check-probe   # scratch: no memories; held in the no-model set below, rerank off
# Connectivity-class probe failures (no HTTP answer for our calls, psql refuses) alert only on
# the second consecutive run: a single-run blip used to open an urgent issue that silenced the
# whole check until a human closed it (FOV-3002 pattern). Definitive failures (401/403/HTTP,
# no row) alert at once. State file like openrouter-alert.sh, cleared on every clean verdict.
PROBE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ema-route-check"; mkdir -p "$PROBE_STATE_DIR"
PROBE_DOWN="$PROBE_STATE_DIR/probe-connectivity-failed"
probe_conn_fail() {  # 0: second consecutive failure, alert now; 1: recorded, stay quiet this run
  if [[ -e "$PROBE_DOWN" ]]; then rm -f "$PROBE_DOWN"; problems+=("$1"); return 0; fi
  printf '%s\n' "first failure at $(date -u '+%FT%TZ'): $1" >"$PROBE_DOWN" 2>/dev/null || true
  echo "probe connectivity failure, not alerting yet (one more run opens an alert): $1"; return 1
}
probe_ok() { rm -f "$PROBE_DOWN" 2>/dev/null || true; }
probe_rows() { docker exec hindsight sh -c 'PGPASSWORD=$(python3 -c "import json;print(json.load(open(\"/home/hindsight/.pg0/instances/hindsight/instance.json\"))[\"password\"])") \
  /home/hindsight/.pg0/installation/*/bin/psql -h 127.0.0.1 -U hindsight -d hindsight -Atc \
  "select count(*) from llm_requests where bank_id='"'"'$0'"'"' and started_at > now()-interval '"'"'5 minutes'"'"'"' "$PROBE_BANK" 2>&1; }
before=$(probe_rows)   # baseline: both timers can put their rows inside this 5-min window
proceed=1              # recall only once enable_reranking=false is verified for this run
pcode=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X PUT "$HS/banks/$PROBE_BANK" \
  -H 'content-type: application/json' -d "{\"name\":\"$PROBE_BANK\"}")
if [[ "$pcode" == 000 ]]; then
  probe_conn_fail "probe bank $PROBE_BANK unreachable (HTTP 000)" || true; proceed=0
elif [[ "$pcode" != 2* ]]; then
  probe_ok; problems+=("creating probe bank $PROBE_BANK: HTTP $pcode"); proceed=0
else
  pcfg=$(curl -s -m 20 -w '\n%{http_code}' "$HS/banks/$PROBE_BANK/config")
  pcode=${pcfg##*$'\n'}
  pstate=$(jq -r '.config | "\(.enable_reranking) \(.retain_extraction_mode) \(.enable_observations) \(.enable_auto_consolidation)"' <<<"${pcfg%$'\n'*}" 2>/dev/null)
  if [[ "$pcode" == 401 ]]; then
    probe_ok; problems+=("reading $PROBE_BANK config: authentication failed (HTTP 401)"); proceed=0
  elif [[ "$pcode" == 403 ]]; then
    probe_ok; problems+=("reading $PROBE_BANK config: permission denied (HTTP 403)"); proceed=0
  elif [[ "$pcode" != 200 ]]; then
    if [[ "$pcode" == 000 ]]; then probe_conn_fail "reading $PROBE_BANK config: no response (HTTP 000)" || true
    else probe_ok; problems+=("reading $PROBE_BANK config: HTTP $pcode ${pcfg%$'\n'*}"); fi
    proceed=0
  elif [[ "$pstate" == "false chunks false false" ]]; then
    probe_ok
  else
    # One PATCH for all four: rerank off (recalls would rerank on OpenRouter) plus the agent-ema
    # no-model set, so any stray retain into the bank stays in house (FOV-2962, FOV-3011).
    # Status-checked and re-read back: a failed PATCH silently spent hosted money per recall.
    ppatch=$(curl -s -m 20 -w '\n%{http_code}' -X PATCH "$HS/banks/$PROBE_BANK/config" \
      -H 'content-type: application/json' \
      -d '{"updates":{"enable_reranking":false,"retain_extraction_mode":"chunks","enable_observations":false,"enable_auto_consolidation":false}}')
    ppc=${ppatch##*$'\n'}
    if [[ "$ppc" == 401 ]]; then
      probe_ok; problems+=("PATCHing $PROBE_BANK config: authentication failed (HTTP 401): probe recalls would rerank on OpenRouter"); proceed=0
    elif [[ "$ppc" == 403 ]]; then
      probe_ok; problems+=("PATCHing $PROBE_BANK config: permission denied (HTTP 403): probe recalls would rerank on OpenRouter"); proceed=0
    elif [[ "$ppc" != 200 ]]; then
      if [[ "$ppc" == 000 ]]; then probe_conn_fail "PATCHing $PROBE_BANK config: no response (HTTP 000)" || true
      else probe_ok; problems+=("PATCHing $PROBE_BANK config failed (HTTP $ppc): probe recalls would rerank on OpenRouter"); fi
      proceed=0
    else
      pver=$(curl -s -m 20 -w '\n%{http_code}' "$HS/banks/$PROBE_BANK/config")
      pvc=${pver##*$'\n'}
      vstate=$(jq -r '.config | "\(.enable_reranking) \(.retain_extraction_mode) \(.enable_observations) \(.enable_auto_consolidation)"' <<<"${pver%$'\n'*}" 2>/dev/null)
      if [[ "$vstate" == "false chunks false false" ]]; then
        probe_ok
      elif [[ "${vstate%% *}" != false ]]; then
        # Rerank is what spends: without a verified rerank=false the recall would create
        # OpenRouter spend, so skip it and let the alert issue carry the reason (FOV-3011).
        if [[ "$pvc" == 000 ]]; then probe_conn_fail "verifying $PROBE_BANK config after PATCH: no response (HTTP 000)" || true
        else
          probe_ok
          if [[ "$pvc" == 401 || "$pvc" == 403 ]]; then
            problems+=("verifying $PROBE_BANK config after the rerank-off PATCH: HTTP $pvc -- rerank state unknown, recall skipped")
          else
            problems+=("$PROBE_BANK rerank still on after the rerank-off PATCH (config: $vstate): probe recalls would rerank on OpenRouter -- hosted spend, recall skipped")
          fi
        fi
        proceed=0
      else
        probe_ok  # rerank off, but the no-model settings did not take: recall itself is safe
        problems+=("$PROBE_BANK no-model settings did not take after PATCH (config: $vstate, want 'false chunks false false'): a future retain into it would use the hosted model")
      fi
    fi
  fi
fi
if (( proceed )); then
  probe=$(curl -s -m 60 -w '\n%{http_code}' -X POST "$HS/banks/$PROBE_BANK/memories/recall" \
    -H 'content-type: application/json' -d '{"query":"route check tracing probe"}')
  pcode=${probe##*$'\n'}
  if [[ -z "$pcode" ]]; then
    probe_conn_fail "recall tracing probe got no response (recall endpoint unreachable or timed out)" || true
  elif [[ "$pcode" == 401 ]]; then
    probe_ok; problems+=("recall tracing probe: authentication failed (HTTP 401)")
  elif [[ "$pcode" == 403 ]]; then
    probe_ok; problems+=("recall tracing probe: permission denied (HTTP 403)")
  elif [[ "$pcode" != 200 ]]; then
    probe_ok; pbody=${probe%$'\n'*}; problems+=("recall tracing probe: HTTP $pcode ${pbody:0:200}")
  else
    prow=$(probe_rows)
    # Equal to baseline (or zero with a failed baseline) can mean the buffered row is not in yet.
    if [[ "$prow" == "$before" || ( ! "$before" =~ ^[0-9]+$ && "$prow" == 0 ) ]]; then sleep 3; prow=$(probe_rows); fi
    if [[ ! "$prow" =~ ^[0-9]+$ ]]; then
      probe_conn_fail "cannot read llm_requests for the tracing probe (got: ${prow:0:150})" || true
    elif [[ ( "$before" =~ ^[0-9]+$ && "$prow" -le "$before" ) || "$prow" == 0 ]]; then
      probe_ok
      problems+=("recall tracing probe succeeded but llm_requests gained no NEW row (after=$prow, baseline=${before:-failed}): LLM tracing is off, so the hosted-call check is blind")
    else
      probe_ok
    fi
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
