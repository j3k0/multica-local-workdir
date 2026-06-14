#!/usr/bin/env bash
# Install + load the responder as a per-user launchd agent (starts at login,
# restarts on crash). Reversible with uninstall-launchd.sh.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.multica.health-responder"
TEMPLATE="$SCRIPT_DIR/com.multica.health-responder.plist.template"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PYTHON="$(command -v python3)"

if [ -z "$PYTHON" ]; then
	echo "python3 not found on PATH" >&2
	exit 1
fi

# Don't let a foreground start.sh instance hold the port.
if [ -f "$SCRIPT_DIR/responder.pid" ] && kill -0 "$(cat "$SCRIPT_DIR/responder.pid")" 2>/dev/null; then
	echo "A start.sh instance is running; stopping it first."
	"$SCRIPT_DIR/stop.sh" || true
fi

mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__PYTHON__|$PYTHON|g" \
    -e "s|__RESPONDER__|$SCRIPT_DIR/responder.py|g" \
    -e "s|__DIR__|$SCRIPT_DIR|g" \
    "$TEMPLATE" >"$PLIST"

# Reload cleanly if already present.
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed and loaded: $PLIST"
sleep 1
"$SCRIPT_DIR/status.sh" || true
