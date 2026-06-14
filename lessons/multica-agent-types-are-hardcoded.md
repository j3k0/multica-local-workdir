# multica agent types are a compiled-in enum (as of CLI v0.3.16)

You CANNOT add a new agent/provider to multica with a wrapper script alone. The
set of agent types is hardcoded in the Go binary
(`/opt/homebrew/Cellar/multica/<ver>/bin/multica`). Verified via `strings`:

> `unknown agent type: %q (supported: claude, codex, copilot, opencode, openclaw, hermes, gemini, pi, cursor, kimi, kiro, antigravity)`

Each type has a fixed override env var `MULTICA_<TYPE>_PATH` (confirmed present:
ANTIGRAVITY, CLAUDE, CODEX, COPILOT, CURSOR, GEMINI, HERMES, KIMI, KIRO,
OPENCLAW, OPENCODE, PI) and some have `MULTICA_<TYPE>_MODEL` (CLAUDE, CODEX,
CURSOR, GEMINI, HERMES, OPENCODE). The `multica-daemon` wrapper only exports
CLAUDE/OPENCODE/PI; the others exist in the binary but aren't wired here.

Consequence for adding a genuinely new agent CLI as its own top-level provider:
not possible without forking. Exporting a `MULTICA_FOO_PATH` for a name not in
the enum does nothing — multica never dispatches to it. The only no-fork path is
to ride an existing slot (point `MULTICA_OPENCODE_PATH` / `OPENCODE_BIN` at the
alt binary) and make that binary satisfy multica's `opencode` integration
contract:
- non-interactive `run` subprocess that emits the stdout JSON multica parses
  (`agent_error.empty_or_unparseable_output` on mismatch),
- a parseable `version` string (`cannot parse detected %s version`),
- honors opencode's config surface: `--dir`, `OPENCODE_CONFIG` schema with the
  `instructions` array, and `mcp_config` injection.

Forking the binary is impractical: it's a closed Homebrew Go build, and the
Desktop app auto-updates/supervises its own daemon (see
`multica-desktop-daemon-supervisor.md`), so a patched binary gets clobbered.

NB: "OpenCode Go" (the `opencode-go` claude-provider) is unrelated to the above
— it's not an agent type but a backend for the `claude` wrapper. See
`opencode-go-claude-provider.md`.
