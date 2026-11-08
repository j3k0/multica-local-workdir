#!/bin/bash
# Static checks for the devbox3 OOM safety net (FOV-2442).
# Run: bash test/host-oom.test.sh   (touches nothing on the host)
exec </dev/null
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$REPO/systemd/host"
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "${2:-}"; fails=$((fails+1)); }

# 1. user manager drop-in
grep -qx 'OOMScoreAdjust=-100' "$H/user@1000.service.d/oom.conf" \
  && grep -qx '\[Service\]' "$H/user@1000.service.d/oom.conf" \
  && ok "user@1000 drop-in: [Service] OOMScoreAdjust=-100" || fail "user@1000 drop-in"

# 2. earlyoom args: --prefer must not match the agent stack's process names
args="$(. "$H/earlyoom.default"; printf '%s' "$EARLYOOM_ARGS")"
prefer="$(printf '%s' "$args" | sed -nE 's/.*--prefer ([^ ]+).*/\1/p')"
avoid="$(printf '%s' "$args" | sed -nE 's/.*--avoid ([^ ]+).*/\1/p')"
[ -n "$prefer" ] && [ -n "$avoid" ] || fail "earlyoom args parse" "$args"
bad=""
for n in node python python3 litellm multica meridian pi bun; do
  printf '%s' "$n" | grep -qE "$prefer" && bad="$bad $n"
done
[ -z "$bad" ] && ok "earlyoom --prefer spares the agent stack" || fail "earlyoom --prefer matches:$bad"
lost=""
for n in sshd systemd; do
  printf '%s' "$n" | grep -qE "$avoid" || lost="$lost $n"
done
[ -z "$lost" ] && ok "earlyoom --avoid keeps sshd/systemd" || fail "earlyoom --avoid lost:$lost"

# 3. earlyoom accepts the args (dry run; `timeout` kills it after 2 s, so rc 124 = it kept running = pass)
if command -v earlyoom >/dev/null; then
  # shellcheck disable=SC2086
  out="$(timeout 2 earlyoom $args --dryrun 2>&1)"; rc=$?
  [ $rc -eq 124 ] && ok "earlyoom starts with these args (--dryrun)" || fail "earlyoom --dryrun rc=$rc" "$(printf '%s' "$out" | tail -2)"
fi

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
