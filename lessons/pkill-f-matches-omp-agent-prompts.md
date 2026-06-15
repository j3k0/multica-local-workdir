# `pkill -f` / `pgrep -f` matches omp agent prompts — can kill live agents

**as of 2026-06-15**

`pkill -f '<text>'` and `pgrep -f '<text>'` match the **full command line**.
omp/pi agents are launched as:

    bun /Users/jeko/.bun/bin/omp --thinking <lvl> --config <overlay> \
        --append-system-prompt <…/AGENTS.md> -p --mode json --session <…> \
        <ENTIRE PROMPT TEXT>

and multica's agent prompts contain the literal string `multica issue get <uuid>`.
So `pkill -f 'multica issue get'` matches **live omp coding agents**, not just
stray `multica` CLI calls.

This terminated pid 71560 (issue `a274ecb0-…`) mid-run while cleaning up a hung
`multica issue get` test call.

## Rule
- Never use `-f` with text that can appear in an agent prompt ("multica issue
  get", "Your assigned issue ID is", issue keys/UUIDs, etc.).
- To target only the `multica` CLI, match the process name, e.g.
  `pkill -x multica` (exact-name match), or pgrep for `^multica ` at the start.
- To find live omp agents: `pgrep -fl 'bun.*omp'` or `pgrep -fl 'omp .*--mode json'`.
