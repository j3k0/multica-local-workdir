#!/usr/bin/env python3
"""Multica Desktop daemon "health responder" decoy.

Stands up a tiny HTTP server on the exact port the Multica Desktop app polls
for its own bundled daemon, answering with a health payload that makes Desktop
believe a matching daemon is already running. Desktop therefore never starts
(or restarts) its own daemon, and never touches the daemon you launched with
your own environment.

How Desktop decides (reverse-engineered from Multica.app/.../app.asar):

  fetchHealth():
    - polls http://127.0.0.1:<port>/health  (5s interval)
    - <port> = 19514 + 1 + sum(utf-8 bytes of profile name) % 1000
    - profile name = "desktop-" + URL(apiUrl).host (":"->"-", lowercased)
    - apiUrl is read from ~/.multica/desktop.json
    - the daemon counts as "running" only if  status == "running"  AND
      (server_url absent  OR  server_url URL-matches Desktop's target apiUrl)

  decideVersionAction():
    - if cli_version is empty/absent           -> "ok"      (no restart)
    - if cli_version == bundled CLI version    -> "ok"      (no restart)
    - else (and no active tasks)               -> "restart"
    - bundled version = `<bundled multica> version --output json` -> .version
      (verbatim, e.g. "v0.3.15")

  startDaemon():
    - no-ops if the port already answers status=="running"
      -> so this decoy blocks BOTH auto-start and the manual Start button.

This responder reads the bundled version with a short TTL cache, so when the
Desktop app updates and ships a new CLI, the reported version follows along
automatically (no restart needed) -> the decoy survives app updates.

Pure standard library. Python 3.7+.  Binds 127.0.0.1 only.
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HOME = os.path.expanduser("~")
DEFAULT_HEALTH_PORT = 19514  # mirrors DEFAULT_HEALTH_PORT in the Desktop app
DESKTOP_JSON = os.path.join(HOME, ".multica", "desktop.json")
DEFAULT_API_URL = "https://api.multica.ai"  # Desktop's DEFAULT_RUNTIME_CONFIG.apiUrl

# Where electron-builder unpacks the bundled Go binary inside the .app.
BUNDLED_BIN = (
    "/Applications/Multica.app/Contents/Resources/"
    "app.asar.unpacked/resources/bin/multica"
)


# --------------------------------------------------------------------------
# Config resolution (mirrors the Desktop app's own logic)
# --------------------------------------------------------------------------
def find_bundled_bin(explicit=None):
    """Locate the multica binary bundled inside Multica.app."""
    candidates = []
    if explicit:
        candidates.append(explicit)
    candidates.append(BUNDLED_BIN)
    # Fallback: glob in case Apple/electron tweak the path in a future build.
    import glob
    candidates += sorted(
        glob.glob("/Applications/Multica.app/Contents/Resources/**/bin/multica",
                  recursive=True)
    )
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def read_desktop_api_url():
    """apiUrl from ~/.multica/desktop.json — what Desktop derives its profile from."""
    try:
        with open(DESKTOP_JSON, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        url = data.get("apiUrl")
        if isinstance(url, str) and url.strip():
            return url.strip()
    except Exception:
        pass
    return DEFAULT_API_URL


def derive_profile_name(api_url):
    """desktop-${new URL(apiUrl).host.replace(/:/g,"-").toLowerCase()}"""
    try:
        host = urlparse(api_url).netloc  # host[:port]
        if not host:
            raise ValueError("no host")
        return "desktop-" + host.replace(":", "-").lower()
    except Exception:
        return "desktop"


def health_port_for_profile(profile):
    """19514 + 1 + sum(utf-8 bytes) % 1000  — verified against app.asar."""
    if not profile:
        return DEFAULT_HEALTH_PORT
    total = sum(profile.encode("utf-8"))
    return DEFAULT_HEALTH_PORT + 1 + (total % 1000)


# --------------------------------------------------------------------------
# Bundled-version probe, cached with a TTL so we track app updates live
# --------------------------------------------------------------------------
class VersionCache:
    def __init__(self, binary, ttl=30.0, static=None):
        self.binary = binary
        self.ttl = ttl
        self.static = static  # if set, never probe; always return this
        self._value = static
        self._stamp = 0.0
        self._lock = threading.Lock()

    def get(self):
        if self.static is not None:
            return self.static
        now = time.monotonic()
        with self._lock:
            if self._value is not None and (now - self._stamp) < self.ttl:
                return self._value
            value = self._probe()
            if value is not None:
                self._value = value
                self._stamp = now
            return self._value

    def _probe(self):
        if not self.binary:
            return self._value
        try:
            out = subprocess.run(
                [self.binary, "version", "--output", "json"],
                capture_output=True, text=True, timeout=5,
            )
            parsed = json.loads(out.stdout)
            v = parsed.get("version")
            if isinstance(v, str) and v:
                return v  # verbatim, e.g. "v0.3.15"
        except Exception as exc:
            sys.stderr.write("[responder] version probe failed: %s\n" % exc)
        return self._value


# --------------------------------------------------------------------------
# HTTP handler
# --------------------------------------------------------------------------
def make_handler(cfg, version_cache):
    start_time = time.time()
    daemon_id = str(uuid.uuid4())
    device_name = socket.gethostname()

    def fmt_uptime(seconds):
        s = int(seconds)
        h, s = divmod(s, 3600)
        m, s = divmod(s, 60)
        return "%dh%dm%ds" % (h, m, s)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _send_json(self, payload, code=200):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.split("?")[0] != "/health":
                self._send_json({"error": "not found"}, code=404)
                return

            payload = {
                "status": "running",
                "pid": os.getpid(),
                "uptime": fmt_uptime(time.time() - start_time),
                "daemon_id": daemon_id,
                "device_name": device_name,
                "active_task_count": 0,
                "agents": cfg["agents"],
                "workspaces": [],
            }
            cli_version = version_cache.get()
            if cli_version:
                payload["cli_version"] = cli_version
            if cfg["server_url"]:
                payload["server_url"] = cfg["server_url"]
            self._send_json(payload)

        # Silence default per-request stderr logging.
        def log_message(self, *args):
            pass

    return Handler


# --------------------------------------------------------------------------
# Wiring
# --------------------------------------------------------------------------
def resolve_config(args):
    binary = find_bundled_bin(args.bin)
    api_url = args.server_url if args.server_url is not None else read_desktop_api_url()
    profile = args.profile or derive_profile_name(api_url)
    port = args.port if args.port is not None else health_port_for_profile(profile)
    server_url = None if args.no_server_url else api_url
    agents = [a.strip() for a in args.agents.split(",") if a.strip()]
    return {
        "binary": binary,
        "api_url": api_url,
        "profile": profile,
        "port": port,
        "server_url": server_url,
        "agents": agents,
    }


def main():
    ap = argparse.ArgumentParser(description="Multica Desktop daemon health-responder decoy")
    ap.add_argument("--port", type=int, default=None,
                    help="override the health port (default: computed from profile)")
    ap.add_argument("--profile", default=None,
                    help="override the Desktop profile name (default: derived from desktop.json apiUrl)")
    ap.add_argument("--server-url", default=None,
                    help="server_url to report / target apiUrl (default: ~/.multica/desktop.json apiUrl)")
    ap.add_argument("--no-server-url", action="store_true",
                    help="omit server_url from the payload (bypasses Desktop's URL-match check entirely)")
    ap.add_argument("--cli-version", default=None,
                    help="hardcode cli_version instead of probing the bundled binary")
    ap.add_argument("--bin", default=None,
                    help="path to the bundled multica binary (default: auto-detect in Multica.app)")
    ap.add_argument("--version-ttl", type=float, default=30.0,
                    help="seconds to cache the probed bundled version (default: 30)")
    ap.add_argument("--agents", default="claude,opencode,gemini,pi",
                    help="comma-separated agent list to report (cosmetic; default: claude,opencode,gemini,pi)")
    ap.add_argument("--print-config", action="store_true",
                    help="resolve and print the config, then exit (dry run)")
    args = ap.parse_args()

    cfg = resolve_config(args)
    version_cache = VersionCache(cfg["binary"], ttl=args.version_ttl, static=args.cli_version)
    resolved_version = version_cache.get()

    if args.print_config:
        print(json.dumps({
            "bundled_binary": cfg["binary"],
            "bundled_version": resolved_version,
            "desktop_api_url": cfg["api_url"],
            "profile_name": cfg["profile"],
            "health_port": cfg["port"],
            "server_url_reported": cfg["server_url"],
            "agents": cfg["agents"],
        }, indent=2))
        return 0

    handler = make_handler(cfg, version_cache)
    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", cfg["port"]), handler)
    except OSError as exc:
        sys.stderr.write(
            "[responder] could not bind 127.0.0.1:%d (%s).\n"
            "            Something is already listening there — perhaps the real\n"
            "            Desktop daemon, or another copy of this responder.\n"
            % (cfg["port"], exc))
        return 1

    sys.stderr.write(
        "[responder] listening on http://127.0.0.1:%d/health\n"
        "[responder] profile=%s  cli_version=%s  server_url=%s\n"
        % (cfg["port"], cfg["profile"], resolved_version, cfg["server_url"]))
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("[responder] shutting down\n")
        httpd.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
