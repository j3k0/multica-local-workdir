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
#     rerank=false is verified (FOV-3011), and connectivity blips alert only on the second
#     consecutive run of the same timer (per-alert-key state file, FOV-3011).
# Hindsight restarting looks identical to all five: its live reads fail (HTTP 000, connection
# refused) -- the 2026-11-25 restart opened two such alerts 7 s after the container boot
# (FOV-3002). A probe decides "up" (config HTTP < 500, and Hindsight's own Postgres answers
# "select 1"); down cycles stay quiet for up to 30 min of down time (restart grace,
# FOV-3002a -- maximum silence ~45 min with cycle timing), then alert as an outage instead.
# Down-state transitions also clear the probe's connectivity-debounce file: a blip armed
# before an outage must not alert right after the restart (FOV-3002a review).
# Alert = one open urgent Multica issue (metadata alert_key=$ALERT_KEY), assigned to DSA.
# Other banks: ROUTE_BANK=<bank> ALERT_KEY=<key> (no LiteLLM key lookup), e.g. agent-intern.
# Usage: ema-route-check.sh [--dry-run]   (--dry-run still records and clears down-since state)
set -uo pipefail
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
KEY_ALIAS="${EMA_KEY_ALIAS:-agent/ema}"
HS=http://127.0.0.1:18888/v1/default
DSA_ID=4c8d7afb-acdc-4f89-a96a-3ff709b2959c
ALERT_KEY="${ALERT_KEY:-ema-hindsight-route}"
[[ "$ALERT_KEY" =~ ^[a-z0-9-]+$ ]] || { echo "ALERT_KEY \"$ALERT_KEY\" is not safe for a state-file path" >&2; exit 1; }
export MULTICA_WORKSPACE_ID="${MULTICA_WORKSPACE_ID:-7253250f-2139-4450-811b-2f08dd69a242}"
problems=()

# ROUTE_BANK (or EMA_BANK, tests) skips the LiteLLM key lookup.
bank=${ROUTE_BANK:-${EMA_BANK:-}}
[[ -n "$bank" ]] || bank=$(docker exec -e PGCONNECT_TIMEOUT=10 litellm-postgres psql -U litellm -d litellm -Atc \
  "select metadata->>'hindsight_bank' from \"LiteLLM_VerificationToken\" where key_alias='$KEY_ALIAS'" 2>&1)
if [[ ! "$bank" =~ ^[a-z0-9-]+$ ]]; then
  problems+=("cannot read the bank of key $KEY_ALIAS from LiteLLM (got: ${bank:0:100})"); bank=""
fi
# Unreachability gate (FOV-3002a, PR #14 review): a restart looks like lost routing (HTTP 000,
# connection refused on the live reads) and false-alerted on 2026-11-25. "Up" has to cover a
# booting server, which can 503 or accept HTTP while its embedded Postgres is still
# initialising: up = config HTTP < 500 AND Hindsight's own Postgres answering "select 1". The
# first unreachable cycle records down-since and stays quiet; after $DOWN_GRACE of staying
# down (crash loop, OOM, dead container) it alerts on its own below -- so the maximum silence
# is the grace plus one 15-min cycle (~45 min). Successful cycles clear the record.
gate_url="$HS/banks/${bank:-route-check-probe}/config"
DOWN_GRACE=1800
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/hindsight-route-check"
state_file="$state_dir/down-$ALERT_KEY"
PROBE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ema-route-check"  # the probe's debounce file lives here (FOV-3011)
gate_db() { docker exec hindsight sh -c 'PGCONNECT_TIMEOUT=10 PGPASSWORD=$(python3 -c "import json;print(json.load(open(\"/home/hindsight/.pg0/instances/hindsight/instance.json\"))[\"password\"])") \
    /home/hindsight/.pg0/installation/*/bin/psql -h 127.0.0.1 -U hindsight -d hindsight -Atc "select 1"' 2>/dev/null; }
clear_probe_down() { rm -f "$PROBE_STATE_DIR/probe-connectivity-failed-$ALERT_KEY" 2>/dev/null; }
down_hard=""
gate_code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$gate_url" 2>/dev/null | tail -n1)
gate_db_out=""
[[ "$gate_code" != 000 && "$gate_code" -lt 500 ]] && gate_db_out=$(gate_db)
if [[ "$gate_db_out" == 1 ]]; then
  rm -f "$state_file" 2>/dev/null; clear_probe_down
elif [[ ! -s "$state_file" ]]; then
  mkdir -p "$state_dir" 2>/dev/null
  if date -u +%FT%TZ > "$state_file" 2>/dev/null && [[ -s "$state_file" ]]; then
    clear_probe_down
    echo "Hindsight unreachable (probe HTTP $gate_code): staying quiet until $((DOWN_GRACE / 60)) min of down time -- restart grace (FOV-3002a)"
    exit 0
  fi
  # cannot persist down-since: never risk permanent silence, alert now
  down_hard="no-state"
  problems+=("Hindsight unreachable (probe config HTTP $gate_code, db ${gate_db_out:-no answer}) and down-since cannot be persisted in $state_dir: alerting rather than staying silent")
