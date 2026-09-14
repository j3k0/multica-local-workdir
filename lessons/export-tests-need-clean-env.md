# Test "does this export?" with `env -i` — the Bash tool's zsh leaks exports (as of 2026-06-14)

The Claude Code Bash tool runs commands under the user's **zsh**, whose
exported environment leaks across tool calls. A naive test like
`source ./foo.sh; bash -c 'echo $VAR'` can show `VAR` present in the child even
when `foo.sh` never `export`s it — an earlier call (or the parent shell) already
exported it, and that bleeds into the spawn.

This hid a real bug in `claude-providers/z-ai.sh`: it had bare assignments (no
`export`), so it was broken — the `claude` wrapper sources providers with a bare
`.` and no `set -a` (line ~216), and its comment says they are "expected to
export". Bare assignments never reach the `claude` child, which silently falls
back to native Anthropic. The first test reported it worked; only `env -i`
revealed the truth.

Always isolate export-propagation tests with a clean environment:

```
env -i PATH=/usr/bin:/bin /bin/bash <<'EOF'
set +a
. ./claude-providers/foo.sh
/bin/bash -c 'test -n "$ANTHROPIC_BASE_URL" && echo YES || echo NO'
EOF
```

Rule: **provider files in this repo MUST `export` every var they set** — and
verify it under `env -i`, never the bare Bash tool shell.
