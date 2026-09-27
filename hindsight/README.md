# Per-agent Hindsight memory for multica (omp / pi wrapper)

Give each multica agent its own [Hindsight](https://github.com/vectorize-io/hindsight)
memory bank, with a per-agent scope and a set of durable "mental model" summaries.

The `pi` wrapper (omp variant) maps a couple of per-agent env vars to omp's
`HINDSIGHT_*`, so no per-bank wiring is needed beyond setting env in multica.

## Files

| File | Purpose |
|---|---|
| `manifest.json` | **Your input — not committed** (copy `manifest.json.example`, fill it in) |
| `manifest.json.example` | Minimal schema reference for the manifest |
| `create-banks.sh` | Create/patch each selected agent's bank and import its mental models |
| `set-agent-envs.sh` | Set `LWD_HINDSIGHT_BANK_ID` + `LWD_HINDSIGHT_SCOPING` on each selected agent |

## Prerequisites

- `multica` CLI authenticated (agent owner or workspace admin)
- `jq`, `curl`, `python3`
- A Hindsight server, and agents running through the `pi` wrapper (omp variant)

## How it works

`set-agent-envs.sh` sets two env vars per agent:

- `LWD_HINDSIGHT_BANK_ID=agent-<slug>` → wrapper exports `HINDSIGHT_BANK_ID`
- `LWD_HINDSIGHT_SCOPING=global|per-project-tagged` → wrapper exports `HINDSIGHT_SCOPING`

The wrapper also exports `HINDSIGHT_RETAIN_EVERY_N_TURNS=1` (multica runs are
single-turn, so every run retains).

Scoping:

- **`global`** — one flat bank per agent. Simple; omp's `user-preferences` seed applies.
- **`per-project-tagged`** — the *same* bank id, but each retain is tagged
  `project:<cwd-basename>`. Recall returns this project's memories plus the
  untagged agent-level ones, and omp's project-scoped mental models
  (`project-conventions`, `project-decisions`) apply. Use it for project-bound
  agents (dev, sysadmin); `global` otherwise.

Note omp's config default is `per-project`, which turns the bank id into a
*prefix* (`<id>-<cwd-basename>`). The wrapper overrides scoping so the id is exact.

## Manifest

See `manifest.json.example`. Top level:

| Field | Meaning |
|---|---|
| `hindsight_api` | Base URL of the Hindsight server (overridable with `HINDSIGHT_API`) |
| `agents[]` | One entry per agent |
| `agents[].agent_id` | multica agent id |
| `agents[].bank_id` | Hindsight bank id (`agent-<lowercase name, spaces removed>`) |
| `agents[].scoping` | `global` or `per-project-tagged` |
| `agents[].selected` | Only `true` entries are processed |
| `agents[].reflect_mission` / `retain_mission` / `observations_mission` | Bank missions (agent-specific instructions to the memory pipeline) |
| `agents[].mental_models[]` | Standing summaries imported into the bank |

Build the agent list from multica:

```bash
multica agent list   --output json > /tmp/agents.json
multica runtime list --output json > /tmp/runtimes.json
```

Only agents on omp/pi-protocol runtimes consume `HINDSIGHT_*`; mark everything
else `selected: false`.

## Mental models

Imported into every selected bank. Injected into the agent's instructions at
boot (omp loads existing models; it does not overwrite them). Matched by `id`,
so re-running updates them.

| id | name | source_query (summary) |
|---|---|---|
| `user-preferences` | User Preferences | durable preferences in coding style, tooling, communication, review |
| `red-lines` | Red Lines & Standing Rules | standing "do not do this" instructions meant to persist |
| `where-things-live` | Systems of Record & Locations | locations of sources of truth — **not their volatile contents** |
| `decision-log` | Decision Log | durable decisions with rationale, incl. supersessions |
| `failure-modes` | Failure Modes & Fixes | recurring failures and fixes, with version/date context |

Guiding rule: store durable principles, decisions, and **pointers** to sources of
truth — never the volatile contents of a source (host lists, current goals,
ticket state). Those belong in the source, not in memory.

## Apply

```bash
cd hindsight
cp manifest.json.example manifest.json   # then fill it in
ONLY=<name-or-bank> ./create-banks.sh    # canary: one bank + its mental models
./create-banks.sh                        # the rest
ONLY=<name-or-bank> ./set-agent-envs.sh  # canary: one agent
./set-agent-envs.sh                      # the rest
```

Both scripts accept `ONLY=<regex>` (matches name or bank id, case-insensitive)
and `MANIFEST=<path>`.

`create-banks.sh` is idempotent: `PUT`/`PATCH` are upserts and `/import` matches
mental models by `id`. `set-agent-envs.sh` reads each agent's current
`custom_env`, re-sends every existing key as the CLI's `****` sentinel (which
preserves the stored value), adds the two hindsight vars, then re-reads and
verifies the prior keys survived. It **fails closed**: if an agent's env cannot
be read, it skips that agent rather than replacing it. Secrets are never read
into the payload or printed.

## Caveats

- Bank ids cannot be renamed. A typo leaves an empty bank behind.
- Mental models are generated server-side (via reflect) asynchronously and
  refreshed after consolidation, so they carry a real LLM cost.
- Hindsight does not expire facts that silently become false. Prefer durable
  facts/pointers, and curate the rest (`PATCH .../memories/{id}` to invalidate).
