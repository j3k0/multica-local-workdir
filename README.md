# multica-local-workdir

Thin shell wrappers that let [multica](https://github.com/) agents work directly inside your local project directory — so project-scoped skills, slash commands, MCP servers, and settings actually load — without patching multica itself.

## The problem

multica creates a per-session **workspace directory** (e.g. `~/multica_workspaces/<uuid>/.../workdir`) and runs the agent CLI from there. Two things break as a result:

1. **Project-scoped configuration isn't loaded.** Skills, slash commands, subagents, MCP servers, settings, hooks — everything that lives under `<project>/.claude/` or `<project>/.opencode/` — is keyed strictly off the agent's CWD. Running from the workspace means none of it loads.
2. **The workspace's instructions file is the only one that loads.** multica writes a `CLAUDE.md` (or `AGENTS.md`) into the workspace with agent-specific behaviour instructions. If you `cd` into the project to fix #1, you lose those.

These wrappers fix both: they `cd` into the project so project-scoped config loads, then re-inject the workspace's instructions file into the agent's system prompt.

## Install

```bash
mkdir -p "$HOME/bin/multica-local-workdir"
# Copy the `claude`, `opencode`, and `opencode-config.json` files into that directory
chmod +x "$HOME/bin/multica-local-workdir/claude" "$HOME/bin/multica-local-workdir/opencode"
```

### Point the multica daemon at the wrappers

multica reads `MULTICA_CLAUDE_PATH` and `MULTICA_OPENCODE_PATH` to locate the agent binaries. The included `multica-daemon` script sets both (derived from its own location) and `exec`s `multica daemon "$@"`. Use it instead of `multica daemon`:

```bash
# Symlink onto your PATH (or call it by absolute path):
ln -s "$HOME/bin/multica-local-workdir/multica-daemon" "$HOME/bin/multica-daemon"
multica-daemon
```

Set `MULTICA_SERVER_URL` (and optionally `MULTICA_BIN`) in `.env` — see `.env.example`.

### Per-user overrides via `.env`

Both wrappers source `$HOME/bin/multica-local-workdir/.env` at startup (if present). Copy `.env.example` to `.env` and set what you need:

```
CLAUDE_BIN=/abs/path/to/claude      # default: `claude` on PATH
OPENCODE_BIN=/abs/path/to/opencode  # default: `opencode` on PATH
```

`.env` is gitignored — your local overrides won't be committed.

### Set agent concurrency to 1

In each agent's multica configuration, set `concurrency: 1`. Two sessions of the same agent running concurrently would share the same project directory, which causes conflicts (lock files, git state, edits stepping on each other).

## Telling the wrapper which project to use

The wrapper needs to know which directory is your **real project** (so it can `cd` there and pick up project-scoped config). Two equivalent ways:

### Option A — multica per-agent extra args (recommended)

In multica's agent configuration, append `--working-directory <abs-path-to-project>` to the agent's extra args. The wrapper consumes these two args and removes them before passing the rest to the underlying CLI.

### Option B — environment variable

Set `LOCAL_WORKING_PATH=/abs/path/to/project` in the environment multica launches agents under.

If both are present, the CLI flag wins.

## How the workspace instructions get injected

### claude

The wrapper appends the workspace's `CLAUDE.md` to claude's system prompt via `--append-system-prompt "$(cat $WORKSPACE_DIR/CLAUDE.md)"`. This is applied fresh on every invocation, including on `--resume` continuations — verified to not stack or duplicate.

> Side note that tripped us up: claude's `--add-dir <path>` does **not** auto-discover `<path>/CLAUDE.md` into the system prompt, despite a hint to the contrary in the `--bare` flag's help text. `--append-system-prompt` is the right tool.

### opencode

opencode has no `--append-system-prompt` equivalent, so the wrapper uses opencode's own config-and-env-var interpolation:

- `opencode-config.json` (next to the wrapper) declares `"instructions": ["{env:EXTRA_INSTRUCTIONS_PATH}"]`.
- The wrapper exports `EXTRA_INSTRUCTIONS_PATH=$WORKSPACE_DIR/AGENTS.md` and `OPENCODE_CONFIG=<path-to-opencode-config.json>` before exec'ing opencode.
- opencode loads the instructions file alongside the project's own.

If you already use a custom `OPENCODE_CONFIG` for non-multica work, note that this wrapper overrides it for multica sessions only. To keep both, copy the `instructions` interpolation snippet into your existing custom config.

## Quick test

```bash
# Sanity test for claude:
mkdir -p /tmp/mwtest/project /tmp/mwtest/workspace
echo "SECRET CODEWORD: pineapple-42" > /tmp/mwtest/workspace/CLAUDE.md
cd /tmp/mwtest/workspace
echo "What is the SECRET CODEWORD? Reply with only the codeword." | \
  "$HOME/bin/multica-local-workdir/claude" -p --permission-mode bypassPermissions \
  --working-directory /tmp/mwtest/project
# Expected: pineapple-42

# Same for opencode (replace CLAUDE.md with AGENTS.md):
echo "SECRET CODEWORD: pineapple-42" > /tmp/mwtest/workspace/AGENTS.md
cd /tmp/mwtest/workspace
"$HOME/bin/multica-local-workdir/opencode" run \
  "What is the SECRET CODEWORD? Reply with only the codeword." \
  --dangerously-skip-permissions \
  --working-directory /tmp/mwtest/project
# Expected: pineapple-42
```
