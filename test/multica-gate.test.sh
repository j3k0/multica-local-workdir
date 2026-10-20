#!/bin/bash
# Tests for bin/multica-gate.py (FOV-2097). Run: bash test/multica-gate.test.sh
#
# Copies bin/multica + bin/multica-gate.py into a temp dir; MULTICA_BIN is a
# stub that appends every call to $CALLS ("ARGS:[...]" for posts/status
# changes, plain args for reads/side steps, "BODY:..." for piped stdin) and
# answers the reads the gate needs (agent list, issue get, comment list).
# Primary calls exit 0, so post-success side steps run.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo"
CALLS="$T/calls"
LOG="$T/logs/multica-shim.log"   # shim + gate log of the temp copy
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "${2:-}"; fails=$((fails+1)); }

FA1=11111111-1111-1111-1111-111111111111
FA2=22222222-2222-2222-2222-222222222222
FI=33333333-3333-3333-3333-333333333333
FR=44444444-4444-4444-4444-444444444444
M1="[@FakeAgent](mention://agent/$FA1)"
M2="[@OtherAgent](mention://agent/$FA2)"
printf '[{"id":"%s","name":"FakeAgent"},{"id":"%s","name":"OtherAgent"},{"id":"%s","name":"Integrity"},{"id":"%s","name":"RunnerAgent"}]\n' \
  "$FA1" "$FA2" "$FI" "$FR" > "$T/agents.json"

cat > "$T/stub" <<'EOF'
#!/bin/bash
# STUB_FAIL: a fixed string; any call whose args contain it is logged and exits 1
if [ -n "$STUB_FAIL" ] && [[ "$*" == *"$STUB_FAIL"* ]]; then echo "FAILED:$*" >> "$STUB_CALLS"; echo "stub: forced failure" >&2; exit 1; fi
if [ "$1 $2" = "agent list" ]; then echo "agent list" >> "$STUB_CALLS"; cat "$STUB_AGENTS"; exit 0; fi
if [ "$1 $2" = "issue get" ]; then echo "$*" >> "$STUB_CALLS"; cat "$STUB_ISSUE"; exit 0; fi
if [ "$1 $2 $3" = "issue comment list" ]; then echo "$*" >> "$STUB_CALLS"; cat "$STUB_COMMENTS" 2>/dev/null || echo "[]"; exit 0; fi
case "$*" in *--no-start*|"issue metadata"*) echo "$*" >> "$STUB_CALLS"; exit 0;; esac
echo "ARGS:[$*]" >> "$STUB_CALLS"
case " $* " in *" --content-stdin "*) echo "BODY:$(cat)" >> "$STUB_CALLS";; esac
exit 0
EOF
chmod +x "$T/stub"
cp -L "$REPO/bin/multica" "$T/repo/multica"; chmod +x "$T/repo/multica"
cp "$REPO/bin/multica-gate.py" "$T/repo/multica-gate.py"
export STUB_AGENTS="$T/agents.json" STUB_CALLS="$CALLS" STUB_ISSUE="$T/issue.json"
export LWD_GATE_CACHE_DIR="$T/cache" MULTICA_WORKSPACE_ID=ws-test
export MULTICA_AGENT_ID="$FR" MULTICA_AGENT_NAME=RunnerAgent

