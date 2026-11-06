#!/bin/bash
# Tests for bin/lwd-path-guard and its use by the claude/pi wrappers (FOV-2510).
# Run from anywhere: bash test/path-guard.test.sh
#
# Part A/C stand in `nobody` for the sandbox user (LWD_PATH_GUARD_USER) and
# grant it access with ACLs on temp dirs, so they run on any host with
# setfacl. Part B checks the real multica-sbx grants and is skipped where
# they don't exist.
exec </dev/null
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO/bin/lwd-path-guard"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "${2:-}"; fails=$((fails+1)); }
export LWD_PATH_GUARD_USER=nobody

allowed() { local out; if out="$("$GUARD" "$2" 2>&1)"; then ok "$1"; else fail "$1" "refused: $out"; fi; }
refused() { local out; if out="$("$GUARD" "$2" 2>&1)"; then fail "$1" "allowed: $out"; else ok "$1 ($out)"; fi; }

# --- A. guard, with `nobody` as the sandbox user ---------------------------
mkdir -p "$T/safe" "$T/w/sub" "$T/masked" "$T/ro" "$T/world" "$T/inst/.claude" "$T/lnk" "$T/agentsln"
chmod 755 "$T" "$T/safe" "$T/w" "$T/w/sub" "$T/masked" "$T/ro" "$T/inst" "$T/inst/.claude" "$T/lnk" "$T/agentsln"
setfacl -m u:nobody:rwx "$T/w"
setfacl -m u:nobody:rwx,m::rx "$T/masked"
setfacl -m u:nobody:rx "$T/ro"
chmod 777 "$T/world"
echo '{}' > "$T/inst/.claude/settings.json"; chmod 644 "$T/inst/.claude/settings.json"
setfacl -m u:nobody:rw "$T/inst/.claude/settings.json"
ln -s "$T/w" "$T/lnk/to-w"
echo x > "$T/w/planted.md"
ln -s "$T/w/planted.md" "$T/agentsln/AGENTS.md"
mkdir -p "$T/samedir"; chmod 755 "$T/samedir"; echo x > "$T/samedir/CLAUDE.md"; ln -s CLAUDE.md "$T/samedir/AGENTS.md"

allowed "plain 755 dir"                                "$T/safe"
refused "ACL u:sbx:rwx"                                "$T/w"
refused "subdir of a sbx-writable dir"                 "$T/w/sub"
allowed "ACL u:sbx:rwx masked to r-x"                  "$T/masked"
allowed "ACL u:sbx:r-x"                                "$T/ro"
refused "world-writable dir"                           "$T/world"
refused "symlink resolving into a sbx-writable dir"    "$T/lnk/to-w"
refused ".claude/settings.json writable by sbx"        "$T/inst"
refused "AGENTS.md symlinked into a sbx-writable dir"  "$T/agentsln"
allowed "AGENTS.md -> CLAUDE.md in the same safe dir"  "$T/samedir"
refused "nonexistent path"                             "$T/nope"
refused "a file, not a dir"                            "$T/w/planted.md"
# Review round 1: symlinked config dirs, ancestor entries, unreadable dirs.
mkdir -p "$T/cfgt" "$T/symcfg" "$T/symsub/.claude" "$T/cfgt2" "$T/anc/child" "$T/loop/.claude" "$T/unread/.claude/x"
chmod 755 "$T/cfgt" "$T/symcfg" "$T/symsub" "$T/symsub/.claude" "$T/cfgt2" "$T/anc" "$T/anc/child" "$T/loop" "$T/loop/.claude" "$T/unread" "$T/unread/.claude"
echo '{}' > "$T/cfgt/settings.json"; chmod 644 "$T/cfgt/settings.json"; setfacl -m u:nobody:rw "$T/cfgt/settings.json"
ln -s "$T/cfgt" "$T/symcfg/.claude"
echo x > "$T/cfgt2/SKILL.md"; chmod 644 "$T/cfgt2/SKILL.md"; setfacl -m u:nobody:rw "$T/cfgt2/SKILL.md"
ln -s "$T/cfgt2" "$T/symsub/.claude/skills"
echo x > "$T/anc/CLAUDE.md"; chmod 644 "$T/anc/CLAUDE.md"; setfacl -m u:nobody:rw "$T/anc/CLAUDE.md"
ln -s "$T/loop/.claude" "$T/loop/.claude/self"
chmod 000 "$T/unread/.claude/x"; trap 'chmod 755 "$T/unread/.claude/x"; rm -rf "$T"' EXIT
refused "symlinked .claude holding a sbx-writable file"     "$T/symcfg"
refused "symlinked subdir inside .claude, sbx-writable file" "$T/symsub"
refused "sbx-writable CLAUDE.md in an ancestor"              "$T/anc/child"
allowed "symlink loop inside .claude terminates"             "$T/loop"
refused "unreadable dir inside .claude (fail closed)"        "$T/unread"

