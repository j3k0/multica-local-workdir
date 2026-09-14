# omp has a config overlay flag; vanilla pi does not

As of 2026-06-15 (omp v15.13.1, pi 0.79.x).

- **omp** supports `--config=<path>` — "Load an extra config.yml-style overlay
  for this run (**repeatable**)". It is a *partial* YAML deep-merged on top of
  `~/.omp/agent/config.yml`, so an overlay may set only the keys it overrides
  (`modelRoles`, `model.defaultThinkingLevel`, `providers.webSearch`, …). This
  is the natural mechanism for a named "provider/preset" on the pi wrapper:
  `pi-providers/<name>.yml` loaded via `--config`.
- **vanilla `pi` has no equivalent.** `pi --config <x>` → `Unknown option:
  --config`. It reads a shared global `~/.pi/agent/settings.json` (overridable
  via `PI_CODING_AGENT_DIR`) and uses native `--provider` / `--model` /
  `*_API_KEY` env. There is no per-run overlay path that's safe under
  concurrency (the config dir is shared across agents), so a wrapper can't
  cleanly overlay per-run for vanilla pi.

Implication for the `pi` wrapper: `LWD_PROVIDER` (and the `provider:` task
label) is **omp-only** — it loads `pi-providers/<name>.yml` via `--config` when
`LWD_PI_VARIANT=omp`, and is warned + ignored on the vanilla pi variant. Don't
try to synthesize an overlay for vanilla pi; route vanilla-pi model selection
through native `--model` / `--provider` (driven by `LWD_MODEL`) instead.

Also: omp model strings take the form `provider/model:thinking`
(e.g. `zai/glm-5.2:xhigh`), and `config.yml`'s `modelRoles` is a
`role -> "provider/model:thinking"` map (roles: default/slow/smol/plan/task/
vision/designer). `--model` overrides the `default` role for the session;
`--thinking` overrides `defaultThinkingLevel`.
