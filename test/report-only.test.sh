#!/bin/bash
# Tests for bin/multica's report-only mode (FOV-2848). Run: bash test/report-only.test.sh
# The real CLI is stubbed (prints REAL + args, exit 0); a refusal exits 3 without reaching it.
exec </dev/null
unset LWD_GATE_AGENTS LWD_GATE_ENFORCE_AGENTS LWD_GATE_ENFORCE_EXCEPT LWD_GATE_MODE MULTICA_BIN MULTICA_CLI_PATH
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo"
printf '#!/bin/bash\necho "REAL:[$*]"\n' > "$T/real"; chmod +x "$T/real"
cp -L "$REPO/bin/multica" "$T/repo/multica"; chmod +x "$T/repo/multica"
fails=0
I=01a1f055-b357-72a7-81d4-2c29f5788ad4

# want <allow|refuse> <report_only> args...
want() {
  local exp="$1" ro="$2"; shift 2
  local out rc
  out=$(cd "$T" && PATH=/usr/bin:/bin MULTICA_BIN="$T/real" LWD_AGENT_RUN=1 LWD_REPORT_ONLY="$ro" \
        "$T/repo/multica" "$@" 2>&1); rc=$?
  local got=refuse
  [ $rc = 0 ] && [[ "$out" == *REAL:* ]] && got=allow
  [ $rc != 0 ] && [ $rc != 3 ] && got="rc=$rc"
  if [ "$got" = "$exp" ]; then echo "ok   $exp: ${*:0:6}"; else echo "FAIL want $exp got $got: $* :: ${out:0:200}"; fails=$((fails+1)); fi
}

want allow  1 issue get $I --output json
want allow  1 issue comment list $I --roots-only --summary --compact --output json
want allow  1 issue comment add $I --parent x --content-file r.md --output table
want allow  1 issue status $I in_review
want allow  1 issue status $I blocked
want allow  1 issue status $I in_progress
want allow  1 chat history --output json
want allow  1 chat thread
want allow  1 --help
want allow  1 issue create --help
want allow  1 version
want refuse 1 issue status $I done
want refuse 1 issue status $I todo
want refuse 1 issue create --title x
want refuse 1 issue assign $I --to Reviewer
want refuse 1 issue update $I --title x
want refuse 1 issue comment add $I --content-file r.md --next Reviewer
want refuse 1 issue comment add $I --content-file r.md --next=Reviewer
want refuse 1 issue comment add $I --content-file r.md --next-human JC
want refuse 1 issue comment add $I --content-file r.md --no-next-actor
want refuse 1 issue comment add $I --content-file r.md --progress
want refuse 1 issue comment add $I --content-file r.md --attachment x.png
want refuse 1 issue list
want refuse 1 issue search x
want refuse 1 agent list
want refuse 1 autopilot create
want refuse 1 issue wakeup create $I --after 1m
want refuse 1 attachment download x
want refuse 1 --workspace-id w issue create --title x
# report-only off: the ordinary shim path (gate not installed in this copy -> passthrough)
want allow  0 issue create --title x
echo
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