out="$(LWD_PATH_GUARD_USER=no-such-user-fov2510 "$GUARD" "$T/w" 2>&1)" \
  && ok "no sandbox user on this host -> allowed" || fail "no sandbox user on this host" "$out"
out="$("$GUARD" "$T/lnk/../safe" 2>&1)"
[ "$out" = "$T/safe" ] && ok "prints the resolved path" || fail "prints the resolved path" "$out"

# --- B. the real sandbox grants (devbox3) ----------------------------------
if getent passwd multica-sbx >/dev/null && [ -d /opt/projects/email-assistant/scratch ]; then
  (unset LWD_PATH_GUARD_USER
   refused "real: email-assistant/scratch (multica-sbx)" /opt/projects/email-assistant/scratch
   refused "real: email-assistant/notes (multica-sbx)"   /opt/projects/email-assistant/notes
   allowed "real: this repo (multica-sbx)"               "$REPO"
   exit "$fails") || fails=$((fails+$?))
else
  echo "skip B: no multica-sbx / email-assistant on this host"
fi

# --- C. wrappers fall back to the default dir on a refused path: label -----
AGENT=11111111-1111-1111-1111-111111111111
ISSUE=22222222-2222-2222-2222-222222222222
W="$T/wrap"; mkdir -p "$W/bin" "$T/ws" "$T/default"; chmod 755 "$T/default"
cp "$REPO/claude" "$REPO/pi" "$W/"; cp "$GUARD" "$W/bin/"
printf '**You are: X** (ID: `%s`)\nmultica issue get %s --output json\n' "$AGENT" "$ISSUE" > "$T/ws/CLAUDE.md"
printf '#!/bin/bash\ncase "$1 $2" in "issue get") cat "%s/issue.json";; *) exit 1;; esac\n' "$T" > "$W/bin/multica"
printf '#!/bin/bash\npwd\n' > "$T/agent-bin"
chmod +x "$W/bin/multica" "$T/agent-bin"
wrapper_pwd() {  # <wrapper> <label path>
  printf '{"id":"%s","assignee_type":"agent","assignee_id":"%s","labels":[{"name":"path: %s"}]}' \
    "$ISSUE" "$AGENT" "$2" > "$T/issue.json"
  ( cd "$T/ws" && LOCAL_WORKING_PATH="$T/default" CLAUDE_BIN="$T/agent-bin" PI_BIN="$T/agent-bin" \
      LWD_PI_VARIANT=pi LOG_DIR="$T/logs" "$W/$1" -p hi 2>/dev/null | tail -1 )
}
if command -v jq >/dev/null; then
  for w in claude pi; do
    got="$(wrapper_pwd "$w" "$T/w")"
    [ "$got" = "$T/default" ] && ok "$w: path: -> sbx-writable dir is refused" || fail "$w: refused path" "pwd=$got"
    got="$(wrapper_pwd "$w" "$T/safe")"
    [ "$got" = "$T/safe" ] && ok "$w: path: -> normal dir still works" || fail "$w: normal path" "pwd=$got"
  done
  grep -q "REFUSED path '$T/w'" "$T/logs/claude.log" "$T/logs/pi.log" 2>/dev/null \
    && ok "refusal is logged" || fail "refusal is logged" "$(cat "$T"/logs/*.log 2>/dev/null | tail -3)"
else
  echo "skip C: jq not installed (the wrappers skip task settings without it)"
fi

[ "$fails" = 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
