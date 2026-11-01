"""The work root moves from ~/iso to ~/.iso (here ISOVIM_OLD_WORK and ISOVIM_WORK, both in the check's
tmp dir), as isovim.migrate's move_work does on the first iso command or TUI start that finds one.

A world made under the old root: a router in acme/app with a real worktree (aN/w, off a base clone)
holding uncommitted work and a file surface in its Inbox, a general/ chat agent, and a terminal, all
running, Claude's sessions kept as Claude Code keeps them (by the path the agent runs in,
FAKE_ACP_CLAUDE_KEYED). Then the new code, the general agent mid-turn: the move is deferred, and the
old root stays the work root (iso ls, iso status and the TUI see every agent there); an iso command
inside an agent leaves the move to an `iso __migrate` of its own. Once the agent is idle the move
happens: the old root is gone and every agent is at the same address under the new one, the chat
agents restarted there and resumed on their sessions (Claude's transcripts copied to the project
dirs for their new paths), the terminal still the same process, the worktree repaired (git status
works in aN/w, the base clone's git worktree list names the new path, and the edit guard lets the
agent edit and commit there), paths in records and surfaces moved, and the TUI on the new root.
Last, an old _/ (made by the isovim from before general/ and root/, $PSEUDO_OLD_REV, default
68cd736) under the old root, and the new root there already with a file and no agents: one iso
command merges the old root into it (the file kept) and moves _/ on to root/ and general/, both
agents resumed.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/work_move.py"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

BIN = str(REPO / "bin" / "iso")
OLD_REV = os.environ.get("PSEUDO_OLD_REV", "68cd736")
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


def git(*args, cwd=None, check=True):
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=check)
    return result.stdout.strip() if check else result


def listed(rows):
    """Whether sidebar rows show the router (by its role), its README surface and gen (not just the
    general header)."""
    return all(any(re.search(pattern, row) for row in rows) for pattern in (r"\brouter\b", r"\bREADME\b", r"\bgen\b"))


def claude_key(path):
    return "".join(c if c.isalnum() else "-" for c in str(Path(path).resolve()))


class World:
    """One pilot: its old and new work roots, the env before the new code (work in the old root,
    no old root to move) and after it (ISOVIM_OLD_WORK and ISOVIM_WORK)."""

    def __init__(self, name):
        self.iso = Iso(name, agent_delay=0.2)
        self.tmp = self.iso.tmp
        self.old_root = self.tmp / "iso"
        self.new_root = self.tmp / ".iso"
        self.home = self.tmp / "home"
        (self.tmp / "claude").mkdir()
        self.plain = self.tmp / "plain"
        self.plain.mkdir()
        self.iso.env.update(ISOVIM_SELF="pilothost", CLAUDE_CONFIG_DIR=str(self.tmp / "claude"), FAKE_ACP_CLAUDE_KEYED="1",
                            ISOVIM_WORK=str(self.old_root))
        self.after = {**self.iso.env, "ISOVIM_WORK": str(self.new_root), "ISOVIM_OLD_WORK": str(self.old_root)}

    def new_code(self):
        """From here on, the new env, for the TUI and for every agent the tmux server starts."""
        self.iso.env.clear()
        self.iso.env.update(self.after)
        for name in ("ISOVIM_WORK", "ISOVIM_OLD_WORK"):
            self.tmux("set-environment", "-g", name, self.after[name])

    def run(self, *args, env=None, bin=BIN, timeout=120):
        r = subprocess.run([bin, *args], env={**self.iso.env, **(env or {})}, capture_output=True, text=True, timeout=timeout,
                           cwd=self.plain)
        return r.returncode, r.stdout.strip(), r.stderr.strip()

    def tmux(self, *args):
        return subprocess.run(["tmux", "-L", self.iso.env["ISOVIM_TMUX_SOCKET"], *args], capture_output=True, text=True).stdout

    def sessions(self):
        return self.tmux("list-sessions", "-F", "#{session_name}").split()

    def pane_pid(self, session):
        out = self.tmux("list-panes", "-t", "=" + session, "-F", "#{pane_pid}").strip()
        return int(out) if out.isdigit() else None

    def root_of(self, address):
        """The root an agent's record is under now."""
        key = address.rsplit("/", 1)[0]
        for root in (self.new_root, self.old_root):
            if (root / key / "iso" / "agents" / (address.rsplit("/", 1)[1] + ".json")).exists():
                return root
        return self.new_root

    def journal(self, address):
        key, agent = address.rsplit("/", 1)
        path = self.root_of(address) / key / "iso" / "journal" / f"{agent}.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def chunks(self, address):
        return [e["update"]["content"].get("text", "") for e in self.journal(address)
                if e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk"]

    def reply(self, address, text, prefixes, timeout=60, env=None):
        """The agent's first new reply starting with one of prefixes, or what went wrong (so the
        checks on it fail, and the rest still run)."""
        prefixes = (prefixes,) if isinstance(prefixes, str) else prefixes
        before = len(self.chunks(address))
        rc, _, err = self.run("send", address, text, env=env)
        if rc != 0:
            return f"(iso send failed: {err})"
        try:
            return self.iso.wait(lambda: next((c for c in self.chunks(address)[before:] if c.startswith(prefixes)), None),
                                 f"{address}'s reply to {text!r}", timeout)
        except AssertionError as error:
            return f"(no reply: {str(error)[:300]})"

    def record(self, address):
        key, agent = address.rsplit("/", 1)
        path = self.root_of(address) / key / "iso" / "agents" / f"{agent}.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def state(self, address):
        key, agent = address.rsplit("/", 1)
        path = self.home / "run" / key.replace("/", "+") / f"{agent}.state"
        return path.read_text().strip() if path.exists() else None

    def idle(self, *addresses):
        return all(self.state(a) in ("idle", "ready") for a in addresses)

    def log(self):
        path = self.home / "migrate.log"
        return path.read_text() if path.exists() else ""

    def ls(self):
        rc, out, err = self.run("ls", "--json")
        return [row.get("id") for row in json.loads(out or "[]")] if rc == 0 else []

    def resumed_from(self, session):
        """The cwds the fake adapter was asked to resume (or load) session in."""
        path = Path(self.iso.env["FAKE_ACP_LOG"])
        frames = [json.loads(line)["frame"] for line in path.read_text().splitlines() if '"frame"' in line] if path.exists() else []
        return [str(Path(f["params"]["cwd"]).resolve()) for f in frames
                if f.get("method") in ("session/resume", "session/load") and f.get("params", {}).get("sessionId") == session]


print("# a world under the old root")
w = World("work_move")
iso = w.iso
try:
    remote = w.tmp / "remotes" / "acme" / "app.git"
    remote.mkdir(parents=True)
    git("init", "-q", "--bare", "-b", "main", str(remote))
    app = w.tmp / "src" / "app"
    git("clone", "-q", str(remote), str(app))
    git("checkout", "-qb", "main", cwd=app)
    (app / "README").write_text("app\n")
    git("add", "-A", cwd=app)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "first", cwd=app)
    git("push", "-q", "-u", "origin", "main", cwd=app)
    git("remote", "set-head", "origin", "main", cwd=app)
    base = Path(iso.cli("repo", "base", "acme/app", "--from", str(app)))

    rc, router, err = w.run("spawn", "--repo", str(app), "--role", "router", "--name", "r")
    check(rc == 0 and router == "acme/app/a0", "a router in acme/app", (rc, router, err))
    rc, gen, err = w.run("spawn", "--repo", "general", "--name", "gen")
    check(rc == 0 and gen == "general/a0", "a chat agent in general/", (rc, gen, err))
    rc, term, err = w.run("agent", "general", "terminal", "--v2", "--name", "term")
    check(rc == 0 and term == "general/a1", "a terminal", (rc, term, err))
    iso.wait(lambda: w.idle(router, gen), "both chat agents ready", 60)

    old_w = w.old_root / "acme" / "app" / "a0" / "w"
    made = w.reply(router, f"run {BIN} router wt > {w.tmp}/wt.out 2>&1", "ran:", 120)
    check((old_w / ".git").is_file(), "the router made its worktree, aN/w", (made, (w.tmp / "wt.out").read_text()))
    (old_w / "wip.txt").write_text("uncommitted\n")
    shown = w.reply(router, f"run {BIN} router surface file {old_w / 'README'} > {w.tmp}/surface.out 2>&1", "ran:")
    surface = w.old_root / "acme" / "app" / "iso" / "README.surface"
    check(surface.exists() and str(old_w) in surface.read_text(), "and showed a file in it in its Inbox",
          (shown, (w.tmp / "surface.out").read_text(), list((w.old_root / "acme" / "app" / "iso").iterdir())))
    w.reply(router, "first words to the router", "reply to:")
    w.reply(gen, "first words to gen", "reply to:")
    iso.wait(lambda: w.idle(router, gen), "both idle", 30)
    sessions = {a: w.record(a).get("session") for a in (router, gen)}
    check(all(sessions.values()), "both have sessions in their records", sessions)
    for a, sid in sessions.items():
        key, agent = a.rsplit("/", 1)
        kept = w.tmp / "claude" / "projects" / claude_key(w.old_root / key / agent) / f"{sid}.jsonl"
        check(kept.exists(), f"{a}'s session is kept under its old path's Claude project", kept)
    pids = {name: w.pane_pid(name) for name in ("iso2-acme+app+a0", "iso2-general+a0", "iso2-general+a1")}
    check(all(pids.values()), "all three run", (pids, w.sessions()))

    print("\n# the new code, while gen is mid-turn: deferred, and the old root still the work root")
    rc, _, err = w.run("send", gen, "slow 30")
    iso.wait(lambda: w.state(gen) == "working", "gen working", 20)
    w.new_code()
    rc, out, err = w.run("ls")
    check(rc == 0 and w.old_root.is_dir() and not w.new_root.exists(), "iso ls leaves the old root where it is", (rc, err))
    check("deferred: general/a0 is working" in w.log(), "the move is deferred on gen", w.log()[-800:])
    ids = w.ls()
    check({router, gen, term} <= set(ids), "iso ls lists every agent in the old root", (ids, err))
    for a in (router, gen, term):
        rc, out, err = w.run("status", a)
        check(rc == 0, f"iso status {a}", (rc, out, err))
    iso.start()
    check(iso.lua("return require('isovim.store').work") == str(w.old_root), "the TUI's start defers it too, on the old root",
          iso.lua("return require('isovim.store').work"))
    try:
        iso.wait(lambda: listed(iso.sidebar()),
                 "the sidebar lists them", 20)
        check(True, "the TUI's sidebar lists the agents")
    except AssertionError as error:
        check(False, "the TUI's sidebar lists the agents", str(error)[:600])

    # An iso command inside an agent (its hook, say) doesn't move anything itself: the agent's
    # stop would end it partway. It starts `iso __migrate` apart from it, which defers too.
    lines = len(w.log().splitlines())
    started = time.time()
    rc, out, err = w.run("status", router, env={"ISOVIM_ADDR": router})
    check(rc == 0 and time.time() - started < 10, "iso status inside an agent returns at once", (rc, out, err))
    check("started the move apart from acme/app/a0" in w.log(), "and leaves the move to iso __migrate", w.log()[-600:])
    try:
        iso.wait(lambda: "deferred: general/a0" in "\n".join(w.log().splitlines()[lines:]), "iso __migrate deferring", 20)
        check(True, "which defers too, gen still mid-turn")
    except AssertionError as error:
        check(False, "which defers too, gen still mid-turn", str(error)[:300])

    print("\n# once gen is idle: an agent's iso command moves it, through iso __migrate")
    iso.wait(lambda: w.idle(gen), "gen idle", 60)
    time.sleep(10)  # past the 10s between starts of iso __migrate
    rc, out, err = w.run("status", gen, env={"ISOVIM_ADDR": router})
    check(rc == 0, "iso status inside an agent", (rc, err))
    try:
        iso.wait(lambda: "done: the work root is " + str(w.new_root) in w.log(), "the move", 90)
        check(True, "the move is done")
    except AssertionError as error:
        check(False, "the move is done", (str(error)[:300], w.log()[-2000:]))
    check(not w.old_root.exists() and w.new_root.is_dir(), "the old root is gone, the new one there", list(w.tmp.iterdir()))
    for a in (router, gen, term):
        key, agent = a.rsplit("/", 1)
        check((w.new_root / key / "iso" / "agents" / f"{agent}.json").exists() and (w.new_root / key / agent).is_dir(),
              f"{a}'s record and dir are under the new root")
    ids = w.ls()
    check({router, gen, term} <= set(ids), "iso ls lists every agent, at the same addresses", ids)
    try:
        iso.wait(lambda: all(w.pane_pid(n) and w.pane_pid(n) != pids[n] for n in ("iso2-acme+app+a0", "iso2-general+a0")),
                 "both chat agents restarted", 30)
        check(True, "both chat agents were restarted")
    except AssertionError as error:
        check(False, "both chat agents were restarted", (str(error)[:300], w.sessions()))
    check(w.pane_pid("iso2-general+a1") == pids["iso2-general+a1"], "the terminal kept running, the same process",
          (pids, w.pane_pid("iso2-general+a1")))
    iso.wait(lambda: w.idle(router, gen), "both ready again", 60)
    env = w.tmux("show-environment", "-t", "=iso2-acme+app+a0")
    meta = str(w.new_root / "acme" / "app" / "iso" / "agents" / "a0.json")
    check(f"ISOVIM_META={meta}" in env.splitlines(), "the router runs with its record under the new root", env)

    print("\n# resumed on their sessions")
    for a, words in ((router, "first words to the router"), (gen, "first words to gen")):
        said = w.reply(a, "history", "history:")
        check(words in said, f"{a} remembers its conversation", said)
        key, agent = a.rsplit("/", 1)
        new_dir = str((w.new_root / key / agent).resolve())
        check(new_dir in w.resumed_from(sessions[a]), f"{a} resumed its session from {key}/{agent} under the new root",
              w.resumed_from(sessions[a]))
        copied = w.tmp / "claude" / "projects" / claude_key(new_dir) / f"{sessions[a]}.jsonl"
        check(copied.exists(), f"{a}'s Claude transcript is under the new path's project", copied)
    check(w.record(router).get("session") == sessions[router], "the router's record keeps its session", w.record(router))

    print("\n# the worktree")
    new_w = w.new_root / "acme" / "app" / "a0" / "w"
    status = git("-C", str(new_w), "status", "--porcelain", check=False)
    check(status.returncode == 0 and "wip.txt" in status.stdout, "git status works in aN/w, the uncommitted work there",
          (status.returncode, status.stdout, status.stderr))
    worktrees = git("worktree", "list", "--porcelain", cwd=base)
    check(f"worktree {new_w.resolve()}" in worktrees and str(old_w) not in worktrees, "the base clone's git worktree list names the new path",
          worktrees)
    landed = w.reply(router, f"write {new_w / 'after.txt'} x", ("blocked:", "write:"))
    check(landed.startswith("write:") and (new_w / "after.txt").exists() and (new_w / "after.txt").read_text() == "x", "the edit guard lets it edit its w/ there", landed)
    own = w.reply(router, f"bash cd {new_w} && git add -A && git -c user.name=t -c user.email=t@t commit -qm moved",
                  ("blocked:", "bash:"))
    check(own.startswith("bash:") and "(exit 0)" in own and git("-C", str(new_w), "log", "-1", "--format=%s", check=False).stdout.strip() == "moved",
          "and commit there", own)
    refused = w.reply(router, f"write {app / 'nope.txt'} x", ("blocked:", "write:"))
    check(refused.startswith("blocked:") and str(new_w / "nope.txt") in refused, "the user's clone is still refused, naming w/ there",
          refused)

    print("\n# paths kept")
    surface = w.new_root / "acme" / "app" / "iso" / "README.surface"
    data = json.loads(surface.read_text()) if surface.exists() else {}
    check(data.get("path") == str(new_w / "README"), "the file surface points into the new root", data)
    check(not any(str(w.old_root) + "/" in p.read_text() for p in (w.new_root / "acme" / "app" / "iso" / "agents").glob("*.json")),
          "no record names the old root")

    print("\n# the TUI follows")
    try:
        iso.wait(lambda: iso.lua("return require('isovim.store').work") == str(w.new_root), "the TUI on the new root", 40)
        check(True, "the TUI's work root is the new one")
    except AssertionError as error:
        check(False, "the TUI's work root is the new one", str(error)[:300])
    iso.lua("require('isovim.sidebar').refresh()")
    try:
        iso.wait(lambda: listed(iso.sidebar()), "gen in the sidebar", 20)
        check(True, "and its sidebar lists them")
    except AssertionError as error:
        check(False, "and its sidebar lists them", str(error)[:600])
    rc, out, err = w.run("ls")
    check(not w.old_root.exists(), "a later iso command leaves it be", (rc, err))
