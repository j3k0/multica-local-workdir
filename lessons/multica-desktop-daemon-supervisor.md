# Multica Desktop daemon supervisor (reverse-engineered, as of 2026-06-04)

Source: `/Applications/Multica.app/Contents/Resources/app.asar` (Desktop build
shipping CLI `v0.3.15`). Full working countermeasure: `health-responder/`.

The Desktop app supervises *its own* daemon and will start/restart it,
clobbering a hand-launched daemon. How it decides (functions in the asar):

- `deriveProfileName(apiUrl)` = `` `desktop-${new URL(apiUrl).host.replace(/:/g,"-").toLowerCase()}` ``.
  `apiUrl` comes from `~/.multica/desktop.json`.
- `healthPortForProfile(name)` = `19514 + 1 + (sum of UTF-8 bytes of name) % 1000`.
  Verified: the `lwd` profile lands on the predicted 19842.
- `fetchHealth()` polls `http://127.0.0.1:<port>/health` every 5s. Counts as
  running only if `status==="running"` AND (`server_url` absent OR it
  URL-matches Desktop's target apiUrl via `urlsMatch`/`normalizeUrl`).
- `decideVersionAction(bundled, running)`: `ok` if `running.cli_version` is
  empty OR `=== bundled`; else `restart` (deferred while `active_task_count>0`).
  `bundled` = verbatim `.version` from `<bundled multica> version --output json`
  (e.g. `"v0.3.15"`, WITH the `v`) — exact string compare.
- `startDaemon()` no-ops if the port already answers `status==="running"` — so a
  decoy on that port blocks auto-start AND the manual Start button.

Key gotchas:
- The running daemon's `/health` reports `cli_version` WITHOUT the `v`
  (`"0.3.13"`), but `getCliBinaryVersion()` returns it WITH the `v`
  (`"v0.3.15"`). Match whatever the bundled binary prints, not the running
  daemon's format.
- Read `cli_version` live from the bundled binary (TTL cache) so the decoy keeps
  matching after a Desktop update without edits.
- The user's own daemon and Desktop's daemon use *different* profile names →
  *different* ports, so a decoy on Desktop's port doesn't touch the real daemon.
