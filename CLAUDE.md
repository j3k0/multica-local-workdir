# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Four small bash wrappers and an opencode config snippet. No build system, no tests, no language runtime — changes are pure shell. Treat each wrapper as a single-purpose script and keep them self-contained.

- `multica-daemon` — entry point. Sources `.env`, exports `MULTICA_CLAUDE_PATH` / `MULTICA_OPENCODE_PATH` / `MULTICA_PI_PATH` pointing at the wrapper scripts in this directory, then `exec`s the real `multica daemon`. This is how the multica binary is told to use our wrappers instead of `claude` / `opencode` / `pi` directly.
- `claude` — wrapper around the Claude Code CLI.
- `opencode` — wrapper around the opencode CLI.
- `pi` — wrapper around the pi CLI.
- `opencode-config.json` — referenced by the `opencode` wrapper via `OPENCODE_CONFIG`; uses `{env:EXTRA_INSTRUCTIONS_PATH}` interpolation so opencode loads the workspace's `AGENTS.md` as an instructions file.
- `claude-providers/<name>.sh` — sourced by the `claude` wrapper when `LWD_PROVIDER=<name>` is set. Each file exports `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / model defaults to redirect claude at a non-Anthropic backend (DeepSeek, Ollama, …). Files may honour `LWD_MODEL` as a convention to let callers switch models without editing the file. Missing provider names fail loud — silent fallthrough would burn real Anthropic credits on a typo. Provider files reference secrets like `$DEEPSEEK_API_KEY` from `.env` rather than embedding them. `ollama launch claude --model X` was verified empirically to do nothing more than set env vars (so it fits this pattern, no special-casing needed).

## The core trick (read before editing wrappers)

multica runs the agent CLI from a per-session **workspace directory** (e.g. `~/multica_workspaces/<uuid>/.../workdir`). That breaks two things, and the wrappers fix both:

1. **Project-scoped config (`.claude/`, `.opencode/`, MCP servers, hooks, skills, slash commands) only loads when the agent's CWD is the project root.** The wrappers `cd` into the user's project before exec'ing the real binary.
2. **The workspace's instructions file (`CLAUDE.md` / `AGENTS.md`) lives in the workspace, not the project, so it stops loading once we `cd` away.** The wrappers capture `WORKSPACE_DIR="$(pwd)"` before the `cd` and re-inject the workspace's instructions:
   - `claude` prepends `--append-system-prompt "$(cat $WORKSPACE_DIR/CLAUDE.md)"` to argv. `--add-dir` was tried and does **not** auto-discover `CLAUDE.md` from added dirs (verified empirically) — that's why we use `--append-system-prompt`.
   - `opencode` exports `EXTRA_INSTRUCTIONS_PATH=$WORKSPACE_DIR/AGENTS.md` and `OPENCODE_CONFIG=$SCRIPT_DIR/opencode-config.json`, and the config's `instructions` array interpolates that env var.
   - `pi` prepends `--append-system-prompt` for both `CLAUDE.md` and `AGENTS.md` from the workspace. pi auto-discovers context files from CWD (the project dir), but the workspace's files aren't in CWD after the `cd`.

**opencode `--dir` overrides CWD.** The daemon passes `--dir <workspace>` to opencode; if the wrapper only does `cd "$project"` without rewriting `--dir`, opencode ignores the `cd` and runs from the workspace anyway (verified empirically — symptom: `pwd` in tool calls returns the workspace path, and only `AGENTS.md` is visible). The wrapper rewrites `--dir`'s value to the project path (or adds `--dir` if absent). `claude` and `pi` don't have this flag — `--add-dir` whitelists access but doesn't relocate the project root — so those wrappers rely on `cd` alone.

If you change either re-injection mechanism, verify the other still works the same way — the two CLIs have asymmetric config systems.

## How the working directory is resolved

Precedence in all three wrappers:

1. `--working-directory <path>` anywhere in argv. The wrapper strips the flag + value from argv before exec'ing the real binary.
2. `LOCAL_WORKING_PATH` environment variable (set in the multica agent's environment).

The arg is scanned with a loop over all positions, not just `args[count-2]` — the daemon may put it before the prompt positional. If you re-introduce a tail-only check, the flag will silently be ignored when a prompt arg follows.

The same loop in the `claude` wrapper also strips `--strict-mcp-config` when `LWD_ALLOW_MCP=1`. multica injects that flag to disable project/user MCP configs (sandboxing for its SaaS); the opt-in flips it off so self-hosted setups can use `.claude/settings.json` MCP servers. Default off — turning it on bypasses multica's intended sandboxing.

## Effort level (`LWD_EFFORT`)

`LWD_EFFORT=<low|medium|high|xhigh|max>` makes the `claude` wrapper inject `--effort <level>` unless the caller already passed `--effort` (both `--effort x` and `--effort=x` forms are detected). The value is validated against the allowed set and fails loud on a typo — same philosophy as the loud failure on an unknown `LWD_PROVIDER`, so a bad value doesn't reach claude and abort the session mid-run. Priority is ambient env > provider file > .env, so the ambient override is captured before `.env` is sourced and re-applied after the provider file runs (a provider may pin an effort its backend tolerates) — identical handling to `LWD_FALLBACK_MODEL`.

There is no in-wrapper *classifier* (the prompt arrives over stdin as stream-json, so the wrapper can't read it without consuming it). "Dynamic" classification is achieved through multica's per-agent env: set `LWD_EFFORT` per agent so each runs at the effort its role warrants. If you ever want true content-based classification, it belongs upstream (the orchestrator that sets the per-agent env), not in this wrapper.

## Concurrency constraint

Each agent in multica must be configured with `concurrency: 1`. Two sessions sharing the same project directory would collide on git state, lock files, and edits. There is no in-wrapper locking — the constraint is enforced by the operator's multica config.

## Running locally

```bash
cp .env.example .env   # set MULTICA_SERVER_URL, optionally override *_BIN paths
./multica-daemon
```

`.env` is gitignored. The wrappers source `.env` from `SCRIPT_DIR`, so they work regardless of where multica launches them from.

## Testing changes

There is no test suite. To validate a wrapper change, exercise the actual argv parsing with a throwaway `bash -c '...'` script that replays a real argv (see commit `0dd1145` for the pattern). Don't rely on `set -u` semantics — the scripts use `set -e` only, and empty-array expansions are intentional.

## Commit style

Short imperative subject, no Claude/Co-Authored footers (per user global instructions). Recent history is the reference for tone.

# Lessons

- `lessons/multica-desktop-daemon-supervisor.md` — how the Multica Desktop app supervises/restarts its own daemon (profile/port/health/version logic, reverse-engineered from `app.asar`), and the `health-responder/` decoy that stops it.
- `lessons/multica-agent-types-are-hardcoded.md` — multica's agent/provider types are a compiled-in enum (claude, codex, copilot, opencode, openclaw, hermes, gemini, pi, cursor, kimi, kiro, antigravity); you can't add a new agent *type* with a wrapper alone.
- `lessons/opencode-go-claude-provider.md` — the `opencode-go` claude-provider routes claude through OpenCode Go's open-weight models, which need the local `oc-go-cc` translating proxy (no native Anthropic endpoint).
