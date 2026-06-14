#!/usr/bin/env bash
# Unload + remove the launchd agent. Fully reverses install-launchd.sh.
set -e

LABEL="com.multica.health-responder"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -f "$PLIST" ]; then
	launchctl unload "$PLIST" 2>/dev/null || true
	rm -f "$PLIST"
	echo "Unloaded and removed: $PLIST"
else
	echo "Not installed ($PLIST absent)."
	# Best-effort unload in case it was loaded from elsewhere.
	launchctl remove "$LABEL" 2>/dev/null || true
fi
