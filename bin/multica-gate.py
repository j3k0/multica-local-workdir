#!/usr/bin/env python3
"""multica-gate.py — handoff policy behind bin/multica (FOV-2094 step 3, FOV-2097).

bin/multica execs this for AGENT runs (LWD_AGENT_RUN=1) on mutating issue
commands. Advisory only (decided on FOV-2097: no server-side enforcement):
it catches mistakes, it is not a security boundary.

Env:
  MULTICA_REAL_BIN   real multica CLI (required)
  LWD_GATE_MODE      warn (default) | enforce
  LWD_GATE_LOG       decision log (best effort)
  LWD_GATE_FORBIDDEN agents that may not be dispatched
                     (default Integrity,Librarian,IAPDAPM,LODAPM,TRIGAPM)
  MULTICA_AGENT_ID / MULTICA_AGENT_NAME / MULTICA_WORKSPACE_ID  the running agent

Two kinds of input:
  - New flags (--next, --next-human, --waiting-on, --no-next-actor,
    --progress) are unknown to the real CLI, so they are always translated:
    the flow runs when well-formed, the command is refused (exit 3) if not —
    in both modes. On gated commands argv may also be normalised
    (--flag=value -> --flag value) and shim flags stripped; everything not
    overloaded passes through untouched.
  - Plain commands that break policy: warn mode prints advice and lets the
    raw command through; enforce mode refuses (exit 3).
"""

import json
import os
import re
import shlex
import subprocess
import sys
import time

REFUSE = 3
GLOBAL_VALUE_FLAGS = {"--workspace-id", "--profile", "--server-url", "--output"}
NEW_VALUE_FLAGS = {"--next", "--next-human", "--waiting-on"}
NEW_BARE_FLAGS = {"--no-next-actor", "--progress"}
# value-taking flags of the gated subcommands (so values are never positionals)
CMD_VALUE_FLAGS = GLOBAL_VALUE_FLAGS | NEW_VALUE_FLAGS | {
    "--content", "--content-file", "--parent", "--attachment", "--duplicate-of",
    "--status", "--assignee", "--assignee-id", "--to", "--to-id", "--title",
    "--description", "--description-file", "--priority", "--stage", "--project",
    "--due-date", "--key", "--value", "--type",
}
FINISHED = {"in_review", "done", "released", "cancelled"}
CLOSED = {"done", "released", "cancelled"}
MENTION_RE = re.compile(r"mention://agent/([0-9a-fA-F-]{36})")
NO_NEXT_LINE = "No next actor."

REAL = os.environ.get("MULTICA_REAL_BIN") or "multica"
MODE = os.environ.get("LWD_GATE_MODE") or "warn"
LOG = os.environ.get("LWD_GATE_LOG", "")
SELF_ID = os.environ.get("MULTICA_AGENT_ID", "")
SELF_NAME = os.environ.get("MULTICA_AGENT_NAME", "")
FORBIDDEN = {n.strip().lower() for n in os.environ.get(
    "LWD_GATE_FORBIDDEN", "Integrity,Librarian,IAPDAPM,LODAPM,TRIGAPM").split(",") if n.strip()}
# Agents allowed to set `done` (e.g. Secretary closing on JC's recorded approve,
# FOV-2064a). `secretary` is the one default member (decided on FOV-2097a: the
# Secretary's close on JC's recorded `approve` must keep working in enforce
# mode); every allowlisted close is logged.
DONE_AGENTS = {n.strip().lower() for n in os.environ.get(
    "LWD_GATE_DONE_AGENTS", "secretary").split(",") if n.strip()}

DONE_MSG = "closing is a human's call; use: multica issue comment add <id> --next-human <human-name>"


SIDE_FAILED = 4  # comment posted, but a handoff side step failed (see stderr)


class Refused(Exception):
    pass


CONSUMED_STDIN = {}


def say(msg):
    print(f"bin/multica: gate ({MODE}): {msg}", file=sys.stderr)


def log(decision, argv):
    if not LOG:
        return
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        body = " ".join(shlex.quote(a) for a in argv).replace("\n", "\\n")[:2000]
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}|gate|{MODE}|{decision}|{body}\n")
    except OSError:
        pass


def refuse(msg):
    raise Refused(msg)


