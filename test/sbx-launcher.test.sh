#!/bin/bash
# Tests for the pi wrapper's sandbox hand-off (FOV-2848). Run: bash test/sbx-launcher.test.sh
#  outer: LWD_SBX_SOCKET_DIR in .env + an agent id -> exec sbx-run <dir>/<id>.sock -- args
#  outer without agent id (daemon probes) -> local pi
#  inner (LWD_SBX_INNER=1): no hand-off; launcher's PI_BIN / LOG_DIR / MULTICA_SERVER_URL beat .env
exec </dev/null
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/w" "$T/logs" "$T/inner-logs"
tar -C "$REPO" --exclude=.git --exclude=logs -cf - . | tar -C "$T/w" -xf -
cat > "$T/w/.env" <<EOF
PI_BIN=$T/daemon-pi
LOG_DIR=$T/logs
MULTICA_SERVER_URL=ws://127.0.0.1:21408/ws
LWD_PI_VARIANT=pi
LWD_SBX_SOCKET_DIR=$T/sock
EOF
printf '#!/bin/bash\necho "SBXRUN:[$*]"\n' > "$T/sbx-run"
printf '#!/bin/bash\necho "DAEMONPI:[$*] url=$MULTICA_SERVER_URL"\n' > "$T/daemon-pi"
printf '#!/bin/bash\necho "AGENTPI:[$*] url=$MULTICA_SERVER_URL ro=$LWD_REPORT_ONLY"\n' > "$T/agent-pi"
chmod +x "$T/sbx-run" "$T/daemon-pi" "$T/agent-pi"
fails=0
check() { if [[ "$2" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: got: ${2:0:300}"; fails=$((fails+1)); fi; }
A=50c2d273-878d-4554-b9a8-ec816a7c428b
clean=(env -i PATH=/usr/bin:/bin HOME="$T" SBX_RUN_BIN="$T/sbx-run")

out=$(cd "$T" && "${clean[@]}" MULTICA_AGENT_ID=$A "$T/w/pi" -p --mode json --model litellm/smol 2>&1)
check "outer + agent id -> sbx-run with the agent's socket" "$out" "SBXRUN:[$T/sock/$A.sock -- -p --mode json --model litellm/smol]"
out=$(cd "$T" && "${clean[@]}" "$T/w/pi" --version 2>&1)
check "outer without agent id -> local pi" "$out" "DAEMONPI:[--version]"
out=$(cd "$T" && "${clean[@]}" MULTICA_AGENT_ID='x;rm -rf /' "$T/w/pi" -p 2>&1; echo "rc=$?")
check "malformed agent id refused" "$out" "rc=126"
out=$(cd "$T" && "${clean[@]}" LWD_SBX_INNER=1 MULTICA_AGENT_ID=$A PI_BIN="$T/agent-pi" LOG_DIR="$T/inner-logs" \
      MULTICA_SERVER_URL=http://127.0.0.1:4011 LWD_REPORT_ONLY=1 "$T/w/pi" -p --mode json 2>&1)
check "inner: no hand-off, the launcher's pi" "$out" "AGENTPI:[-p --mode json"
check "inner: gate URL, not the .env backend" "$out" "url=http://127.0.0.1:4011"
check "inner: report-only kept" "$out" "ro=1"
[ -s "$T/inner-logs/pi.log" ] && echo "ok   inner: logs to the launcher's LOG_DIR" || { echo "FAIL inner log dir unused"; fails=$((fails+1)); }
out=$(cd "$T" && "${clean[@]}" LWD_SBX_INNER=1 MULTICA_AGENT_ID=$A PI_BIN="$T/agent-pi" "$T/w/pi" -p 2>&1)
check "inner without a server URL: .env's backend URL dropped" "$out" "url= "
sed -i '/LWD_SBX_SOCKET_DIR/d' "$T/w/.env"
out=$(cd "$T" && "${clean[@]}" MULTICA_AGENT_ID=$A "$T/w/pi" -p 2>&1)
check "no LWD_SBX_SOCKET_DIR (main runtime) -> unchanged behaviour" "$out" "DAEMONPI:[-p"
echo
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
