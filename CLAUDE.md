# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Four small bash wrappers, a provider-switcher helper, and an opencode config snippet. No build system, no tests, no language runtime — changes are pure shell. Treat each script as single-purpose and keep them self-contained.

- `multica-daemon` — entry point. Sources `.env`, exports `MULTICA_CLAUDE_PATH` / `MULTICA_OPENCODE_PATH` / `MULTICA_PI_PATH` pointing at the wrapper scripts in this directory, then `exec`s the real `multica daemon`. This is how the multica binary is told to use our wrappers instead of `claude` / `opencode` / `pi` directly.
- `claude` — wrapper around the Claude Code CLI. Honours `LWD_CLAUDE_PROVIDER` (falling back to `LWD_PROVIDER`) to source a `claude-providers/<name>.sh` redirect.
- `opencode` — wrapper around the opencode CLI.
- `pi` — wrapper around the pi CLI. Routes to either `omp` (oh-my-pi) or vanilla `pi` via `LWD_PI_VARIANT` (`omp`→`OMP_BIN`, `pi`→`PI_BIN`); the bin paths and the default variant live in `.env`, the variant is overridable per-agent (ambient env > `.env`, same capture idiom as the claude wrapper's `LWD_*` knobs). `LWD_MODEL`/`LWD_EFFORT` carry over from the claude wrapper with the same task > ambient > `.env` precedence; the provider knob is `LWD_PI_PROVIDER` (falling back to `LWD_PROVIDER`): on the omp variant a resolved `<name>` loads a `pi-providers/<name>.yml` overlay via omp's `--config`, `LWD_MODEL`→`--model`, and `LWD_EFFORT`→`--thinking` (pi/omp's reasoning-level flag). The per-task settings machinery (issue labels + assignee gate) is ported verbatim from the claude wrapper.
- `opencode-config.json` — referenced by the `opencode` wrapper via `OPENCODE_CONFIG`; uses `{env:EXTRA_INSTRUCTIONS_PATH}` interpolation so opencode loads the workspace's `AGENTS.md` as an instructions file.
- `set-claude-provider` — CLI helper that edits the active (uncommented) `LWD_CLAUDE_PROVIDER` / `LWD_MODEL` assignments in `.env`, validating the provider name against `claude-providers/` before writing. Commented example lines are documentation — it must not touch them. (The generic `LWD_PROVIDER` fallback is set directly in `.env`; task `provider:` labels or per-agent `LWD_PI_PROVIDER` are independent.)
- `claude-providers/<name>.sh` — sourced by the `claude` wrapper when the resolved provider (`LWD_CLAUDE_PROVIDER` > `LWD_PROVIDER`) is `<name>`. Each file exports `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / model defaults to redirect claude at a non-Anthropic backend (DeepSeek, Ollama, …). Files may honour `LWD_MODEL` as a convention to let callers switch models without editing the file. Missing provider names fail loud — silent fallthrough would burn real Anthropic credits on a typo. Provider files reference secrets like `$DEEPSEEK_API_KEY` from `.env` rather than embedding them. `ollama launch claude --model X` was verified empirically to do nothing more than set env vars (so it fits this pattern, no special-casing needed).
- `pi-providers/<name>.yml` — loaded by the `pi` wrapper **on the omp variant only** when the resolved provider (`LWD_PI_PROVIDER` > `LWD_PROVIDER`) is `<name>` (≠ `anthropic`), via omp's repeatable, deep-merged `--config <path>` flag. It is a partial `config.yml`-style overlay (model roles, thinking, search provider, …) — a named *preset*, the pi-side analog of `claude-providers/<name>.sh`. omp's `--config` deep-merges over `~/.omp/agent/config.yml`, so an overlay may set only the keys it overrides. Missing names fail loud (operator typo), matching the claude wrapper. The vanilla `pi` variant has no `--config` flag (`pi --config` → Unknown option — verified), so the provider is warned + ignored there; use native `--model`/`--provider` args instead. `set-claude-provider` only validates against `claude-providers/`, so a name must exist there to be set that way even if its `pi-providers/` counterpart is what a pi agent consumes. Provider var resolution is `LWD_CLAUDE_PROVIDER`/`LWD_PI_PROVIDER` (wrapper-specific, wins) > `LWD_PROVIDER` (generic fallback) at each of the ambient > `.env` layers; a task `provider:` label beats all.

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

In the `claude` and `pi` wrappers a `path: …` settings label on the issue (see below) outranks both of these.

The arg is scanned with a loop over all positions, not just `args[count-2]` — the daemon may put it before the prompt positional. If you re-introduce a tail-only check, the flag will silently be ignored when a prompt arg follows.

The same loop in the `claude` wrapper also strips `--strict-mcp-config` when `LWD_ALLOW_MCP=1`. multica injects that flag to disable project/user MCP configs (sandboxing for its SaaS); the opt-in flips it off so self-hosted setups can use `.claude/settings.json` MCP servers. Default off — turning it on bypasses multica's intended sandboxing.

## Effort level (`LWD_EFFORT`)

`LWD_EFFORT=<low|medium|high|xhigh|max>` makes the `claude` wrapper inject `--effort <level>` unless the caller already passed `--effort` (both `--effort x` and `--effort=x` forms are detected). The value is validated against the allowed set and fails loud on a typo — same philosophy as the loud failure on an unknown `LWD_PROVIDER`, so a bad value doesn't reach claude and abort the session mid-run. Priority is ambient env > provider file > .env, so the ambient override is captured before `.env` is sourced and re-applied after the provider file runs (a provider may pin an effort its backend tolerates) — identical handling to `LWD_FALLBACK_MODEL`. The `pi` wrapper reuses the same knob but maps it to pi/omp's `--thinking` flag (the reasoning-level analog), validated against the intersection of omp's and pi's thinking levels (`minimal|low|medium|high|xhigh`); `max` is claude-only and is warn-and-ignored on the pi wrapper.

The wrapper does **not** read the prompt to classify effort (the prompt arrives over stdin as stream-json; reading it would consume it). Per-agent classification is just multica's per-agent env. Per-*task* classification is the settings labels below.

## Per-task settings (labels)

The `claude` and `pi` wrappers let a single task override settings via its **issue labels**, which are structured data on the issue itself — no free-text parsing of the user-authored description, and the only per-task signal available without reading the prompt. (The `pi` wrapper ports this machinery verbatim; only the downstream flag each key maps to differs — see below.) Mechanism:

1. multica writes the task's `multica issue get <id>` command into the workspace `CLAUDE.md`. The wrapper greps the first UUID out of `$WORKSPACE_DIR/CLAUDE.md`.
2. It runs `multica issue get <id> --output json` and reads `.labels[].name` with `jq` (so `jq` is a soft dependency — absent `jq` just skips task settings).
3. Labels named `key: value` (e.g. `provider: deepseek`, `effort: high`) carry the settings. The name is split on the **first** colon — a model value like ollama's `qwen3:32b` keeps its colon — the key is lowercased and space-stripped, the value is whitespace-trimmed and one pair of surrounding double quotes is dropped (forgiving a pasted `path: "/x y"`). Labels without a colon or with an unrecognised key are other people's labels and are ignored silently. Recognised keys map straight onto the existing env knobs:

   | label name     | env var              |
   |----------------|----------------------|
   | `effort: X`    | `LWD_EFFORT`         |
   | `model: Y`     | `LWD_MODEL`          |
   | `provider: Z`  | `LWD_PROVIDER`       |
   | `path: P`      | `LOCAL_WORKING_PATH` |

   (Settings used to live in a `# Task Settings` block in the description — see the ignore-note rule below for the legacy handling.)

   The env-var mapping above is shared by both wrappers; only the **downstream flag** each env var drives differs: on `claude`, `LWD_EFFORT`→`--effort`, `LWD_MODEL`→`--model` (native) or provider-file env, the resolved provider→sources `claude-providers/<name>.sh`; on `pi`, `LWD_EFFORT`→`--thinking`, `LWD_MODEL`→`--model`, the resolved provider→omp `--config pi-providers/<name>.yml` (omp variant; ignored on vanilla pi). "Resolved provider" = `LWD_CLAUDE_PROVIDER`/`LWD_PI_PROVIDER` (wins) over `LWD_PROVIDER` (fallback); a task `provider:` label overrides the lot.

Task settings sit at the **top of every precedence chain**: task > per-agent (ambient env) > provider file > .env. `effort` is overlaid after the ambient re-apply; `provider`/`model` are overlaid before provider selection (so a task provider sources the right file and a task model reaches it); `path` is overlaid after the argv/env working-dir resolution.

**Assignee gate (who the labels apply to).** Task Settings describe how the task's *assigned* work should run, so the wrapper honours them only when the **running agent is the one the work belongs to** — otherwise a reviewer/orchestrator/squad-member agent invoked on the same issue would inherit pins written for someone else. The gate only runs when at least one settings label is present (no label → nothing to apply → no gate lookups). The wrapper resolves its own agent id from the `**You are: NAME** (ID: \`…\`)` line multica writes into the workspace `CLAUDE.md`: it greps the line by `You are: ` (the only line carrying it — the issue/comment ids elsewhere in the file lack it) and pulls the UUID out by regex rather than a fixed backtick column, so a delimiter change alone won't break it. **Fallback** (logged as a `WARNING` to `claude.log`): if no `You are:` line is found, it scans every UUID in the file and keeps the ones `multica agent get <id>` confirms are agents (issue/comment ids fail this and drop out), applying only when **exactly one** agent id remains — 0 or >1 is ambiguous, so the gate stays closed. This survives a line-format change while making the drift visible. The wrapper applies the labels only when **either**:
- the issue is assigned to *this* agent — `assignee_type == "agent"` and `assignee_id` == our id (from `multica issue get`), **or**
- the issue is assigned to a squad *this* agent leads — `assignee_type == "squad"` and `multica squad get <assignee_id>`'s `leader_id` == our id.

Every other case (a different agent, a squad we don't lead, a `member`, an unassigned/`null` issue, or an id we can't resolve) leaves Task Settings **off** for this agent. The gate stays **closed on uncertainty** (can't read our id / the assignee → don't apply) — the safe direction, matching the feature's fail-open philosophy. `task_labels_seen` / `task_block_seen` (the ignore-note below) are tracked *independently* of the gate, so a non-assignee agent is still told the settings labels (and any legacy block) it sees aren't task content.

`model` resolves in two ways depending on backend. With a **provider** active, the provider file consumes `LWD_MODEL` (sets `ANTHROPIC_MODEL` / `ANTHROPIC_DEFAULT_*_MODEL`) as before. On the **native Anthropic** backend (`LWD_PROVIDER` empty or `anthropic`), the wrapper injects `--model "$LWD_MODEL"` into argv — unless the caller already passed `--model`. It's native-only on purpose: injecting `--model` *and* letting a provider file set the model env would double-handle it. This applies to any source of `LWD_MODEL` (task, ambient, .env), not just task settings.

**Design rules baked in (don't regress these):**
- **Fail-open, always.** The fetch/parse runs on *every* launch (including every `--resume` turn — JC accepted the ~0.3s cost rather than gate it). A missing `jq`, a changed `CLAUDE.md` format, or a failed/garbled `issue get` must **skip silently and log to `claude.log`** (`task-settings:` prefix) — never abort, or it breaks every agent turn. This is the opposite of the loud failure on an operator-owned `LWD_PROVIDER`, because labels are softer, user-controlled input.
- **Validate task values, warn-and-ignore (never abort).** A bad `effort` (incl. `ultracode` — deliberately *not* a claude `--effort` level), an unknown `provider`, or a non-directory `path` is dropped with a log line. Because task effort is pre-validated, the loud `LWD_EFFORT` check later only ever fires on operator env/.env typos.
- **Parse with process substitution, not a pipeline.** `jq ... | while read` would run the loop in a subshell and lose the label assignments; `done < <(... jq ...)` keeps them in the current shell.
- **Opt out with `LWD_TASK_SETTINGS=0`** (`off`/`false`/`no` too). On by default. The `provider`/`path` labels let issue authors source a bash file / relocate the working dir — acceptable because this project is self-hosted with trusted issue authors, but the opt-out is the escape hatch.
- **Tell the agent to ignore the settings.** When settings labels are present (`task_labels_seen`) and/or a legacy `# Task Settings` heading is in the description (`task_block_seen` — the block is **detected but no longer parsed**), the wrapper appends a note to the agent's system prompt: those are wrapper config, not task content. Both flags are tracked *independently of the assignee gate*, and the note is deliberately worded without claiming "already applied" — a non-assignee agent still sees the labels/block but the gate did *not* apply them, so the note only asserts they aren't task instructions. The note is folded into the **same** `--append-system-prompt` as the workspace CLAUDE.md — claude's `--append-system-prompt` is not reliably repeatable, so a second flag could clobber the first.

## Concurrency constraint

Each agent in multica must be configured with `concurrency: 1`. Two sessions sharing the same project directory would collide on git state, lock files, and edits. There is no in-wrapper locking — the constraint is enforced by the operator's multica config.

## Running locally

```bash
cp .env.example .env   # set MULTICA_SERVER_URL, optionally override *_BIN paths
./multica-daemon
```

`.env` is gitignored. The wrappers source `.env` from `SCRIPT_DIR`, so they work regardless of where multica launches them from.

## Testing changes

There is no test suite. To validate a wrapper change, replay a real argv against an isolated copy: copy the wrapper into a temp dir (so it sources no real `.env` and logs to a throwaway `claude.log`), stub the binaries it calls with scripts that dump argv/env (`CLAUDE_BIN`, `MULTICA_BIN`, plus a fake workspace `CLAUDE.md` for the task-settings path), run it, and assert on the dump. Don't rely on `set -u` semantics — the scripts use `set -e` only, and empty-array expansions are intentional.

## Commit style

Short imperative subject, no Claude/Co-Authored footers (per user global instructions). Recent history is the reference for tone.

# Lessons

The `lessons/` directory (like `health-responder/`) is **local and untracked** — it exists on the primary host only, so these files may be absent on a fresh clone. The one-line summaries below carry the key facts either way.

- `lessons/multica-desktop-daemon-supervisor.md` — how the Multica Desktop app supervises/restarts its own daemon (profile/port/health/version logic, reverse-engineered from `app.asar`), and the `health-responder/` decoy that stops it.
- `lessons/multica-agent-types-are-hardcoded.md` — multica's agent/provider types are a compiled-in enum (claude, codex, copilot, opencode, openclaw, hermes, gemini, pi, cursor, kimi, kiro, antigravity); you can't add a new agent *type* with a wrapper alone.
- `lessons/opencode-go-claude-provider.md` — the `opencode-go` claude-provider routes claude through OpenCode Go's open-weight models, which need the local `oc-go-cc` translating proxy (no native Anthropic endpoint).
- `lessons/export-tests-need-clean-env.md` — verify export-propagation with `env -i`; the Claude Code Bash tool runs under zsh, which leaks exports across calls and gives false positives. Provider files must `export` every var.
- `lessons/omp-has-config-overlay-pi-does-not.md` — omp supports `--config=<path>` (repeatable, deep-merged config.yml-style overlay); vanilla `pi` does not (`pi --config` → Unknown option). So `LWD_PROVIDER`/`pi-providers/*.yml` is omp-only on the pi wrapper; vanilla pi uses native `--model`/`--provider`.