def violation(msg, argv, stdin_text=None):
    """Policy breach on a plain command: warn+pass in warn mode, refuse in enforce."""
    if MODE == "enforce":
        refuse(msg)
    say(f"WARNING (enforce mode would refuse): {msg}")
    log("warn", argv)
    sys.exit(run(argv, stdin_text))


def run(argv, stdin_text=None):
    """Call the real CLI, inheriting stdio. When the gate has consumed stdin
    (a --content-stdin body), it is re-fed verbatim."""
    if stdin_text is not None:
        return subprocess.run([REAL] + argv, input=stdin_text, text=True).returncode
    return subprocess.run([REAL] + argv).returncode


def side(argv):
    """Quiet side step (assign/status/metadata); reports failure, never stops."""
    p = subprocess.run([REAL] + argv, capture_output=True, text=True)
    if p.returncode != 0:
        say(f"handoff side step failed: multica {' '.join(argv)}")
        if p.stderr:
            say(p.stderr.strip()[:500])
    return p.returncode


# ------------------------------------------------------------------ lookups --
def agents(refresh=False):
    """{id: name}, cached per workspace for 6h; None when the list can't be read."""
    d = os.environ.get("LWD_GATE_CACHE_DIR") or os.path.expanduser("~/.cache/multica-gate")
    cache = os.path.join(d, f"agents-{os.environ.get('MULTICA_WORKSPACE_ID', 'default')}.json")
    if not refresh:
        try:
            if time.time() - os.path.getmtime(cache) < 21600:
                with open(cache) as f:
                    return json.load(f)
        except (OSError, ValueError):
            pass
    try:
        p = subprocess.run([REAL, "agent", "list", "--output", "json"],
                           capture_output=True, text=True, timeout=60)
        m = {a["id"]: a["name"] for a in json.loads(p.stdout) if a.get("id") and a.get("name")}
    except Exception as e:
        say(f"could not list agents ({type(e).__name__})")
        log("agent-list-failed", ["agent", "list"])
        return None
    try:
        os.makedirs(d, exist_ok=True)
        with open(cache, "w") as f:
            json.dump(m, f)
    except OSError:
        pass
    return m


def resolve_agent(name, required=True):
    """(id, name) for an agent name or id, else (None, None). Refreshes once on
    a miss. A failed agent list refuses when `required` (no id, no mention),
    otherwise reads as "not an agent" (fail-open)."""
    for refresh in (False, True):
        m = agents(refresh)
        if m is None:
            if required:
                refuse("could not list agents, so the next actor can't be resolved; retry")
            return None, None
        if name in m:
            return name, m[name]
        for aid, n in m.items():
            if n.lower() == name.lower():
                return aid, n
    return None, None


def issue(issue_id):
    """Issue JSON or None — fail-open: unreadable data skips checks that need it."""
    try:
        p = subprocess.run([REAL, "issue", "get", issue_id, "--output", "json"],
                           capture_output=True, text=True, timeout=60)
        return json.loads(p.stdout)
    except Exception:
        say(f"could not read issue {issue_id}; skipping checks that need it")
        return None


# ------------------------------------------------------------------ parsing --
def positionals(argv):
    toks, skip = [], False
    for a in argv:
        if skip:
            skip = False
        elif a in CMD_VALUE_FLAGS:
            skip = True
        elif not a.startswith("-"):
            toks.append(a)
    return toks


def take_new_flags(argv):
    """Strip the new flags from argv. Returns (rest, found) with found mapping
    flag -> list of values (bare flags -> [True])."""
    rest, found, i = [], {}, 0
    while i < len(argv):
        a = argv[i]
        if a in NEW_VALUE_FLAGS:
            if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                refuse(f"{a} needs a value")
            found.setdefault(a, []).append(argv[i + 1])
            i += 2
            continue
        if a in NEW_BARE_FLAGS:
            found.setdefault(a, []).append(True)
        else:
            rest.append(a)
        i += 1
    return rest, found


def flag_value(argv, flag):
    for k, a in enumerate(argv):
        if a == flag and k + 1 < len(argv):
            return argv[k + 1]
    return None


def drop_flag(argv, flag, has_value):
    out, skip = [], False
    for a in argv:
        if skip:
            skip = False
        elif a == flag:
            skip = has_value
        else:
            out.append(a)
    return out