else
  down_since=$(<"$state_file")
  now=$(date +%s)
  if ! since=$(date -d "$down_since" +%s 2>/dev/null) || (( since > now )); then
    # unparsable or from a clock jump: restart the grace clock rather than trust it
    date -u +%FT%TZ > "$state_file" 2>/dev/null || true; clear_probe_down
    echo "Hindsight unreachable (corrupt down-since record restarted): staying quiet until $((DOWN_GRACE / 60)) min of down time (FOV-3002a)"
    exit 0
  fi
  age=$(( now - since ))
  if (( age >= DOWN_GRACE )); then
    down_hard="grace-over"; mins=$(( age / 60 ))
    problems+=("Hindsight unreachable for $mins min (down since $down_since, probe config HTTP $gate_code, db ${gate_db_out:-no answer}): restart grace ($((DOWN_GRACE / 60)) min) over -- an outage, not a restart")
    # falls through to the create block; the live checks below are skipped (down_hard), they
    # would only repeat the connection errors
  else
    echo "Hindsight still unreachable since $down_since (${age}s): staying quiet until $((DOWN_GRACE / 60)) min of down time (FOV-3002a)"
    exit 0
  fi
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
if [[ -z "$down_hard" && -n "$bank" && -z "$alias" ]]; then
  problems+=("bank $bank is not in HINDSIGHT_API_LLM_REQUEST_BANK_MODELS (\"$routes\"): its LLM calls use the hosted server model")
fi

started=$(docker inspect hindsight --format '{{.State.StartedAt}}' 2>/dev/null)
if [[ -n "$down_hard" ]]; then :  # down-hard: the unreachability problem above is the whole report
elif [[ -z "$started" ]]; then
  problems+=("cannot inspect the hindsight container")
elif [[ -n "$bank" ]]; then
  until=$(date -u -d "$started + 10 minutes" +%FT%TZ)
  # grep -c, not -q: -q exits early and pipefail would report docker's SIGPIPE as a miss.
  n=$(docker logs --since "$started" --until "$until" hindsight 2>&1 | grep -c "bank_llm_routes: routing .*'$bank'")
  if (( n == 0 )); then
    problems+=("the bank_llm_routes extension did not log a route for $bank when hindsight started ($started)")
  fi
fi

