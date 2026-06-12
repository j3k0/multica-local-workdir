# multica-local-workdir

Thin shell wrappers that let [multica](https://multica.ai/) agents work directly inside your local project directory — so project-scoped skills, slash commands, MCP servers, and settings actually load — without patching multica itself.

## The problem

multica creates a per-session **workspace directory** (e.g. `~/multica_workspaces/<uuid>/.../workdir`) and runs the agent CLI from there. As a result:

1. **Project-scoped configuration isn't loaded.** Skills, slash commands, subagents, MCP servers, settings, hooks — everything that lives under `<project>/.claude/` or `<project>/.opencode/` — is keyed strictly off the agent's CWD. Running from the workspace means none of it loads.
2. **The workspace's instructions file is the only one that loads.** multica writes a `CLAUDE.md` (or `AGENTS.md`) into the workspace with agent-specific behaviour instructions. If you `cd` into the project to fix #1, you lose those.
3. Dev agents working on large monorepos or heavy setup projects need to go fresh for every session.

These wrappers fix those: they `cd` into the project so project-scoped config loads, then re-inject the workspace's instructions file into the agent's system prompt.

## Install

```bash
git clone https://github.com/j3k0/multica-local-workdir.git
cd multica-local-workdir
cp .env.example .env   # then edit — set MULTICA_SERVER_URL
./multica-daemon
```

## Telling the wrapper which project to use

Set `LOCAL_WORKING_PATH=/abs/path/to/project` in the environment multica launches agents under. (Alternatively, append `--working-directory <path>` to the agent's extra args in multica's per-agent configuration.)

## Set agent concurrency to 1

In each agent's multica configuration, set `concurrency: 1`. Two sessions of the same agent running concurrently would share the same project directory — lock files, git state, and edits would step on each other.

## Example agent configuration

![Agent configuration in multica: LOCAL_WORKING_PATH set under Environment, Concurrency set to 1](docs/agent-config.png)

## Setting the effort level (claude)

Set `LWD_EFFORT=<level>` and the `claude` wrapper injects `--effort <level>` (unless the caller already passed `--effort`). Valid levels are `low`, `medium`, `high`, `xhigh`, `max`; an unknown value fails loud rather than letting claude reject the flag mid-session.

Because env vars can be set **per agent** in multica, a per-agent `LWD_EFFORT` is effectively dynamic effort classification: give each agent the effort its job warrants — `max` for an orchestrator or code reviewer, `low` for a trivial-chore agent — without the wrapper inspecting the (streamed) prompt. Set it globally in `.env` as a default, or per-agent in multica; ambient values win over the `.env` default, and a provider file may pin its own effort (priority: ambient env > provider file > .env). For **per-task** effort, see below.

## Per-task settings from issue labels (claude)

For effort (and a few other knobs) that vary **per task** rather than per agent, the `claude` wrapper reads settings from the issue's **labels**. multica writes the task's `multica issue get <id>` command into the workspace `CLAUDE.md`, so the wrapper can pull the issue ID, fetch the issue, and apply its labels — all without reading the (streamed) prompt.

Add labels named `key: value` to the issue, e.g.:

```
effort: high
model: claude-opus-4-8
provider: deepseek
path: /abs/path/to/project
```

Each label maps to the matching env knob (`effort`→`LWD_EFFORT`, `model`→`LWD_MODEL`, `provider`→`LWD_PROVIDER`, `path`→`LOCAL_WORKING_PATH`); add only the ones you want, and `effort: …` alone is the common case. Any other label (no colon, or another key like `area: billing`) is ignored by the wrapper — labels keep working as regular labels.

Parsing is forgiving: the name is split on the **first** colon (so `model: qwen3:32b` keeps its colon), the key is case-insensitive, the value is whitespace-trimmed, and one pair of surrounding double quotes is dropped (`path: "/x y"` works).

Labels are configuration, not instructions, so when settings labels are present the wrapper appends a note to the agent's system prompt saying they're wrapper config and not part of the task. (Settings used to live in a `# Task Settings` block in the issue description; such a block is still *detected* — the agent is told to ignore it — but **no longer parsed**. Migrate old blocks to labels.)

Task settings take the **highest priority** — above per-agent (custom args / ambient env) and global (`.env`). Notes:

- **Only the assigned agent gets them.** The labels describe how the task's assigned work should run, so the wrapper applies them only when the running agent *is* the work's owner: the issue is assigned to this agent (`assignee_type: agent`), or to a squad this agent **leads**. Any other agent invoked on the same issue (a different agent, a squad member who isn't leader, a human/`member` assignee, or an unassigned issue) runs with its own config and ignores the labels. The wrapper learns its own agent id from the `You are: … (ID: …)` line in the workspace `CLAUDE.md`; if it can't determine that or the assignee, it errs toward *not* applying.
- Needs `jq` on `PATH`; without it, task settings are silently skipped.
- Invalid values are ignored with a line in `claude.log` (never abort) — e.g. an effort outside `low|medium|high|xhigh|max`, an unknown provider, or a non-existent path.
- `model` resolves per backend: on the native Anthropic backend the wrapper injects `--model` (unless the caller already passed one); with a provider active the provider file consumes `LWD_MODEL` as before. Either way a `model:` label works.
- It runs a `multica issue get` on every launch (~0.3s). Opt out with `LWD_TASK_SETTINGS=0`.
- `provider` and `path` let issue authors source a provider script / relocate the working dir; fine for self-hosted with trusted issue authors, otherwise opt out.

## Allowing project MCP servers (claude)

multica injects `--strict-mcp-config` into the `claude` CLI, which makes claude ignore any MCP servers configured in the project (`.claude/settings.json`) or in the user's claude config. That's a sensible default for multica's hosted SaaS, but on a self-hosted setup the operator owns the project and usually wants those servers to load (see [multica#2532](https://github.com/multica-ai/multica/issues/2532)).

Set `LWD_ALLOW_MCP=1` in `.env` (or per-agent in multica) and the `claude` wrapper strips the flag before exec'ing the CLI. Default is off — only opt in if you trust every MCP server the project can reach. The env var can also be set per agent in multica.

## Routing claude through a different provider

Set `LWD_PROVIDER=<name>` and the `claude` wrapper sources `claude-providers/<name>.sh` before exec'ing the CLI. The provider file is just a bash file that exports `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, model defaults, etc. — claude itself does the rest.

Two providers ship as examples:

- **`deepseek`** — DeepSeek's Anthropic-compatible API. Requires `DEEPSEEK_API_KEY` in `.env`.
- **`ollama`** — local Ollama daemon. Use any model the daemon can run (e.g. self-hosted `qwen3.6:35b`), or an Ollama Cloud model like `glm-5.1:cloud` (requires `ollama signin`). No separate key in either case.

Add your own by dropping a `claude-providers/<name>.sh` file alongside them. Provider files may honour `LWD_MODEL` to let you switch models without editing the file. Set `LWD_PROVIDER` and `LWD_MODEL` in `.env` as project defaults, or per-agent in multica; values already in the environment (e.g. set per-agent in multica) take precedence over the global default.

Unknown provider names fail loud rather than silently falling back to Anthropic (which would burn real credits on a typo).

### Switching providers from the CLI

`set-provider` edits the active `LWD_PROVIDER` / `LWD_MODEL` lines in `.env` for you, so you don't have to hand-edit the file to flip the global default. It only touches uncommented assignments — the commented examples stay as documentation — and validates the provider against `claude-providers/` before writing.

```bash
./set-provider                                # show current values + available providers
./set-provider deepseek                       # set LWD_PROVIDER
./set-provider deepseek 'deepseek-v4-pro[1m]' # set provider + model
./set-provider -m glm-5.1:cloud               # set LWD_MODEL only
./set-provider --clear-model                  # drop the model override
./set-provider none                           # clear both — back to real Anthropic
```

An unknown provider fails loud and lists the valid names. Per-agent overrides in multica still win over whatever this writes to `.env`.