# -------------------------------------------------------------- comment add --
def read_body(argv, stdin_text):
    """(source, body). source: content|file|stdin|None. The stdin body is
    passed in already consumed."""
    if "--content-stdin" in argv or stdin_text is not None:
        return "stdin", (stdin_text if stdin_text is not None else "")
    path = flag_value(argv, "--content-file")
    if path is not None:
        try:
            with open(path, encoding="utf-8") as f:
                return "file", f.read()
        except OSError as e:
            refuse(f"cannot read --content-file {path}: {e}")
    c = flag_value(argv, "--content")
    if c is not None:
        return "content", c
    return None, ""


def deliver(argv, src, body):
    """(argv, stdin_text) that posts `body`. Inline --content values are
    patched in place (the CLI decodes \n escapes there); anything else is
    piped via --content-stdin. `src`/`body` may come from read_body."""
    if src == "content":
        out = list(argv)
        k = out.index("--content")
        if k + 1 < len(out):
            out[k + 1] = body
        else:
            out.append(body)
        return out, None
    out = drop_flag(drop_flag(argv, "--content-file", True), "--content-stdin", False)
    out = drop_flag(out, "--allow-external-file", False)
    out.append("--content-stdin")
    return out, body


def find_add_tail(argv):
    """Issue id of `issue comment add` (first positional after `add`), or None."""
    for k in range(1, len(argv)):
        if argv[k] == "add" and argv[k - 1] == "comment":
            i, skip_global = k + 1, False
            while i < len(argv):
                a = argv[i]
                if skip_global:
                    skip_global = False
                elif a in GLOBAL_VALUE_FLAGS:
                    skip_global = True
                elif a.startswith("-"):
                    pass
                else:
                    return a
                i += 1
            return None
    return None


def warn_loop(issue_id, aid, aname):
    """Advisory only: handing straight back to the agent who wrote the latest
    comment is a paid loop unless the comment carries new information — which
    we cannot judge, so we never refit, just note it. The inbox's catch-up
    pass is the safety net for runs that end undeclared."""
    try:
        p = subprocess.run([REAL, "issue", "comment", "list", issue_id, "--roots-only",
                            "--summary", "--compact", "--output", "json"],
                           capture_output=True, text=True, timeout=60)
        cs = [c for c in json.loads(p.stdout or "[]") if c.get("author_id") != SELF_ID]
    except Exception:
        return
    if cs and max(cs, key=lambda c: c.get("created_at", "")).get("author_id") == aid:
        say(f"note: {aname} wrote the latest comment; handing straight back is a "
            "paid loop unless your comment carries new information")


