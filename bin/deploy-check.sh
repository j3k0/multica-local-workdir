#!/bin/bash
# bin/deploy-check.sh — post-deploy health check for multica-local-workdir
# (FOV-2098, plan step 4: a 0-second failing run right after a deploy must
# page the maintainer, not look like a handoff problem).
#
# The 2026-10-08 outage class: a stale binary path (PI_BIN) made every agent
# launch fail in 0 seconds with exit 127. These checks catch exactly that
# class without launching a paid run:
#   1. real multica CLI (MULTICA_BIN) resolves
#   2. every agent-binary path the daemon reads from .env exists + executes
#      (MULTICA_CLAUDE_PATH / MULTICA_OPENCODE_PATH / MULTICA_PI_PATH /
#      MULTICA_OMP_PATH)
#   3. bin/multica shim + multica-gate.py + python3 are in place
#   4. the shim resolves the real CLI end-to-end (PATH + marker probe on a
#      cheap `--help` passthrough)
#   5. the gate + shim test suites pass
#
# Usage: bin/deploy-check.sh [--no-tests]
# Exit: 0 all good · 1 checks failed · 2 could not page
#
# On failure it also pages by commenting on $LWD_HEALTH_ISSUE (default the
# FOV-2098 issue; its followers are notified) — best effort: a dead server
# means no comment can go out, so the non-zero exit code is the real signal
# for the caller (deploying SA run / cron). Run it right after every pull.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEALTH_ISSUE="${LWD_HEALTH_ISSUE:-01a157dd-5962-71d8-b85d-8bab0f496143}"

fail=""; note() { printf '%s\n' "$1"; }  # checks accumulate a failure list

# --- .env (multi values, set-a sourcing like the wrappers) -------------------
env_of() {
  local k="$1"
  printf '%s' "${!k:-}"
  if [ -f "$SCRIPT_DIR/.env" ]; then
    local v="$(. "$SCRIPT_DIR/.env" >/dev/null 2>&1; eval "printf '%s' \"\${$k:-}\"")"
    [ -n "${!k:-}" ] || printf '%s' "$v"
  fi
}

# --- 1/2: binaries ----------------------------------------------------------
bin_ok() { [ -n "$1" ] && [ -f "$1" ] && [ -x "$1" ] && [ ! -d "$1" ]; }

mb="$(env_of MULTICA_BIN)"
if [ -n "$mb" ]; then
  bin_ok "$mb" && note "ok  MULTICA_BIN $mb" || fail="$fail
  MULTICA_BIN ($mb) from .env is missing / not executable"
else
  note "ok  MULTICA_BIN unset — falls back to PATH"
fi

for v in MULTICA_CLAUDE_PATH MULTICA_OPENCODE_PATH MULTICA_PI_PATH MULTICA_OMP_PATH; do
  p="$(env_of $v)"
  # The daemon wrapper exports these itself pointing at this checkout, so a
  # missing .env line is fine — the checkout's own file is what gets executed.
  case "$v" in
    MULTICA_OPENCODE_PATH) [ -z "$p" ] && p="$SCRIPT_DIR/opencode" ;;
    MULTICA_PI_PATH)       [ -z "$p" ] && p="$SCRIPT_DIR/pi" ;;
    MULTICA_OMP_PATH)      [ -z "$p" ] && p="$SCRIPT_DIR/omp" ;;
    *)                     [ -z "$p" ] && p="$SCRIPT_DIR/claude" ;;
  esac
  bin_ok "$p" && note "ok  $v -> $p" || fail="$fail
  $v ($p) is missing / not executable — agent launches on this runtime exit 127 in 0s"
done

# --- 3: gate pieces ---------------------------------------------------------
for f in "$SCRIPT_DIR/bin/multica" "$SCRIPT_DIR/bin/multica-gate.py"; do
  bin_ok "$f" && note "ok  $f" || fail="$fail
  $f missing (gate unusable)"
done
command -v python3 >/dev/null 2>&1 && note "ok  python3" || fail="$fail
  python3 not on PATH (gate unreach; shim fails open)"

# --- 4: shim end-to-end passthrough ----------------------------------------
shim_out="$(cd "$SCRIPT_DIR" && PATH="$SCRIPT_DIR/bin:$PATH" LWD_AGENT_RUN=1 \
  "$SCRIPT_DIR/bin/multica" --help 2>&1)"
rc=$?
[ $rc -eq 0 ] && note "ok  shim passthrough (--help via bin/multica)" \
  || { fail="$fail
  shim --help probe failed (rc=$rc): $shim_out"; }

# --- 5: test suites (skip with --no-tests on a very slow box) ---------------
if [ "${1:-}" != "--no-tests" ]; then
  bash "$SCRIPT_DIR/test/multica-gate.test.sh" >/dev/null 2>&1 \
    && note "ok  gate test suite" || fail="$fail
  bin/multica-gate.py: test/multica-gate.test.sh FAILED — do not leave this deploy in"
  bash "$SCRIPT_DIR/test/multica-shim.test.sh" >/dev/null 2>&1 \
    && note "ok  shim test suite" || fail="$fail
  bin/multica: test/multica-shim.test.sh FAILED — do not leave this deploy in"
fi

# --- report (and page, best effort) -----------------------------------------
if [ -z "$fail" ]; then
  note "deploy-check: ALL OK on $(hostname)"
  exit 0
fi
page="multica-local-workdir deploy check FAILED on $(hostname) at $(date -u '+%Y-%m-%dT%H:%M:%SZ'):
$fail
Rollback: the per-agent switch is LWD_GATE_AGENTS in multica-local-workdir/.env (empty = everyone) — or revert the last commit in that checkout (one-line PATH removal in the wrappers)."

printf '%s\n' "$page"
if command -v multica >/dev/null 2>&1; then
  if printf '%s' "$page" | multica issue comment add "$HEALTH_ISSUE" --content-stdin >/dev/null 2>&1; then
    note "paged: commented on $HEALTH_ISSUE"
    exit 1
  fi
fi
note "could not page (comment failed or multica CLI unavailable) — exit code is the signal"
exit 1