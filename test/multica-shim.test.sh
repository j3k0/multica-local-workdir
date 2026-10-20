#!/bin/bash
# Tests for bin/multica (FOV-2096). Run from anywhere: bash test/multica-shim.test.sh
#
# Runs a copy of the shim out of a temp dir, so the shim's own REPO_DIR (= the
# temp copy's parent) is where it writes logs/multica-shim.log — the tests read
# that, not the repo's logs/. The real CLI is stubbed to exit 9; a fake PATH
# multica echoes FOUND-REAL.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo" "$T/empty" "$T/pathdir"
LOG="$T/logs/multica-shim.log"   # where the shim copy will write it
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "${2:-}"; fails=$((fails+1)); }

printf '#!/bin/bash\necho "ARGS:[$*]"; cat; exit 9\n' > "$T/real"; chmod +x "$T/real"
printf '#!/bin/bash\necho FOUND-REAL\n' > "$T/pathdir/multica"; chmod +x "$T/pathdir/multica"
cp -L "$REPO/bin/multica" "$T/repo/multica"; chmod +x "$T/repo/multica"
clear_log() { rm -f "$LOG"; }
logged() { [ -s "$LOG" ]; }

# run <LWD_AGENT_RUN> <paths-extra-flag> args... -> last line "rc=<code>"; PATH
# has /usr/bin and /bin so the shim's dirname/cut binaries resolve.
run() {
  local marker="$1"; shift
  local shimpath="$T/repo/multica" keep="$1"; shift
  ( cd "$T" && PATH="$keep:$T/pathdir:/usr/bin:/bin" MULTICA_BIN="$T/real" \
      LWD_AGENT_RUN="$marker" "$shimpath" "$@" 2>/dev/null; echo "rc=$?" )
}
run_out() { run "$@"; }
run_silent() { run "$@" >/dev/null 2>&1; }
run_err() { ( cd "$T" && PATH="$2:$T/pathdir:/usr/bin:/bin" MULTICA_BIN="$3" LWD_AGENT_RUN="$1" \
      shift 3; set -- "$@"; "$T/repo/multica" "$@" 2>&1 >/dev/null; echo "rc=$?" ); }

# --- passthrough fidelity ---------------------------------------------------
out=$(echo "payload" | run 1 "$T/empty" issue comment read --output json)
echo "$out" | head -1 | grep -qF 'ARGS:[issue comment read --output json]' && ok "passthrough: argv intact" || fail "argv" "$out"
echo "$out" | grep -qxF 'payload' && ok "passthrough: stdin consumed" || fail "stdin" "$out"
echo "$out" | tail -1 | grep -q 'rc=9' && ok "passthrough: exit code kept" || fail "exit code" "$out"
out=$(run 0 "$T/empty" issue status X done)
echo "$out" | head -1 | grep -qF 'ARGS:[issue status X done]' && ok "gated command still passes through (step 2)" || fail "gated passthrough" "$out"

# --- resolution -------------------------------------------------------------
out=$(cd "$T" && PATH="$T/repo:$T/pathdir:/usr/bin:/bin" "$T/repo/multica" x 2>/dev/null; echo "rc=$?")
echo "$out" | grep -q FOUND-REAL && ok "PATH scan skips own directory (no recursion)" || fail "recursion" "$out"
out=$(cd "$T" && PATH="$T/repo:$T/empty:/usr/bin:/bin" MULTICA_BIN= "$T/repo/multica" x 2>&1; echo "rc=$?")
echo "$out" | tail -1 | grep -q 'rc=127' && ok "missing binary fails loud (127)" || fail "missing binary" "$out"