def comment_add(argv, toks):
    issue_id = find_add_tail(argv)
    if issue_id is None:
        sys.exit(run(argv))  # usage error is the real CLI's business
    stdin_text = sys.stdin.read() if "--content-stdin" in argv else None
    if stdin_text is not None:
        CONSUMED_STDIN["text"] = stdin_text  # for the fail-open path in main()
    argv, nf = take_new_flags(argv)
    src, body = read_body(argv, stdin_text)
    mentions = set(MENTION_RE.findall(body))
    self_forbidden = SELF_NAME.lower() in FORBIDDEN
    amap = agents() or {}
    named = {m: amap.get(m, "").lower() for m in mentions}

    if not nf:
        # Plain comment: the body itself declares the next actor.
        if set(named.values()) & FORBIDDEN:
            violation("forbidden-to-dispatch agent(s) mentioned: " +
                      ", ".join(sorted({amap[m] for m in mentions
                                        if amap.get(m, "").lower() in FORBIDDEN})), argv, stdin_text)
        elif mentions and self_forbidden:
            violation(f"{SELF_NAME} may not dispatch agents; drop the agent mention", argv, stdin_text)
        elif len(mentions) > 1:
            violation("more than one next actor (several agent mentions); one handoff, one actor", argv, stdin_text)
        elif not mentions and NO_NEXT_LINE not in body:
            violation("every comment must name its next actor: add --next <agent>, "
                      "--next-human <name>, --no-next-actor (finished work), "
                      "or --progress for a mid-run note", argv, stdin_text)
        log("pass", argv)
        sys.exit(run(argv, stdin_text))

    if mentions and set(named.values()) & FORBIDDEN:
        refuse("forbidden-to-dispatch agent(s) mentioned: " +
               ", ".join(sorted({amap[m] for m in mentions
                                 if amap.get(m, "").lower() in FORBIDDEN})))
    kinds = [k for k in ("--next", "--next-human", "--no-next-actor", "--progress") if k in nf]
    if len(kinds) > 1 or len(nf.get("--next", [])) + len(nf.get("--next-human", [])) > 1:
        refuse("exactly one next actor: one of --next / --next-human / --no-next-actor / --progress")
    if "--waiting-on" in nf and not nf.get("--next-human"):
        refuse('--waiting-on goes with --next-human (or: multica issue status <id> blocked --waiting-on "...")')
    if not kinds:
        refuse("--waiting-on alone declares no next actor; add --next-human <name>")
    kind = kinds[0]

    if kind == "--progress":
        if mentions:
            refuse("--progress is a mid-run note and must mention nobody (a mention dispatches a run)")
        log("progress", argv)
        sys.exit(run(argv, stdin_text))

    if kind == "--no-next-actor":
        if mentions:
            refuse("--no-next-actor contradicts the agent mention in the body")
        iss = issue(issue_id)
        if iss and iss.get("status") not in FINISHED:
            refuse(f"--no-next-actor needs the issue in {'/'.join(sorted(FINISHED))} "
                   f"(it is {iss.get('status')}); finished work goes to a human: --next-human <name>")
        body = (body or "").rstrip("\n")
        # --content values get the CLI's \n escape decoded; other bodies are verbatim
        nl = "\\n" if src == "content" else "\n"
        body = f"{body}{nl}{NO_NEXT_LINE}" if body else NO_NEXT_LINE
        out, stdin = deliver(argv, src or "stdin", body)
        log("no-next-actor", out)
        sys.exit(run(out, stdin))

    if kind == "--next-human":
        human = nf["--next-human"][0]
        if resolve_agent(human, required=False)[0]:
            refuse(f"'{human}' is an agent; use --next {human}")
        if mentions:
            refuse("a --next-human handoff must not mention agents (that dispatches a run)")
        iss = issue(issue_id)
        refuse_if_closed(iss)
        rc = run(argv, stdin_text)
        log(f"next-human rc={rc}", argv)
        if rc != 0:
            say("HANDOFF DID NOT LAND: the comment was not posted; assignee and status unchanged")
            sys.exit(rc)
        if side(["issue", "assign", issue_id, "--to", human, "--no-start"]) != 0:
            say(f"HANDOFF INCOMPLETE: the comment IS POSTED; do not re-run it. But assigning '{human}' "
                f"failed, so the status was NOT changed. Fix: multica issue assign {issue_id} --to "
                f"<exact human name> --no-start, then the status")
            log("next-human assign-failed", argv)
            sys.exit(SIDE_FAILED)
        if "--waiting-on" in nf:
            ok_ = side(["issue", "metadata", "set", issue_id, "--key", "waiting_on",
                        "--value", nf["--waiting-on"][0], "--type", "string"]) == 0
            ok_ = side(["issue", "status", issue_id, "blocked", "--no-start"]) == 0 and ok_
        else:
            ok_ = clear_waiting(issue_id, iss)
            ok_ = side(["issue", "status", issue_id, "in_review", "--no-start"]) == 0 and ok_
        if not ok_:
            say("HANDOFF INCOMPLETE: the comment IS POSTED; do not re-run it. The human is assigned, "
                "but a status/metadata step failed (above) — carry that side step out by hand")
            sys.exit(SIDE_FAILED)
        sys.exit(0)

    # --next <agent>
    name = nf["--next"][0]
    if self_forbidden:
        refuse(f"{SELF_NAME} may not dispatch agents; use --next-human or --no-next-actor")
    aid, aname = resolve_agent(name)
    if not aid:
        refuse(f"unknown agent '{name}' (see: multica agent list)")
    if aname.lower() in FORBIDDEN:
        refuse(f"'{name}' is a forbidden-to-dispatch agent ({', '.join(sorted(FORBIDDEN))})")
    if aid == SELF_ID:
        refuse("--next names yourself; keep working, or hand off to someone else")
    others = mentions - {aid}
    if others:
        refuse(f"never mention an agent other than the next actor (found {', '.join(sorted(others))})")
    iss = issue(issue_id)
    refuse_if_closed(iss)
    warn_loop(issue_id, aid, aname)
    if aid not in mentions:
        link = f"[@{aname}](mention://agent/{aid})"
        body = f"{link} {body}" if src == "content" else (f"{link}\n{body}" if body else link)
        argv, stdin_text = deliver(argv, src or "stdin", body)
    # Ownership and status first, so the run the mention starts sees them
    # (assign --no-start + mention = exactly one run). Status only moves once
    # ownership did; a failed post rolls both back.
    prev_assignee = iss.get("assignee_id") if iss else None
    prev_status = iss.get("status") if iss else None
    prev_waiting = waiting_of(iss)
    assigned = moved = cleared = False
    owned = iss is not None and prev_assignee == aid
    if not owned:
        owned = assigned = side(["issue", "assign", issue_id, "--to-id", aid, "--no-start"]) == 0
        if not owned:
            say(f"COMMENT IS POSTED; do not re-run it: the ownership side step failed, so ownership stays "
                f"with the previous assignee and status is unchanged. The mention still dispatches {aname}. "
                f"Fix after: multica issue assign {issue_id} --to-id {aid} --no-start")
    if owned:
        if iss is None or prev_status != "in_progress":
            moved = side(["issue", "status", issue_id, "in_progress", "--no-start"]) == 0
        cleared = prev_waiting is not None and clear_waiting(issue_id, iss)
    rc = run(argv, stdin_text)
    log(f"next rc={rc}", argv)
    if rc != 0:
        if iss is None:
            # Review nit (FOV-2097): with the issue unreadable there are no
            # previous assignee/status values to restore — say so instead of
            # promising a rollback that would never run.
            say("HANDOFF DID NOT LAND: the comment was not posted and nobody was dispatched "
                "(the issue was unreadable, so ownership was never changed — nothing to roll back)")
        else:
            say("HANDOFF DID NOT LAND: the comment was not posted and nobody was dispatched; rolling back")
            if assigned and iss is not None:
                side(["issue", "assign", issue_id, "--no-start"] +
                     (["--to-id", prev_assignee] if prev_assignee else ["--unassign"]))
            if moved and prev_status:
                side(["issue", "status", issue_id, prev_status, "--no-start"])
            if cleared:
                side(["issue", "metadata", "set", issue_id, "--key", "waiting_on",
                      "--value", str(prev_waiting), "--type", "string"])
        sys.exit(rc)
    sys.exit(0 if owned else SIDE_FAILED)


