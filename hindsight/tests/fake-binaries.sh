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
