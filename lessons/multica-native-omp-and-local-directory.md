# multica 0.4.22: native omp runtime + local_directory (as of 2026-08-16)

Verified against multica 0.4.22 (daemon on gravity) and https://www.multica.ai/docs/project-resources + /docs/daemon-runtimes.

- **omp is a natively detected runtime** ("Oh-My-Pi", provider `omp`). The daemon
  finds `omp` on PATH and registers a runtime per workspace — no
  MULTICA_PI_PATH + LWD_PI_VARIANT=omp hack needed for basic use.
  Native invocation shape (observed live): `omp --append-system-prompt
  <workdir>/AGENTS.md -p --mode json --session ~/.multica/pi-sessions/<ts>.jsonl`.
- **UPDATE 2026-08-18 (CLI 0.4.26): `MULTICA_OMP_PATH` now exists.** Verified
  empirically: a throwaway-profile daemon started with
  `MULTICA_OMP_PATH=/tmp/sentinel` executed the sentinel (`--version`) during
  runtime detection and registered an "Oh-My-Pi" runtime from it. So the
  `multica-daemon` wrapper now exports `MULTICA_OMP_PATH` pointing at the
  repo's `omp` shim, and native Oh-My-Pi agents get the wrapper features
  directly. The custom-profile route below remains the fallback for daemons
  not started via `multica-daemon`. (In 0.4.22 the override enum excluded
  omp: `unknown agent type` / `MULTICA_<TYPE>_PATH` /
  `runtime profile create --protocol-family` listed 20 types with no omp.)
  omp rides the **pi protocol family** (same `-p --mode json` protocol, same
  pi-sessions dir). The profile route: create a custom runtime profile with
  `--protocol-family pi --command-name <cmd>` and pin per machine:
  `multica runtime profile set-path <profile-id> --path /abs/path/to/wrapper`.
  Profile command takes executable+args (no shell); a wrapper script as the
  command is the documented pattern.
- **local_directory project resource = native LOCAL_WORKING_PATH**:
  `multica project resource add <project> --type local_directory --local-path
  /abs/path --daemon-id <id> [--execution-mode worktree]`. Per project+daemon
  (max 1 per daemon per project), not per agent. Agent CWD becomes the local
  path; multica writes the instruction files (AGENTS.md etc.) and
  `.multica/project/resources.json` INTO that directory. Validates: absolute,
  exists, not system root/home parent, symlinks resolved.
  - `in_place` (default): tasks on the same dir serialize
    (`waiting_local_directory` state) — the native version of our
    "concurrency: 1" rule.
  - `worktree`: per-task git worktree, results land on branch
    `agent/<agent>/<task>`; concurrent; nothing touches your working copy.
- **Per-agent knobs are native too**: `agent create/update --model`,
  `--thinking-level`, `--custom-args` (JSON array, e.g. `["--config",
  "/abs/pi-providers/z-ai.yml"]` for the omp overlay), `--custom-env`.
- **Still wrapper-only**: per-task settings from issue labels
  (effort/model/provider/path), ambient>LWD-priority layering, loud-fail
  validation. No native equivalent. If those matter, wrap omp via a custom
  runtime profile (protocol family pi) pointing at the repo's `pi` wrapper
  with LWD_PI_VARIANT=omp.