def waiting_of(iss):
    return ((iss or {}).get("metadata") or {}).get("waiting_on")


def clear_waiting(issue_id, iss):
    """A resumed or handed-off issue is no longer parked: drop a stale
    waiting_on (the inbox treats it as authoritative). True when cleared or
    nothing to clear; unknown issue data -> try, tolerating "not set"."""
    if iss is not None and waiting_of(iss) is None:
        return True
    p = subprocess.run([REAL, "issue", "metadata", "delete", issue_id, "--key", "waiting_on"],
                       capture_output=True, text=True)
    if p.returncode != 0 and iss is not None:
        say(f"could not clear waiting_on: {p.stderr.strip()[:300]}")
        return False
    return True


def refuse_if_closed(iss):
    if iss and iss.get("status") in CLOSED:
        refuse(f"the issue is {iss.get('status')}; a handoff would reopen it and (for --next) start a "
               "paid run. Reopen it explicitly first if that is really intended")


# ---------------------------------------------------------- status / update --
def status_problem(key, issue_id, has_waiting):
    """Policy problems for a target status; None when allowed."""
    if key == "done":
        if SELF_NAME.lower() in DONE_AGENTS:
            say(f"done allowed for {SELF_NAME} (LWD_GATE_DONE_AGENTS)")
            log("done-allowlisted", ["issue", "status", issue_id, "done", f"by={SELF_NAME}"])
            return None
        return DONE_MSG.replace("<id>", issue_id)
    if key == "blocked" and not has_waiting:
        return (f'blocked needs --waiting-on: multica issue status {issue_id} blocked '
                '--waiting-on "<what, until when>"')
    if key in ("todo", "in_review"):
        iss = issue(issue_id)
        if not iss:
            return None
        if key == "todo" and iss.get("assignee_id"):
            return ("todo on an assigned issue dispatches the assignee now, with no comment; to park it: "
                    f'multica issue status {issue_id} blocked --waiting-on "<what, until when>"')
        if key == "in_review" and iss.get("assignee_type") != "member":
            return (f"in_review needs a human assignee; use: "
                    f"multica issue comment add {issue_id} --next-human <name>")
    return None


