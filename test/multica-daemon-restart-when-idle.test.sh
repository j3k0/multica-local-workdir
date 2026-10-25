#!/bin/bash
# Tests for multica-daemon-restart-when-idle's restart path (FOV-2246).
# Run: bash test/multica-daemon-restart-when-idle.test.sh
# Copies the script into a temp dir next to a stub ./multica-daemon; stub
# `systemctl` (on PATH) and MULTICA_BIN log every call to $CALLS. Hermetic:
# nothing touches the real daemon or systemd.
exec </dev/null
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
CALLS="$T/calls"
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "${2:-}"; fails=$((fails+1)); }

mkdir -p "$T/repo" "$T/bin"
cp "$REPO/multica-daemon-restart-when-idle" "$T/repo/"
cat > "$T/repo/multica-daemon" <<'EOF'
#!/bin/bash
echo "wrapper $*" >> "$STUB_CALLS"
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$STUB_CALLS"
[ "$2" = "show" ] && { echo "${STUB_STATE:-active}"; exit 0; }
exit 0
EOF
cat > "$T/bin/multica" <<'EOF'
#!/bin/bash
echo '[{"name":"A","runtime_id":"rt1","status":"idle"}]'
EOF
chmod +x "$T/repo/"* "$T/bin/"*

run() { : > "$CALLS"; STUB_CALLS="$CALLS" MULTICA_BIN="$T/bin/multica" PATH="$T/bin:$PATH" \
  "$T/repo/multica-daemon-restart-when-idle" --runtime-id rt1 --interval 0 --idle-checks 1 "$@" > "$T/out" 2>&1; }

# 1. unit active -> systemctl restart, wrapper untouched
STUB_STATE=active run; rc=$?
if [ $rc -eq 0 ] && grep -qx 'systemctl --user restart multica-daemon' "$CALLS" && ! grep -q '^wrapper' "$CALLS"; then
  ok "unit active: restarts via systemctl"
else fail "unit active" "rc=$rc calls=$(tr '\n' ';' < "$CALLS")"; fi

# 1b. unit in RestartSec (activating/auto-restart) -> still systemctl
STUB_STATE=activating run; rc=$?
if [ $rc -eq 0 ] && grep -qx 'systemctl --user restart multica-daemon' "$CALLS" && ! grep -q '^wrapper' "$CALLS"; then
  ok "unit activating: restarts via systemctl"
else fail "unit activating" "rc=$rc calls=$(tr '\n' ';' < "$CALLS")"; fi

# 2. unit inactive/failed -> ./multica-daemon restart
STUB_STATE=failed run; rc=$?
if [ $rc -eq 0 ] && grep -qx 'wrapper restart' "$CALLS" && ! grep -q 'systemctl --user restart' "$CALLS"; then
  ok "unit inactive: restarts via ./multica-daemon"
else fail "unit inactive" "rc=$rc calls=$(tr '\n' ';' < "$CALLS")"; fi

# 3. --dry-run names the systemctl command and restarts nothing
STUB_STATE=active run --dry-run; rc=$?
if [ $rc -eq 0 ] && grep -q 'would run systemctl --user restart multica-daemon' "$T/out" \
   && ! grep -q 'restart multica-daemon$' "$CALLS" && ! grep -q '^wrapper' "$CALLS"; then
  ok "dry-run: logs systemctl, restarts nothing"
else fail "dry-run" "rc=$rc out=$(tr '\n' ';' < "$T/out")"; fi

# 4. static unit check: the exit-42 handoff only works under this exact name
U="$REPO/systemd/multica-daemon.service"
if grep -qx 'RestartForceExitStatus=42' "$U" && grep -qx 'Restart=on-failure' "$U" \
   && grep -q '^EnvironmentFile=/' "$U" && grep -q 'exec ./multica-daemon start --foreground' "$U"; then
  ok "unit: on-failure + exit-42 handoff + EnvironmentFile + wrapper"
else fail "unit static check"; fi
if command -v systemd-analyze >/dev/null; then
  mkdir -p "$T/u" && cp "$U" "$T/u/multica-daemon.service"
  v="$(systemd-analyze --user verify "$T/u/multica-daemon.service" 2>&1)"
  [ -z "$v" ] && ok "unit: systemd-analyze verify clean" || fail "systemd-analyze verify" "$v"
fi

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