mkissue() { # status assignee_id|null assignee_type|null [waiting_on]
  local id=null ty=null md='{}'
  [ "$2" != null ] && id="\"$2\""; [ "$3" != null ] && ty="\"$3\""
  [ -n "$4" ] && md="{\"waiting_on\":\"$4\"}"
  printf '{"id":"I","status":"%s","assignee_id":%s,"assignee_type":%s,"metadata":%s}\n' "$1" "$id" "$ty" "$md" > "$T/issue.json"
}
# g <mode> args... : run the shim as an agent; sets $out (stderr) and $rc
g() {
  local mode="$1"; shift
  rm -f "$CALLS"; touch "$CALLS"
  out=$(cd "$T" && PATH="/usr/bin:/bin" MULTICA_BIN="$T/stub" LWD_AGENT_RUN=1 LWD_GATE_MODE="$mode" \
        "$T/repo/multica" "$@" 2>&1 </dev/null); rc=$?
}
gin() { # like g but feeds $1 on stdin
  local input="$1" mode="$2"; shift 2
  rm -f "$CALLS"; touch "$CALLS"
  out=$(cd "$T" && printf '%s' "$input" | PATH="/usr/bin:/bin" MULTICA_BIN="$T/stub" LWD_AGENT_RUN=1 \
        LWD_GATE_MODE="$mode" "$T/repo/multica" "$@" 2>&1); rc=$?
}
rc_is()  { [ "$rc" = "$1" ] && ok "$2" || fail "$2" "rc=$rc out=$out"; }
has()    { grep -qxF -- "$1" "$CALLS" && ok "$2" || fail "$2" "missing [$1] in: $(tr '\n' '|' < "$CALLS")"; }
hasnt()  { grep -qF -- "$1" "$CALLS" && fail "$2" "unexpected [$1] in: $(tr '\n' '|' < "$CALLS")" || ok "$2"; }
says()   { echo "$out" | grep -qF -- "$1" && ok "$2" || fail "$2" "stderr: $out"; }
order()  { local a b; a=$(grep -nF -- "$1" "$CALLS" | head -1 | cut -d: -f1); b=$(grep -nF -- "$2" "$CALLS" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok "$3" || fail "$3" "$1@${a:-none} $2@${b:-none}"; }

# ------------------------------------------------------- plain comment add --
mkissue in_progress "$FA2" agent
g warn issue comment add I --content hi
rc_is 0 "warn: undeclared comment passes"; says "every comment must name its next actor" "warn: advice printed"
has "ARGS:[issue comment add I --content hi]" "warn: argv byte-identical"
g enforce issue comment add I --content hi
rc_is 3 "enforce: undeclared comment refused"; hasnt ARGS "enforce: nothing posted"
g enforce issue comment add I --content "over to $M1"
rc_is 0 "one agent mention passes"; has "ARGS:[issue comment add I --content over to $M1]" "one mention: untouched"
hasnt "issue assign" "plain comment: no side steps"
g enforce issue comment add I --content "done.
No next actor."
rc_is 0 "literal 'No next actor.' line counts as a declaration"
g warn issue comment add I --content "a $M1 b $M2"
rc_is 0 "warn: two mentions pass"; says "more than one next actor" "warn: two mentions advised"
g enforce issue comment add I --content "a $M1 b $M2"
rc_is 3 "enforce: two mentions refused"
g enforce issue comment add I --content "x [@Integrity](mention://agent/$FI)"
rc_is 3 "enforce: forbidden agent mentioned refused"
MULTICA_AGENT_NAME=Librarian g enforce issue comment add I --content "x $M1"
rc_is 3 "enforce: forbidden dispatcher mentioning an agent refused"

# ---------------------------------------------------------------- --next ---
mkissue in_review "$FA2" agent
g enforce issue comment add I --content "handing over" --next FakeAgent
rc_is 0 "--next: posted"
has "ARGS:[issue comment add I --content $M1 handing over]" "--next: mention injected, flag stripped"
has "issue assign I --to-id $FA1 --no-start" "--next: assign --no-start"
has "issue status I in_progress --no-start" "--next: status in_progress"
order "issue assign" "ARGS:[issue comment add" "--next: ownership before the dispatching post"
order "issue status" "ARGS:[issue comment add" "--next: status before the dispatching post"

mkissue in_progress "$FA1" agent
g enforce issue comment add I --content "$M1 already linked" --next fakeagent
rc_is 0 "--next (case-insensitive) with mention already present"
has "ARGS:[issue comment add I --content $M1 already linked]" "--next: existing mention not duplicated"
hasnt "issue assign" "--next: already the assignee -> no assign (no-op)"
hasnt "issue status" "--next: already in_progress -> no status call"

mkissue in_progress "$FA2" agent
for m in warn enforce; do
  g $m issue comment add I --content "see $M2" --next FakeAgent; rc_is 3 "$m: --next + other agent mentioned refused"
  g $m issue comment add I --content hi --next Integrity;       rc_is 3 "$m: --next to a forbidden agent refused"
  g $m issue comment add I --content hi --next NoSuchAgent;     rc_is 3 "$m: --next unknown agent refused"
  g $m issue comment add I --content hi --next RunnerAgent;     rc_is 3 "$m: --next yourself refused"
  g $m issue comment add I --content hi --next FakeAgent --next OtherAgent; rc_is 3 "$m: two --next refused"
  g $m issue comment add I --content hi --next FakeAgent --next-human JC;   rc_is 3 "$m: --next + --next-human refused"
  g $m issue comment add I --content hi --next;                 rc_is 3 "$m: --next without value refused"
done
hasnt ARGS "refusals post nothing"
MULTICA_AGENT_NAME=Integrity g warn issue comment add I --content hi --next FakeAgent
rc_is 3 "forbidden dispatcher may not use --next"

echo '[{"author_id":"'"$FA1"'","created_at":"2026-10-20T09:00:00Z"}]' > "$T/comments.json"
STUB_COMMENTS="$T/comments.json" g enforce issue comment add I --content back --next FakeAgent
rc_is 0 "paid-loop: advisory only, still posts"; says "paid loop" "paid-loop: note printed"

gin "piped body" enforce issue comment add I --content-stdin --next FakeAgent
rc_is 0 "--next with --content-stdin"
has "BODY:$M1" "--next stdin: mention on the first line"
grep -qxF "piped body" "$CALLS" && ok "--next stdin: body kept" || fail "stdin body kept" "$(cat "$CALLS")"
printf 'from a file' > "$T/reply.md"
g enforce issue comment add I --content-file reply.md --next FakeAgent
has "ARGS:[issue comment add I --content-stdin]" "--next file: re-delivered via stdin"
grep -qxF "from a file" "$CALLS" && ok "--next file: body kept" || fail "file body" "$(cat "$CALLS")"

g enforce --workspace-id w1 issue comment add I --next=FakeAgent --content go
rc_is 0 "--next=value form behind a global flag"
has "ARGS:[--workspace-id w1 issue comment add I --content $M1 go]" "global flag kept, mention injected"

# ---------------------------------------------------------- --next-human ---
mkissue in_progress "$FA2" agent
g enforce issue comment add I --content "need your call" --next-human JC
rc_is 0 "--next-human: posted"
has "ARGS:[issue comment add I --content need your call]" "--next-human: body untouched"
has "issue assign I --to JC --no-start" "--next-human: assigned to the human, no run"
has "issue status I in_review --no-start" "--next-human: in_review"
order "ARGS:[issue comment add" "issue assign" "--next-human: post first"
g enforce issue comment add I --content "waiting" --next-human JC --waiting-on "review, until friday"
has "issue metadata set I --key waiting_on --value review, until friday --type string" "--waiting-on: metadata"
has "issue status I blocked --no-start" "--waiting-on: blocked"
hasnt "in_review" "--waiting-on: not in_review"
g warn issue comment add I --content hi --next-human FakeAgent;      rc_is 3 "--next-human naming an agent refused"
g warn issue comment add I --content "see $M2" --next-human JC;     rc_is 3 "--next-human with agent mention refused"
g warn issue comment add I --content hi --waiting-on x;            rc_is 3 "--waiting-on without --next-human refused"

# ------------------------------------------------------- --no-next-actor ---
mkissue in_progress "$FA2" agent
g warn issue comment add I --content note --no-next-actor; rc_is 3 "--no-next-actor on unfinished issue refused"
mkissue in_review "$FA2" member
g enforce issue comment add I --content "wrapped up" --no-next-actor
rc_is 0 "--no-next-actor on in_review"
has 'ARGS:[issue comment add I --content wrapped up\nNo next actor.]' "--no-next-actor: line appended (CLI-decoded \\n)"
gin "all done" enforce issue comment add I --content-stdin --no-next-actor
grep -qxF "No next actor." "$CALLS" && ok "--no-next-actor stdin: own line" || fail "no-next stdin" "$(cat "$CALLS")"
g warn issue comment add I --content "x $M1" --no-next-actor; rc_is 3 "--no-next-actor with a mention refused"

# ------------------------------------------------------------ --progress ---
mkissue in_progress "$FA2" agent
g enforce issue comment add I --progress --content "halfway"
rc_is 0 "--progress posts"; has "ARGS:[issue comment add I --content halfway]" "--progress: stripped, verbatim"
hasnt "issue assign" "--progress: no side steps"
g warn issue comment add I --progress --content "hm $M2"; rc_is 3 "--progress with a mention refused"
g warn issue comment add I --progress --no-next-actor --content x; rc_is 3 "--progress + --no-next-actor refused"

# ---------------------------------------------------------- issue status ---
mkissue in_progress "$FA2" agent
g warn issue status I done
rc_is 0 "warn: done passes"; says "closing is a human's call" "warn: done advised"
has "ARGS:[issue status I done]" "warn: done argv intact"
g enforce issue status I done; rc_is 3 "enforce: done refused"; hasnt ARGS "enforce: done changed nothing"
g enforce issue status I todo; rc_is 3 "enforce: todo on assigned issue refused"
mkissue backlog null null
g enforce issue status I todo; rc_is 0 "todo on unassigned issue allowed"
g enforce issue status I blocked; rc_is 3 "enforce: blocked without --waiting-on refused"
g enforce issue status I blocked --waiting-on "JC, until friday"
rc_is 0 "blocked --waiting-on allowed"
has "issue metadata set I --key waiting_on --value JC, until friday --type string" "blocked: waiting_on set"
has "ARGS:[issue status I blocked]" "blocked: shim flag stripped"
order "issue metadata set" "ARGS:[issue status" "blocked: metadata first"
g warn issue status I in_progress --waiting-on x; rc_is 3 "--waiting-on with non-blocked refused"
mkissue in_progress "$FA2" agent
g enforce issue status I in_review; rc_is 3 "enforce: in_review with agent assignee refused"
mkissue in_progress m-1 member
g enforce issue status I in_review; rc_is 0 "in_review with human assignee allowed"
g enforce issue status I cancelled --duplicate-of FOV-1; rc_is 0 "cancelled passes"

# ------------------------------------------------- assign / update / create
mkissue in_progress "$FA2" agent
g warn issue assign I --to OtherAgent; rc_is 0 "warn: raw assign passes"; says "assigning alone" "warn: assign advised"
g enforce issue assign I --to OtherAgent; rc_is 3 "enforce: raw assign refused"
g enforce issue assign I --unassign; rc_is 0 "unassign allowed"
g enforce issue update I --assignee-id "$FA2"; rc_is 3 "enforce: update --assignee-id refused"
g enforce issue update I --status=done; rc_is 3 "enforce: update --status=done refused"
g enforce issue update I --title t --status in_progress; rc_is 0 "update --status in_progress allowed"
g warn issue update I --next FakeAgent; rc_is 3 "handoff flags on update refused"
for s in done in_review; do
  g enforce issue create --title t --status $s; rc_is 3 "enforce: create --status $s refused"
done
g enforce issue create --title t --status blocked --assignee-id "$FA2"; rc_is 3 "enforce: create --status blocked + assignee refused"
g enforce issue create --title t --status todo --assignee OtherAgent; rc_is 0 "create todo + assignee allowed (delegation)"

# ------------------------------------------------------------------ misc ---
g enforce issue comment add I --help; rc_is 0 "--help passes"; has "ARGS:[issue comment add I --help]" "--help intact"
g enforce issue reorder I up; rc_is 0 "ungated command passes"; has "ARGS:[issue reorder I up]" "ungated intact"
g enforce issue get I; has "issue get I" "reads pass"
mkissue in_progress "$FA2" agent
g warn issue status I done
grep -qE '\|agent\|issue status' "$LOG" && ok "shim log line" || fail "shim log" "$(cat "$LOG" 2>&1)"
grep -qE '\|gate\|warn\|warn\|issue status I done' "$LOG" && ok "gate decision logged" || fail "gate log" "$(cat "$LOG" 2>&1)"
out=$(cd "$T" && PATH="/usr/bin:/bin" MULTICA_BIN="$T/stub" LWD_AGENT_RUN=0 "$T/repo/multica" issue status I done 2>&1); rc=$?
rc_is 0 "non-agent runs: no gate"; [ -z "$out" ] && ok "non-agent: silent" || fail "non-agent silent" "$out"

# ------------------------------------------- review round 1 (FOV-2097) ---
# side-step failures
mkissue in_progress "$FA2" agent
STUB_FAIL="issue assign" g enforce issue comment add I --content hi --next-human Typo
rc_is 4 "--next-human: failed assign -> exit 4"; says "HANDOFF INCOMPLETE" "--next-human: failed assign reported"
hasnt "in_review" "--next-human: failed assign -> no status flip"
STUB_FAIL="issue assign" g enforce issue comment add I --content hi --next FakeAgent
rc_is 4 "--next: failed assign -> exit 4"; says "ownership stays" "--next: failed assign reported"
hasnt "issue status" "--next: failed assign -> no status flip"
has "ARGS:[issue comment add I --content $M1 hi]" "--next: failed assign still posts the mention"
mkissue in_review "$FA2" agent "JC, until friday"
STUB_FAIL="comment add" g enforce issue comment add I --content hi --next FakeAgent
rc_is 1 "--next: failed post returns the CLI's code"; says "HANDOFF DID NOT LAND" "--next: failed post reported"
has "issue assign I --no-start --to-id $FA2" "--next: failed post rolls the assignee back"
has "issue status I in_review --no-start" "--next: failed post rolls the status back"
has "issue metadata set I --key waiting_on --value JC, until friday --type string" "--next: failed post restores waiting_on"
STUB_FAIL="comment add" g enforce issue comment add I --content hi --next-human JC
rc_is 1 "--next-human: failed post"; hasnt "issue assign" "--next-human: failed post moves nothing"
# stale waiting_on
mkissue blocked "$FA2" agent "JC, until friday"
g enforce issue comment add I --content resume --next FakeAgent
has "issue metadata delete I --key waiting_on" "--next clears a stale waiting_on"
order "issue metadata delete" "ARGS:[issue comment add" "--next: waiting_on cleared before the dispatching post"
g enforce issue comment add I --content review --next-human JC
has "issue metadata delete I --key waiting_on" "--next-human (no --waiting-on) clears waiting_on"
mkissue in_progress "$FA2" agent
g enforce issue comment add I --content go --next FakeAgent
hasnt "metadata delete" "no waiting_on -> no delete call"
# closed issues
for s in done released cancelled; do
  mkissue $s "$FA2" agent
  g warn issue comment add I --content hi --next FakeAgent; rc_is 3 "--next on a $s issue refused"
  g warn issue comment add I --content hi --next-human JC;  rc_is 3 "--next-human on a $s issue refused"
done
hasnt ARGS "closed-issue refusals post nothing"
mkissue done m-1 member
g enforce issue comment add I --content "closed on your approval" --no-next-actor
rc_is 0 "--no-next-actor on a done issue still fine"
# --x=y inside a value
mkissue in_progress "$FA2" agent
g enforce issue comment add I --content "--output=json is what the shim needs" --next FakeAgent
rc_is 0 "value starting with --x=y: handoff ok"
has "ARGS:[issue comment add I --content $M1 --output=json is what the shim needs]" "value starting with --x=y kept intact"
g enforce issue comment add I --content "--next=FakeAgent in prose"
rc_is 3 "value that looks like --next=X is not a declaration"
# agent list failure
rm -rf "$T/cache"
STUB_FAIL="agent list" g enforce issue comment add I --content hi --next FakeAgent
rc_is 3 "agent list failure refuses --next"; says "could not list agents" "agent list failure named as such"
STUB_FAIL="agent list" g enforce issue comment add I --content hi --next-human JC
rc_is 0 "agent list failure: --next-human proceeds (fail-open check)"
# done allowlist
mkissue in_progress m-1 member
LWD_GATE_DONE_AGENTS=Secretary MULTICA_AGENT_NAME=Secretary g enforce issue status I done
rc_is 0 "LWD_GATE_DONE_AGENTS: Secretary may close"; grep -q 'done-allowlisted' "$LOG" && ok "allowlisted close logged" || fail "allowlist log" "$(cat "$LOG")"
LWD_GATE_DONE_AGENTS=Secretary g enforce issue status I done; rc_is 3 "allowlist is per agent (RunnerAgent still refused)"
# nits
g enforce issue assign I --to OtherAgent --no-start; rc_is 0 "assign --no-start passes (starts no run)"
g enforce issue create --title t --status blocked; rc_is 0 "create blocked without assignee passes"
mkissue in_progress "$FA2" agent
g enforce issue status I todo; says "issue status I blocked" "todo advice names the real issue id"

# fail-open: a crashing gate still runs the raw command (stdin body kept)
sed 's/^def comment_add(argv, toks):$/&\n    raise RuntimeError("boom")/' "$REPO/bin/multica-gate.py" > "$T/repo/multica-gate.py"
g enforce issue comment add I --content hi
rc_is 0 "gate crash: raw command still runs"; says "internal error" "gate crash: reported"
has "ARGS:[issue comment add I --content hi]" "gate crash: argv intact"
cp "$REPO/bin/multica-gate.py" "$T/repo/multica-gate.py"

[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILURES"
exit "$fails"