def status(argv, toks):
    issue_id, key = toks[2], toks[3]
    argv, nf = take_new_flags(argv)
    if set(nf) - {"--waiting-on"}:
        refuse("--next/--next-human/--no-next-actor/--progress belong on: multica issue comment add")
    waiting = nf.get("--waiting-on", [None])[0]
    if waiting is not None and key != "blocked":
        refuse("--waiting-on only goes with blocked")
    prob = status_problem(key, issue_id, waiting is not None)
    if prob:
        violation(prob, argv)
    if waiting is not None:
        # consumed here so the raw CLI never sees the shim-level flag
        side(["issue", "metadata", "set", issue_id, "--key", "waiting_on",
              "--value", waiting, "--type", "string"])
    log("pass", argv)
    sys.exit(run(argv))


def update(argv, toks):
    issue_id = toks[2]
    argv, nf = take_new_flags(argv)
    if nf:
        refuse("the handoff flags belong on: multica issue comment add")
    if flag_value(argv, "--assignee") is not None or flag_value(argv, "--assignee-id") is not None:
        violation("assigning alone starts a run with no comment; hand off with a comment: "
                  f"multica issue comment add {issue_id} --next <agent> (or --next-human <name>)", argv)
    key = flag_value(argv, "--status")
    if key:
        prob = status_problem(key, issue_id, False)
        if prob:
            violation(prob, argv)
    log("pass", argv)
    sys.exit(run(argv))


def create(argv):
    argv, nf = take_new_flags(argv)
    if nf:
        refuse("the handoff flags belong on: multica issue comment add")
    key = flag_value(argv, "--status")
    probs = {
        "done": "closing is a human's call; create it open",
        "blocked": ("create --status blocked with an assignee queues a stray run (CLI 0.6.1); create it in "
                    'backlog, then: multica issue status <id> blocked --waiting-on "<what, until when>"'),
        "in_review": "create it, then hand off: multica issue comment add <id> --next-human <name>",
    }
    has_assignee = flag_value(argv, "--assignee") is not None or flag_value(argv, "--assignee-id") is not None
    if key in probs and (key != "blocked" or has_assignee):
        violation(probs[key], argv)
    log("pass", argv)
    sys.exit(run(argv))


def assign(argv, toks):
    if "--unassign" in argv or "--no-start" in argv:  # neither starts a run
        log("pass", argv)
        sys.exit(run(argv))
    issue_id = toks[2] if len(toks) > 2 else "<id>"
    violation("assigning alone starts a run with no comment; hand off with: "
              f"multica issue comment add {issue_id} --next <agent> (or --next-human <name>)", argv)


# --------------------------------------------------------------------- main --
def main():
    global MODE
    raw = sys.argv[1:]
    if MODE not in ("warn", "enforce"):
        say(f"unknown LWD_GATE_MODE '{MODE}'; using warn")
        MODE = "warn"
    if "-h" in raw or "--help" in raw:
        sys.exit(run(raw))
    # --flag=value -> --flag value for KNOWN flags in flag position only, so a
    # value that merely looks like one (--content "--output=json ...") survives.
    argv, skip = [], False
    for a in raw:
        if skip:
            argv.append(a)
            skip = False
        elif a.startswith("--") and "=" in a and a.split("=", 1)[0] in CMD_VALUE_FLAGS:
            argv.extend(a.split("=", 1))
        else:
            argv.append(a)
            skip = a in CMD_VALUE_FLAGS
    toks = positionals(argv)
    try:
        if len(toks) >= 4 and toks[:3] == ["issue", "comment", "add"]:
            comment_add(argv, toks)
        elif len(toks) >= 4 and toks[:2] == ["issue", "status"]:
            status(argv, toks)
        elif len(toks) >= 3 and toks[:2] == ["issue", "update"]:
            update(argv, toks)
        elif len(toks) >= 2 and toks[:2] == ["issue", "create"]:
            create(argv)
        elif len(toks) >= 2 and toks[:2] == ["issue", "assign"]:
            assign(argv, toks)
        else:
            sys.exit(run(raw))
    except Refused as e:
        say(f"REFUSED: {e}")
        log("refuse", raw)
        sys.exit(REFUSE)
    except Exception as e:  # fail-open: a gate bug must never block a run
        say(f"internal error ({type(e).__name__}: {e}); passing the raw command through")
        log("gate-error", raw)
        sys.exit(run(raw, CONSUMED_STDIN.get("text")))


if __name__ == "__main__":
    main()