finally:
    iso.stop()


print("\n# an old _/ under the old root")
w = World("work_move_old")
iso = w.iso
OLD = w.tmp / "old-isovim"
try:
    OLD.mkdir()
    archive = subprocess.run(["git", "-C", os.environ.get("PSEUDO_GIT_DIR", str(REPO)), "archive", OLD_REV], capture_output=True, check=True)
    subprocess.run(["tar", "-x", "-C", str(OLD)], input=archive.stdout, check=True)
    old_bin = str(OLD / "bin" / "iso")
    rc, out, err = w.run("rootmode", "on", "host", bin=old_bin)
    check(rc == 0 and "_/a0" in out, "the old isovim puts the host root at _/a0", (rc, out, err))
    rc, worker, err = w.run("spawn", "--name", "worker1", bin=old_bin)
    check(rc == 0 and worker == "_/a1", "and a worker at _/a1", (rc, worker, err))
    iso.wait(lambda: w.idle("_/a0", "_/a1"), "both ready", 60)
    w.run("send", "_/a1", "first words to the worker", bin=old_bin)
    iso.wait(lambda: w.idle("_/a1") and any(e["kind"] == "update" for e in w.journal("_/a1")), "the worker answered", 30)
    session = w.record("_/a1").get("session")
    check((w.old_root / "_" / "a1").is_dir() and session, "_/ is under the old root", (session, list(w.old_root.iterdir())))

    # The new root is there already, with a file and no agents (written early to where a skill
    # says an agent's dir is): it isn't the work root yet, and the move merges into it.
    early = w.new_root / "root" / "notes.md"
    early.parent.mkdir(parents=True)
    early.write_text("early\n")
    w.new_code()
    rc, out, err = w.run("ls")
    check(rc == 0 and not w.old_root.exists() and not (w.new_root / "_").exists(), "one iso command moves the old root and _/",
          (rc, err, w.log()[-1500:]))
    check(early.exists() and early.read_text() == "early\n", "merged into the new root that was there, its file kept",
          w.log()[-1500:])
    for address in ("root/a0", "general/a1"):
        key, agent = address.split("/")
        check((w.new_root / key / "iso" / "agents" / f"{agent}.json").exists() and (w.new_root / key / agent).is_dir(),
              f"{address} is under the new root")
    try:
        iso.wait(lambda: {"iso2-root+a0", "iso2-general+a1"} <= set(w.sessions()), "both under their new names", 30)
        iso.wait(lambda: w.idle("root/a0", "general/a1"), "both ready again", 60)
        check(True, "both run at their new addresses")
    except AssertionError as error:
        check(False, "both run at their new addresses", (str(error)[:300], w.sessions()))
    said = w.reply("general/a1", "history", "history:")
    check("first words to the worker" in said, "the worker remembers its conversation", said)
    new_dir = str((w.new_root / "general" / "a1").resolve())
    check(new_dir in w.resumed_from(session), "it resumed from general/a1 under the new root", w.resumed_from(session))
    rc, out, err = w.run("root")
    check(rc == 0 and out == "pilothost:root/a0", "iso root names root/a0", (rc, out, err))
finally:
    iso.stop()

print("\nfailures:", len(fails))
sys.exit(1 if fails else 0)
