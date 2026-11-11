#!/bin/bash
# Multica >=0.8 tells agents to run "$MULTICA_CLI_PATH" (the daemon's CLI, by
# absolute path), which skipped bin/multica (FOV-2098 review #2). Canary runs
# must get the shim there; other runs keep the daemon's CLI untouched.
# Run: bash test/cli-path.test.sh
exec </dev/null
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/r" "$T/ws"
cp -r "$REPO/bin" "$REPO/claude" "$REPO/pi" "$REPO/omp" "$REPO/opencode" "$T/r/"
rm -rf "$T/r/bin/__pycache__"
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "${2:-}"; fails=$((fails+1)); }

# the daemon's CLI (logs what reaches it) and an agent that does what the
# platform brief says: run "$MULTICA_CLI_PATH" ...
printf '#!/bin/bash\necho "REAL:$*" >> "%s/calls"\n' "$T" > "$T/daemon-cli"
cat > "$T/agent" <<'EOF'
#!/bin/bash
printf 'CLI=%s\nBIN=%s\n' "${MULTICA_CLI_PATH:-}" "${MULTICA_BIN:-}"
"$MULTICA_CLI_PATH" issue status FOV-0 done 2>&1
EOF
chmod +x "$T/daemon-cli" "$T/agent"

launch() { # wrapper agent-name canary-list [extra env...]
  local w="$1" name="$2" list="$3"; shift 3
  : > "$T/calls"
  out=$(cd "$T/ws" && env -i HOME="$HOME" PATH="/usr/bin:/bin" LOG_DIR="$T/logs" LWD_TASK_SETTINGS=0 \
        MULTICA_CLI_PATH="$T/daemon-cli" MULTICA_AGENT_NAME="$name" LWD_GATE_AGENTS="$list" \
        CLAUDE_BIN="$T/agent" PI_BIN="$T/agent" OMP_BIN="$T/agent" OPENCODE_BIN="$T/agent" \
        LWD_PI_VARIANT=pi "$@" "$T/r/$w" 2>&1)
}

for w in claude pi omp opencode; do
  launch "$w" Gaia "Gaia,Reviewer"
  echo "$out" | grep -qxF "CLI=$T/r/bin/multica" && ok "$w canary: MULTICA_CLI_PATH -> shim" || fail "$w canary cli" "$out"
  echo "$out" | grep -qxF "BIN=$T/daemon-cli" && ok "$w canary: shim's real CLI is the daemon's" || fail "$w canary bin" "$out"
  echo "$out" | grep -qF "gate (warn)" && ok "$w canary: \"\$MULTICA_CLI_PATH\" goes through the gate" || fail "$w canary gate" "$out"
  grep -qxF "REAL:issue status FOV-0 done" "$T/calls" && ok "$w canary: the daemon's CLI still runs it" || fail "$w canary real" "$(cat "$T/calls")"

  launch "$w" Flash "Gaia,Reviewer"
  echo "$out" | grep -qxF "CLI=$T/daemon-cli" && ok "$w non-canary: MULTICA_CLI_PATH untouched" || fail "$w non-canary cli" "$out"
  echo "$out" | grep -qF "gate (" && fail "$w non-canary: gated" "$out" || ok "$w non-canary: no gate"
done

# an operator-set MULTICA_BIN wins over the daemon's path
cp "$T/daemon-cli" "$T/other-cli"
launch claude Gaia Gaia MULTICA_BIN="$T/other-cli"
echo "$out" | grep -qxF "BIN=$T/other-cli" && ok "existing MULTICA_BIN kept" || fail "MULTICA_BIN kept" "$out"
# already pointing at the shim (nested wrapper): no self-loop
out2=$(cd "$T/ws" && env -i HOME="$HOME" PATH="/usr/bin:/bin" LOG_DIR="$T/logs" LWD_TASK_SETTINGS=0 \
       MULTICA_CLI_PATH="$T/r/bin/multica" MULTICA_AGENT_NAME=Gaia LWD_GATE_AGENTS=Gaia \
       CLAUDE_BIN="$T/agent" "$T/r/claude" 2>&1)
echo "$out2" | grep -qxF "BIN=" && ok "MULTICA_CLI_PATH already the shim: MULTICA_BIN not set to it" || fail "self-loop" "$out2"
# no MULTICA_CLI_PATH (older daemon): nothing set
out3=$(cd "$T/ws" && env -i HOME="$HOME" PATH="/usr/bin:/bin" LOG_DIR="$T/logs" LWD_TASK_SETTINGS=0 \
       MULTICA_AGENT_NAME=Gaia LWD_GATE_AGENTS=Gaia CLAUDE_BIN="$T/agent" "$T/r/claude" 2>&1)
echo "$out3" | grep -qxF "CLI=" && ok "no MULTICA_CLI_PATH: left unset" || fail "unset cli" "$out3"

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILURES"
exit "$fails"
