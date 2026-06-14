#!/usr/bin/env bash
# Stop a responder started with start.sh.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/responder.pid"

if [ ! -f "$PID_FILE" ]; then
	echo "No pid file — not running (or started via launchd; use uninstall-launchd.sh)." >&2
	exit 0
fi

PID="$(cat "$PID_FILE")"
if kill -0 "$PID" 2>/dev/null; then
	kill "$PID"
	echo "Stopped (pid $PID)."
else
	echo "Process $PID not alive; cleaning up."
fi
rm -f "$PID_FILE"