# --- MULTICA_BIN edge cases -------------------------------------------------
out=$(cd "$T" && PATH="$T/repo:$T/pathdir:/usr/bin:/bin" MULTICA_BIN="$T/repo/multica" "$T/repo/multica" x 2>&1; echo "rc=$?")
echo "$out" | grep -q 'points at this shim' && echo "$out" | tail -1 | grep -q 'rc=127' && ok "MULTICA_BIN=self refused" || fail "self-exec" "$out"
ln -s "$T/repo/multica" "$T/self-link"
out=$(cd "$T" && PATH="$T/repo:$T/pathdir:/usr/bin:/bin" MULTICA_BIN="$T/self-link" "$T/repo/multica" x 2>&1; echo "rc=$?")
echo "$out" | grep -q 'points at this shim' && ok "symlinked self refused" || fail "symlink self" "$out"
# a legitimate symlinked real binary is accepted (no readlink -f dependency)
printf '#!/bin/bash\necho LEGIT-SYMLINK; exit 9\n' > "$T/real-target"; chmod +x "$T/real-target"; ln -s "$T/real-target" "$T/multica-sym"
out=$(cd "$T" && PATH="$T/repo:$T/pathdir:/usr/bin:/bin" MULTICA_BIN="$T/multica-sym" "$T/repo/multica" x 2>&1; echo "rc=$?")
echo "$out" | grep -q LEGIT-SYMLINK && ok "legit symlinked real binary accepted" || fail "legit symlink" "$out"
# stale / non-executable MULTICA_BIN -> warn + PATH fallback
out=$(cd "$T" && PATH="$T/repo:$T/pathdir:/usr/bin:/bin" MULTICA_BIN="$T/nope" "$T/repo/multica" x 2>&1; echo "rc=$?")
echo "$out" | grep -qF 'falling back to PATH' && echo "$out" | grep -q FOUND-REAL \
  && ok "stale MULTICA_BIN warns + falls back" || fail "stale MULTICA_BIN" "$out"
out=$(cd "$T" && PATH="$T/repo:$T/pathdir:/usr/bin:/bin" MULTICA_BIN="$T" "$T/repo/multica" x 2>&1; echo "rc=$?")
echo "$out" | grep -qF 'falling back to PATH' && ok "directory MULTICA_BIN warns + falls back" || fail "dir MULTICA_BIN" "$out"

# --- marker / gated log -----------------------------------------------------
for m in 0 1; do
  for c in "issue status X done" "issue comment add X -m hi" "issue comment read X" "issue get X" "version"; do
    # shellcheck disable=SC2086
    clear_log; run_silent "$m" "$T/empty" $c
    case "$c" in issue\ status*|issue\ comment\ add*) exp=$([ "$m" = 1 ] && echo YES || echo no) ;; *) exp=no ;; esac
    out=$([ -s "$LOG" ] && echo YES || echo no)
    [ "$out" = "$exp" ] && ok "marker=$m gating [$c]" || fail "marker=$m [$c]" "logged=$out want=$exp"
  done
done

# --- global flags before the command ---------------------------------------
clear_log; run_silent 1 "$T/empty" --workspace-id w1 issue status X done
logged && ok "gated command behind --workspace-id" || fail "--workspace-id eats gate"
clear_log; run_silent 1 "$T/empty" --profile foo issue comment add X -m hi
logged && ok "gated command behind --profile" || fail "--profile eats gate"
clear_log; run_silent 1 "$T/empty" --workspace-id w1 issue get X
logged && fail "read under global flag logged" || ok "read stays free behind global flag"

# --- log format -------------------------------------------------------------
clear_log
run_silent 1 "$T/empty" issue status "x
FAKE|agent|issue status <uuid> done" done
[ "$(wc -l < "$LOG")" -eq 1 ] && ok "newline in args can't mint a fake log line" || fail "log injection" "$(wc -l < "$LOG") lines"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*\|agent\|issue status' "$LOG" && ok "log line format" || fail "log head" "$(head -1 "$LOG")"

# --- probe: value-taking flags accepted BEFORE a subcommand -----------------
# Root --help under-enumerates these; brute-force each candidate against the
# real CLI (needs network + auth) and require every accepted one to be in the
# shim's skip list — and gated commands to still be caught behind each.
_flags='--workspace-id --profile --server-url --output --server --output=json --debug --version'
for f in --profile --output --server-url --workspace-id --server; do
  err=$(multica "$f" dummy issue get FOV-2096 2>&1); rc=$?
  # "accepted" = the CLI parsed the flag (the id/workspace may still fail)
  if ! echo "$err" | grep -qi 'unknown flag\|flag provided but not defined\|unknown shorthand'; then
    if grep -qF -- "${f}|" bin/multica || grep -qF -- "|${f})" bin/multica; then
      ok "real CLI accepts $f before subcommand; in skip list"
    else
      fail "$f accepted pre-subcommand but missing from skip list"
    fi
  fi
done
for f in --workspace-id --profile --server-url --output; do
  clear_log
  # shellcheck disable=SC2086
  run_silent 1 "$T/empty" $f dummy issue status X done
  logged && ok "gated command behind $f dummy" || fail "$f eats gate"
done

clear_log
[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILURES"
exit "$fails"