if [[ -z "$down_hard" && -n "$bank" ]]; then
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
  db=$(docker exec hindsight sh -c 'PGCONNECT_TIMEOUT=10 PGPASSWORD=$(python3 -c "import json;print(json.load(open(\"/home/hindsight/.pg0/instances/hindsight/instance.json\"))[\"password\"])") \
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

# Hindsight restarting does not need the probe: no recall, no PATCH, no new probe state while
# the outage clock runs (FOV-3002a). The gate also clears the debounce file there.
if [[ -z "$down_hard" ]]; then
# Tracing probe (FOV-3010, hardened in FOV-3011). Skipped entirely on a down-hard cycle: the
# outage problem at the gate is the whole report. a recall on a scratch bank must leave a NEW
# llm_requests row since this run started -- its query embedding. That proves the write path
# behind the hosted-call check regardless of traffic: server-wide row counts are legitimately
# zero for up to ~70 min in quiet hours (the old canary false-alerted at night), but a real
# recall always traces. Rows are written by the tracing buffer (flushed every 0.5 s) and can
# land after the 200 response, so the count is taken against a timestamp read just before the
# recall, with one 3 s retry on a zero (FOV-3011 review): a sibling timer run's earlier row
# cannot count for this run, and no 5-min-window row can age out of the compare.
PROBE_BANK=route-check-probe   # scratch: no memories; held in the no-model set below, rerank off
# Connectivity-class probe failures (no HTTP answer for our calls, psql refuses) alert only on
# the second consecutive run: a single-run blip used to open an urgent issue that silenced the
# whole check until a human closed it (FOV-3002 pattern). Definitive failures (401/403/HTTP,
# no row) alert at once. State file like openrouter-alert.sh, PER ALERT KEY: both timers run
# this script about a minute apart, so a shared file would let the second timer's first-ever
# failure alert (FOV-3011 review). Cleared on every clean verdict, never touched by --dry-run.
mkdir -p "$PROBE_STATE_DIR"
PROBE_DOWN="$PROBE_STATE_DIR/probe-connectivity-failed-$ALERT_KEY"
probe_conn_fail() {  # 0: second consecutive failure, alert now; 1: recorded, stay quiet this run
  if [[ -e "$PROBE_DOWN" ]]; then (( DRY )) || rm -f "$PROBE_DOWN"; problems+=("$1"); return 0; fi
  (( DRY )) || printf '%s\n' "first failure at $(date -u '+%FT%TZ'): $1" >"$PROBE_DOWN" 2>/dev/null || true
  echo "probe connectivity failure, not alerting yet (one more run opens an alert): $1"; return 1
}
probe_ok() { (( DRY )) || rm -f "$PROBE_DOWN" 2>/dev/null || true; }
probe_ts() { docker exec hindsight sh -c 'PGCONNECT_TIMEOUT=10 PGPASSWORD=$(python3 -c "import json;print(json.load(open(\"/home/hindsight/.pg0/instances/hindsight/instance.json\"))[\"password\"])") \
  /home/hindsight/.pg0/installation/*/bin/psql -h 127.0.0.1 -U hindsight -d hindsight -Atc \
  "select clock_timestamp()"' 2>&1; }
probe_rows_since() { docker exec hindsight sh -c 'PGCONNECT_TIMEOUT=10 PGPASSWORD=$(python3 -c "import json;print(json.load(open(\"/home/hindsight/.pg0/instances/hindsight/instance.json\"))[\"password\"])") \
  /home/hindsight/.pg0/installation/*/bin/psql -h 127.0.0.1 -U hindsight -d hindsight -Atc \
  "select count(*) from llm_requests where bank_id='"'"'$0'"'"' and started_at >= '"'"'$1'"'"'::timestamptz"' "$PROBE_BANK" "$1" 2>&1; }
since=$(probe_ts)   # rows must land after this instant: a sibling timer run's earlier row can't
                    # count for this run, and no 5-min window row can age out behind the compare
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
    prow=$(probe_rows_since "$since")
    if [[ "$prow" =~ ^[0-9]+$ ]] && (( prow == 0 )); then sleep 3; prow=$(probe_rows_since "$since"); fi
    if [[ ! "$prow" =~ ^[0-9]+$ ]]; then
      probe_conn_fail "cannot read llm_requests for the tracing probe (got: ${prow:0:150})" || true
    elif (( prow == 0 )); then
      probe_ok
      problems+=("recall tracing probe succeeded but wrote no llm_requests row since $since: LLM tracing is off, so the hosted-call check is blind")
    else
      probe_ok
    fi
  fi
fi
fi

(( ${#problems[@]} == 0 )) && { echo "ok (bank=$bank)"; exit 0; }
problem=$(printf -- '- %s\n' "${problems[@]}")
echo "ALERT:"; echo "$problem"
(( DRY )) && exit 0

title="OPS: Hindsight bank $bank may be leaving the house"
tldr="TL;DR: Hindsight bank $bank may be using hosted models again (Ema: register row K2, FOV-2938; Intern: FOV-2962). Fix the routing (runbook: multica-local-workdir hindsight/README.md, \"Per-bank LLM routing\")."
if [[ "$down_hard" == grace-over ]]; then
  title="OPS: Hindsight down for $mins min (restart grace over)"
  tldr="TL;DR: Hindsight has been unreachable for $mins min (down since $down_since) -- the $((DOWN_GRACE / 60)) min restart grace in \`hindsight/ema-route-check.sh\` (FOV-3002a) expired. Restart it or treat as an outage; ${bank:+bank $bank }routing cannot be checked while it is down."
elif [[ "$down_hard" == no-state ]]; then
  title="OPS: Hindsight unreachable (down-time record unwritable)"
  tldr="TL;DR: Hindsight is unreachable (config HTTP $gate_code) and the route check cannot record down time under \`$state_dir\`, so it alerts immediately rather than risking permanent silence (FOV-3002a). Fix the filesystem; meanwhile the check keeps paging while Hindsight is down."
fi
# Outage alerts dedupe under their own key so an open routing issue cannot silence them.
alert_key="$ALERT_KEY"
[[ -n "$down_hard" ]] && alert_key="$ALERT_KEY-outage"

if ! list=$(multica issue list --metadata "alert_key=$alert_key" --limit 50 --output json --fields id,status); then
  echo "multica issue list failed; not creating an issue (would risk duplicates)" >&2; exit 1
fi
open=$(jq -r '(if type=="object" then .issues else . end)[] | select(.status|IN("cancelled","done","released")|not) | .id' <<<"$list" | head -1) \
  || { echo "cannot parse multica issue list output" >&2; exit 1; }
[[ -n "$open" ]] && { echo "already open: $open"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; cd "$tmp"
printf '%s\n\n%s\n\n%s\n' "$tldr" "$problem" \
  "Raised by \`hindsight/ema-route-check.sh\` on devbox3 (timer \`ema-route-check.timer\` or \`intern-route-check.timer\`, FOV-2945). It stays quiet while this issue is open." > description.md
out=$(multica issue create --title "$title" --description-file description.md \
  --assignee-id "$DSA_ID" --priority urgent --output json) || { echo "FAILED to create alert issue" >&2; exit 1; }
new=$(jq -er .id <<<"$out") || { echo "created an issue but cannot parse its id" >&2; exit 1; }
multica issue metadata set "$new" --key alert_key --value "$alert_key" >/dev/null \
  || { echo "created $new but metadata set failed: the next run may duplicate it" >&2; exit 1; }
echo "created alert issue $new"
