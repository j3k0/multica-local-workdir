#!/usr/bin/env bash
# Start the health responder in the background (foreground-detached, no launchd).
# Use install-launchd.sh instead if you want it to come back at login.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/responder.pid"
LOG_FILE="$SCRIPT_DIR/responder.log"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
	echo "Already running (pid $(cat "$PID_FILE")). Use stop.sh first." >&2
	exit 1
fi

# Pass any extra args straight through to responder.py (e.g. --no-server-url).
nohup /usr/bin/env python3 "$SCRIPT_DIR/responder.py" "$@" >>"$LOG_FILE" 2>&1 &
echo $! >"$PID_FILE"
sleep 0.5
if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
	echo "Started (pid $(cat "$PID_FILE")). Logging to $LOG_FILE"
	tail -n 2 "$LOG_FILE" 2>/dev/null || true
else
	echo "Failed to start — see $LOG_FILE" >&2
	rm -f "$PID_FILE"
	exit 1
fi
