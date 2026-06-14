# Multica Desktop daemon health-responder

A tiny Python decoy that makes the **Multica Desktop** macOS app believe its
bundled daemon is already running — so it never starts (or restarts) its own,
and never takes over the daemon you launched yourself with your carefully set
environment variables.

## The problem

You run your own `multica daemon` (here, under the profile `lwd`) with a
specific environment — provider overrides, model selection, the wrapper scripts
in this repo, etc. When the Multica Desktop app is open it **supervises a daemon
of its own** and will start/restart it, which clobbers your setup.

Desktop's daemon supervisor (reverse-engineered from
`/Applications/Multica.app/Contents/Resources/app.asar`) works like this:

1. It derives a **profile name** from the API URL in `~/.multica/desktop.json`:

   ```
   profile = "desktop-" + new URL(apiUrl).host.replace(/:/g, "-").toLowerCase()
   ```

   For `apiUrl = http://kanban408.fovea.cc` → `desktop-kanban408.fovea.cc`.

2. It computes a **health port** from that name:

   ```
   port = 19514 + 1 + (sum of UTF-8 byte values of the profile name) % 1000
   ```

   For `desktop-kanban408.fovea.cc` → **19916**.
   (Verified empirically: your own `lwd` daemon lands on the formula's predicted
   port 19842.)

3. Every **5 seconds** it polls `http://127.0.0.1:<port>/health` and decides:

   - **Not running** if the port refuses the connection, or the body's
     `status` isn't `"running"`, or a present `server_url` doesn't URL-match
     Desktop's target API URL → Desktop will start its own daemon.
   - **Version mismatch** → if the running `cli_version` is non-empty and
     differs from Desktop's **bundled** CLI version, it restarts the daemon
     (deferring while tasks are active). Bundled version = the verbatim
     `version` field from `<bundled multica> version --output json` (e.g.
     `v0.3.15`).
   - Crucially, `startDaemon()` is a **no-op when the port already answers
     `status:"running"`** — so a convincing decoy blocks both auto-start and the
     manual *Start* button.

## The solution

Run a small HTTP server on **exactly that port** that returns:

```json
{ "status": "running", "cli_version": "v0.3.15", "server_url": "http://kanban408.fovea.cc", ... }
```

Desktop sees a healthy daemon whose version matches its bundle, and leaves
everything alone. Your real daemon (different profile → different port) keeps
doing the actual work, untouched.

Two details make this robust:

- **`cli_version` is read live from the bundled binary** (30 s TTL cache), not
  hardcoded. When Desktop updates and ships a new CLI, the decoy automatically
  reports the new version — **it survives app updates** with no edits.
- **`server_url` is read from `~/.multica/desktop.json`**, the same source
  Desktop derives its target from, so the URL-match check passes. (If a future
  Desktop normalizes URLs differently and the match ever fails, run with
  `--no-server-url` to drop the field — Desktop then skips the URL check
  entirely.)

The app binary is **never modified** — this only listens on a port the app
politely asks about.

## Files

| File | Purpose |
| --- | --- |
| `responder.py` | The decoy HTTP server. Pure stdlib, Python 3.7+. Self-configures from `Multica.app` + `~/.multica/desktop.json`. |
| `start.sh` / `stop.sh` | Run it in the background now (no login persistence). |
| `status.sh` | Print the resolved config and probe the live port — shows exactly what Desktop sees. |
| `install-launchd.sh` / `uninstall-launchd.sh` | Install/remove a per-user launchd agent (start at login, restart on crash). |
| `com.multica.health-responder.plist.template` | launchd template the installer fills in. |

## Usage

Inspect what it will do (dry run, changes nothing):

```bash
./status.sh                 # or: python3 responder.py --print-config
```

Run it now in the background:

```bash
./start.sh                  # extra args pass through, e.g. ./start.sh --no-server-url
./stop.sh
```

Persist across logins and app/laptop restarts (recommended):

```bash
./install-launchd.sh        # writes ~/Library/LaunchAgents/com.multica.health-responder.plist and loads it
./uninstall-launchd.sh      # fully reverses it
```

Verify the decoy is convincing Desktop:

```bash
./status.sh                 # "Live probe" block is the exact body Desktop reads
```

## Reversibility

- Started with `start.sh` → `./stop.sh`.
- Installed via launchd → `./uninstall-launchd.sh` (unloads + deletes the plist).

Nothing else on the system is changed — no app files, no `~/.multica` config.

## Overrides (`responder.py`)

All auto-detected; override only if your setup differs.

| Flag | Default |
| --- | --- |
| `--port N` | computed from the profile name |
| `--profile NAME` | derived from `desktop.json` `apiUrl` |
| `--server-url URL` | `apiUrl` from `~/.multica/desktop.json` |
| `--no-server-url` | (off) omit `server_url`, bypassing Desktop's URL-match check |
| `--cli-version V` | live-probed from the bundled binary |
| `--bin PATH` | auto-detected inside `Multica.app` |
| `--version-ttl S` | `30` — how long to cache the probed version |
| `--print-config` | resolve config and exit |

## Caveats

- **One responder per Desktop API target.** If you point Desktop at a different
  server (`desktop.json` `apiUrl` changes), the profile name and port change;
  restart the responder so it recomputes (launchd restart, or `stop`/`start`).
- **Concurrency:** if your real Desktop daemon is *already* listening on the
  computed port, the responder won't be able to bind it (and you don't need the
  decoy in that case). `status.sh` / the bind error will tell you.
- The decoy reports zero workspaces/tasks. Desktop's *UI* may therefore show an
  idle daemon; that's cosmetic — the goal is only to stop Desktop from
  spawning/restarting a daemon. Your own daemon continues to serve real work on
  its own port.
