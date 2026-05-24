# multica-local-workdir

Thin shell wrappers that let [multica](https://multica.ai/) agents work directly inside your local project directory — so project-scoped skills, slash commands, MCP servers, and settings actually load — without patching multica itself.

## The problem

multica creates a per-session **workspace directory** (e.g. `~/multica_workspaces/<uuid>/.../workdir`) and runs the agent CLI from there. Two things break as a result:

1. **Project-scoped configuration isn't loaded.** Skills, slash commands, subagents, MCP servers, settings, hooks — everything that lives under `<project>/.claude/` or `<project>/.opencode/` — is keyed strictly off the agent's CWD. Running from the workspace means none of it loads.
2. **The workspace's instructions file is the only one that loads.** multica writes a `CLAUDE.md` (or `AGENTS.md`) into the workspace with agent-specific behaviour instructions. If you `cd` into the project to fix #1, you lose those.

These wrappers fix both: they `cd` into the project so project-scoped config loads, then re-inject the workspace's instructions file into the agent's system prompt.

## Install

```bash
git clone <this-repo-url> multica-local-workdir
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
