#!/usr/bin/env bash
# Re-run the FOV-2242 failure-path checks with fake docker/multica binaries. Touches nothing live
# except read-only Hindsight GETs. Usage: hindsight/tests/fake-binaries.sh
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export XDG_STATE_HOME=$T/state; mkdir -p "$T/bin" "$XDG_STATE_HOME"; P="$T/bin:$PATH"
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fi; }
printf '#!/bin/sh\necho "Error: No such container: hindsight" >&2; exit 1\n' > "$T/bin/docker"; chmod +x "$T/bin/docker"
check "alert fires when docker fails" 'PATH=$P "$H/openrouter-alert.sh" --dry-run | grep -q "^ALERT: Cannot read"'
check "refresh exits 1 when docker fails" '! PATH=$P "$H/daily-refresh.sh" >/dev/null'
printf '#!/bin/sh\necho "2026-10-24T17:14:56.9Z x 402 Payment Required'"'"' for url '"'"'https://openrouter.ai/api/v1/rerank"\n' > "$T/bin/docker"
printf '#!/bin/sh\necho "$@" >> %s/calls; [ "$2" = list ] && exit 1; echo "{}"\n' "$T" > "$T/bin/multica"; chmod +x "$T/bin/multica"
check "new 402 alerts" 'PATH=$P "$H/openrouter-alert.sh" --dry-run | grep -q "^ALERT: OpenRouter is refusing"'
check "failed list: no create, rc!=0" '! PATH=$P "$H/openrouter-alert.sh" >/dev/null 2>&1 && ! grep -q create "$T/calls"'
check "failed list: 402 not marked seen" '[ ! -f "$XDG_STATE_HOME/openrouter-alert/last-402" ]'
echo 2026-10-24T17:14:56.95Z > "$XDG_STATE_HOME/openrouter-alert/last-402"
check "already-alerted 402 (other fraction width) is ignored" 'PATH=$P "$H/openrouter-alert.sh" --dry-run | grep -q "^ok"'

# --- SACompliance conditions (FOV-2242) ---
reset() { rm -rf "$XDG_STATE_HOME" "$T/calls"; mkdir -p "$XDG_STATE_HOME"; }
printf '#!/bin/sh\necho "$@" >> %s/calls\ncase "$2" in list) echo "[]";; create) echo "{\\"id\\":\\"NEW1\\"}";; metadata) exit 1;; get) echo "{\\"status\\":\\"todo\\"}";; esac\n' "$T" > "$T/bin/multica"
printf '#!/bin/sh\necho "2026-10-24T17:14:56.9Z x 402 Payment Required'"'"' for url '"'"'https://openrouter.ai/api/v1/rerank"\n' > "$T/bin/docker"
reset
PATH=$P "$H/openrouter-alert.sh" >/dev/null 2>&1
check "metadata-set failure: exit path keeps open-credit id" '[ "$(cat "$XDG_STATE_HOME/openrouter-alert/open-credit")" = NEW1 ]'
rm -f "$XDG_STATE_HOME/openrouter-alert/last-402"   # simulate a fresh 402 on the next run
PATH=$P "$H/openrouter-alert.sh" >/dev/null 2>&1
check "metadata-set failure: next run creates no duplicate" '[ "$(grep -c "issue create" "$T/calls")" = 1 ]'
reset; printf '#!/bin/sh\necho "no daemon" >&2; exit 1\n' > "$T/bin/docker"
PATH=$P "$H/openrouter-alert.sh" >/dev/null 2>&1
check "unreadable logs: own title and key" 'grep -q "create --title OPS: Hindsight credit alert is blind" "$T/calls" && [ -f "$XDG_STATE_HOME/openrouter-alert/open-logs" ]'
reset; printf '#!/bin/sh\n: > /dev/null\n' > "$T/bin/docker"
printf '#!/bin/sh\necho "$@" > %s/curl-args; cat > %s/curl-stdin; printf 200\n' "$T" "$T" > "$T/bin/curl"; chmod +x "$T/bin/"*
OPENROUTER_MGMT_KEY=sk-or-FAKEKEYFORTEST PATH=$P "$H/openrouter-alert.sh" --dry-run >/dev/null 2>&1
check "management key not on curl command line" '! grep -q FAKEKEY "$T/curl-args" && grep -q FAKEKEY "$T/curl-stdin"'
rm -f "$T/bin/curl"
check "refresh exits 1 when the API is down" '! HINDSIGHT_API=http://127.0.0.1:9 PATH=$P "$H/daily-refresh.sh" >/dev/null 2>&1'
mkdir -p "$XDG_STATE_HOME/openrouter-alert"; echo 2026-10-24T17:14:56Z > "$XDG_STATE_HOME/openrouter-alert/last-402"
check "refresh skips within MIN_AGE of a 402" 'PATH=$P "$H/daily-refresh.sh" | grep -q "SKIP RUN: OpenRouter 402"'

# --- ema-route-check unreachability gate (FOV-3002a): restart grace, down-hard alert ---
RP="$T/rcbin:$P"
gracereset() { rm -rf "$XDG_STATE_HOME/hindsight-route-check" "$T/rcbin" "$T/rc-calls"; mkdir -p "$T/rcbin" "$XDG_STATE_HOME/hindsight-route-check"; }
gracereset
printf '#!/bin/sh\nexit 1\n' > "$T/rcbin/docker"; chmod +x "$T/rcbin/docker"
printf '#!/bin/sh\nprintf 000\n' > "$T/rcbin/curl"; chmod +x "$T/rcbin/curl"
out=$(ALERT_KEY=rt PATH=$RP "$H/ema-route-check.sh" --dry-run 2>/dev/null)
check "down: first cycle silent and records down-since" \
  '[[ "$out" == *"staying quiet"* ]] && [[ "$out" != *"ALERT"* ]] && [[ -s "$XDG_STATE_HOME/hindsight-route-check/down-rt" ]]'
