#!/usr/bin/env bash
# Show the resolved config and whether the decoy is answering.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/responder.pid"

echo "== Resolved config =="
python3 "$SCRIPT_DIR/responder.py" --print-config "$@"

PORT="$(python3 "$SCRIPT_DIR/responder.py" --print-config "$@" \
	| python3 -c 'import sys,json;print(json.load(sys.stdin)["health_port"])')"

echo
echo "== Process =="
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
	echo "start.sh process: running (pid $(cat "$PID_FILE"))"
else
	echo "start.sh process: not running"
fi
if launchctl list 2>/dev/null | grep -q com.multica.health-responder; then
	echo "launchd job:      loaded"
else
	echo "launchd job:      not loaded"
fi

echo
echo "== Live probe on port $PORT =="
if curl -s -m 2 "http://127.0.0.1:$PORT/health"; then
	echo
	echo "(^ this is what Multica Desktop sees)"
else
	echo "no response — Desktop would start its own daemon"
fi