out=$(ALERT_KEY=rt PATH=$RP "$H/ema-route-check.sh" --dry-run 2>/dev/null)
check "down: second cycle within grace still silent" \
  '[[ "$out" == *"still unreachable since"* ]] && [[ "$out" != *"ALERT"* ]]'
echo 2026-10-24T10:00:00Z > "$XDG_STATE_HOME/hindsight-route-check/down-rt"
out=$(ALERT_KEY=rt PATH=$RP "$H/ema-route-check.sh" --dry-run 2>/dev/null)
check "down: grace over alerts as an outage, no routing noise" \
  '[[ "$out" == *"ALERT:"* && "$out" == *"Hindsight unreachable for"*"an outage, not a restart"* && "$out" != *"connection refused"* ]]'
export RC_CALLS="$T/rc-calls"
cat > "$T/rcbin/multica" <<'STUB'
#!/bin/bash
echo "$@" >> "$RC_CALLS"
case "$2" in
  list) echo "[]";;
  create) echo '{"id":"NEW1"}';;
  metadata) exit 0;;
  get) echo "{}";;
esac
f=$(printf '%s\n' "$*" | sed -n 's/.*--description-file \([^ ]*\).*/\1/p')
[[ -n "$f" ]] && cat "$f" >> "$RC_CALLS"
exit 0
STUB
chmod +x "$T/rcbin/multica"
ALERT_KEY=rt PATH=$RP "$H/ema-route-check.sh" >/dev/null 2>&1
check "down: grace over creates the outage issue: own title, key and description" \
  '[[ "$(grep -c "issue create" "$T/rc-calls")" = 1 ]] && grep -q "OPS: Hindsight down for" "$T/rc-calls" \
     && grep -q "rt-outage" "$T/rc-calls" && grep -q "unreachable for" "$T/rc-calls" \
     && ! grep -q "may be using hosted models" "$T/rc-calls"'
gracereset
printf '#!/bin/sh\nexit 1\n' > "$T/rcbin/docker"; chmod +x "$T/rcbin/docker"
printf '#!/bin/sh\nprintf 000\n' > "$T/rcbin/curl"; chmod +x "$T/rcbin/curl"
echo not-a-date > "$XDG_STATE_HOME/hindsight-route-check/down-rt"
out=$(ALERT_KEY=rt PATH=$RP "$H/ema-route-check.sh" --dry-run 2>/dev/null)
check "down: unparsable down-since restarts the grace clock" \
  '[[ "$out" == *"corrupt down-since record restarted"* && "$out" != *"ALERT"* \
     && "$(cat "$XDG_STATE_HOME/hindsight-route-check/down-rt")" =~ ^2[0-9][0-9][0-9]- ]]'
echo 2076-10-24T10:00:00Z > "$XDG_STATE_HOME/hindsight-route-check/down-rt"
out=$(ALERT_KEY=rt PATH=$RP "$H/ema-route-check.sh" --dry-run 2>/dev/null)
check "down: future-timestamped record restarts the clock too" \
  '[[ "$out" == *"corrupt down-since record restarted"* && "$out" != *"ALERT"* ]]'
out=$(ALERT_KEY='../../evil' PATH=$RP "$H/ema-route-check.sh" --dry-run 2>/dev/null); rc=$?
check "unsafe ALERT_KEY refuses to run" '[[ "$rc" -eq 1 && -z "$out" ]]' 
gracereset
echo 2026-10-24T10:00:00Z > "$XDG_STATE_HOME/hindsight-route-check/down-rt"
printf '#!/bin/sh\ncase "$1.$2" in\n  exec.*) case "$*" in *litellm-postgres*) echo agent-ema;; *"select 1"*) echo 1;; *"route-check-probe"*) echo 1;; *) echo "0 0";; esac;;\n  inspect.*) case "$*" in *"Config.Env"*) echo "HINDSIGHT_API_LLM_REQUEST_BANK_MODELS=agent-ema=qwen3.8-flash-next";; *) date -u -d "-5 min" +%FT%%TZ;; esac;;\n  logs.*) case "$3" in 60m) echo "bank_llm_routes: bank=agent-ema routed";; *) echo "bank_llm_routes: routing '"'"'agent-ema'"'"'";; esac;;\nesac\n' > "$T/rcbin/docker"; chmod +x "$T/rcbin/docker"
printf '#!/bin/sh\ncase "$*" in\n  *"-o /dev/null"*) :;;\n  */memories/recall*) :;;\n  *route-check-probe/config*) printf '"'"'{"config":{"enable_reranking":false}}'"'"';;\n  */config*) printf '"'"'{"config":{"enable_reranking":false,"retain_extraction_mode":"chunks","enable_observations":false,"enable_auto_consolidation":false}}'"'"';;\nesac\ncase "$*" in *http_code*) printf '"'"'\\n200\\n'"'"';; esac\n' > "$T/rcbin/curl"; chmod +x "$T/rcbin/curl"
out=$(ALERT_KEY=rt PATH=$RP "$H/ema-route-check.sh" --dry-run 2>/dev/null)
check "recovered: healthy run clears the down-since record" \
  '[[ "$out" == "ok (bank=agent-ema)" ]] && [[ ! -e "$XDG_STATE_HOME/hindsight-route-check/down-rt" ]]'
