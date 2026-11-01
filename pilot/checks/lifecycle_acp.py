"""L6's spawn default, worktree on first edit and read-only agents, with pilot/fake-acp-agent as the
adapter (it runs the session's PreToolUse hooks from _meta as Claude Code does). iso spawn makes a
new-layout ACP agent by default: in the repo --repo names, in the clone the shell is in, or in
General outside one; an agent's iso worker spawn makes its child the same way; --legacy still makes
a workspace agent in claude's TUI; the sidebar's s makes one in the repo under the cursor (General
on its header). A new-layout agent's first edit in its repo makes its worktree, aN/w, and is
refused with where to make it, and its edit there then goes through; an edit outside the repo needs
no worktree; with w made, the base clone can't be edited. A --read-only agent runs in the repo's
base clone, fetched at its start, where its edits and mutating git commands are refused and reads
and other commands work.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/lifecycle_acp.py"""

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

BIN = str(REPO / "bin" / "iso")
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


def git(*args, cwd=None):
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True)
    return result.stdout.strip()


def commit(checkout, files, message):
    for name, text in files.items():
        path = checkout / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    git("add", "-A", cwd=checkout)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", message, cwd=checkout)


iso = Iso("lifecycle_acp", agent_delay=0.2)
iso.env["ISOVIM_SELF"] = "pilothost"


def run(*args, cwd=None, timeout=90):
    r = subprocess.run([BIN, *args], env=iso.env, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def tmux(*args):
    return subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], *args], capture_output=True, text=True).stdout


def unit_dir(key):
    return iso.tmp / "work" / Path(key)


def record(address):
    key, agent = address.rsplit("/", 1)
    path = unit_dir(key) / "iso" / "agents" / f"{agent}.json"
    return json.loads(path.read_text()) if path.exists() else None


def chunks(address):
    key, agent = address.rsplit("/", 1)
    path = unit_dir(key) / "iso" / "journal" / f"{agent}.jsonl"
    entries = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    return [e["update"]["content"].get("text", "") for e in entries
            if e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk"]


def reply(address, text, prefix, timeout=30):
    """Sends text to the agent and returns its first new reply starting with prefix."""
    before = len(chunks(address))
    rc, _, err = run("send", address, text)
    assert rc == 0, err
    return iso.wait(lambda: next((c for c in chunks(address)[before:] if c.startswith(prefix)), None),
                    f"{address}'s reply to {text!r}", timeout)


def pane_start(address):
    key, agent = address.rsplit("/", 1)
    for line in tmux("list-panes", "-a", "-F", "#{session_name}\t#{pane_start_command}\t#{pane_current_path}").splitlines():
        name, command, path = line.split("\t")
        if name == "iso2-" + key.replace("/", "+") + "+" + agent:
            return command, path
    return None, None


def lua(code, *args):
    return iso.lua(code, *args)


try:
    iso.start()
    remote = iso.tmp / "remotes" / "acme" / "app.git"
    remote.mkdir(parents=True)
    git("init", "-q", "--bare", "-b", "main", str(remote))
    app = iso.tmp / "src" / "app"
    git("clone", "-q", str(remote), str(app))
    git("checkout", "-qb", "main", cwd=app)
    commit(app, {"src/app.lua": "return 1\n"}, "first")
    git("push", "-q", "-u", "origin", "main", cwd=app)
    git("remote", "set-head", "origin", "main", cwd=app)
    plain = iso.tmp / "plain"
    plain.mkdir()
    base = iso.tmp / "home" / "repos" / "acme" / "app" / "base-clone"

    print("# spawn defaults to a new-layout ACP agent")
    rc, a0, err = run("spawn", "--repo", str(app), "--name", "alpha")
    rec = record(a0) if rc == 0 else None
    check(rc == 0 and a0 == "acme/app/a0" and rec and rec.get("acp") is True, "iso spawn --repo makes acme/app/a0, over ACP", (rc, a0, err, rec))
    command, path = pane_start(a0)
    check(command and "agent_host.lua" in command, "its pane runs the ACP supervisor", command)
    check(path and Path(path).resolve() == (unit_dir("acme/app") / "a0").resolve(), "it starts in aN/", path)
    rc, a1, err = run("spawn", "--name", "here", cwd=app / "src")
    check(rc == 0 and a1 == "acme/app/a1" and record(a1).get("checkout") == str(app.resolve()),
          "from a shell in the clone (a subdir), iso spawn picks its repo and the clone", (rc, a1, err, record(a1) if rc == 0 else None))
    rc, g0, err = run("spawn", "--name", "loose", cwd=plain)
    check(rc == 0 and g0 == "general/a0" and record(g0).get("acp") is True, "outside a repo, iso spawn goes to General (general/a0)", (rc, g0, err))
    rc, out, err = run("spawn", "--read-only", cwd=plain)
    check(rc == 1 and "read-only agent works in its repo's base clone" in err, "a read-only spawn in no repo is refused", (rc, out, err))

    print("\n# --legacy")
    rc, old, err = run("spawn", "--legacy", "--repo", str(app), "--name", "old")
    check(rc == 0 and old.endswith("/main") and not old.startswith("acme/app"), "--legacy makes a workspace's agent", (rc, old, err))
    ws = old.split("/")[0]
    spec = lua("return require('isovim.store').agent(..., 'main')", ws) if rc == 0 else None
    check(spec and not spec.get("acp") and lua("return require('isovim.store').dir(...)", ws) == str(app.resolve()),
          "in the repo's dir, not over ACP", spec)
    panes = tmux("list-panes", "-a", "-F", "#{pane_start_command}")
    check("fake-agent" in panes, "its pane runs claude's TUI (the fake agent)", panes)

    print("\n# an agent's iso worker spawn")
    kid_out = iso.tmp / "kid.txt"
    reply(a0, f"run {BIN} worker spawn --name kid kid task > {kid_out} 2>&1", "ran:", 120)
    kid = kid_out.read_text().strip()
    check(kid.startswith("acme/app/a") and kid not in (a0, a1) and record(kid).get("acp") is True and record(kid).get("parent") == a0,
          "an agent's spawn is a new-layout ACP agent in its repo, its child", (kid, record(kid) if kid.startswith("acme") else None))

    print("\n# worktree on first edit")
    w = unit_dir("acme/app") / "a0" / "w"
    first = reply(a0, f"write {unit_dir('acme/app') / 'a0' / 'src' / 'new.lua'} return 2", "blocked:")
    check("isovim made your worktree for your first edit" in first and str(w) in first and str(w / "src" / "new.lua") in first,
          "the first edit is refused, naming the worktree and the path to edit there", first)
    check((w / ".git").exists() and (w / "src" / "app.lua").exists(), "aN/w is made, a checkout of the repo", list(w.parent.iterdir()))
    check(not (unit_dir("acme/app") / "a0" / "src" / "new.lua").exists(), "the refused edit wasn't made")
    branch = git("branch", "--show-current", cwd=w)
    check(branch and record(a0).get("branch") == branch, "its branch is on the record", (branch, record(a0)))
    done = reply(a0, f"write {w / 'src' / 'new.lua'} return 2", "write:")
    check((w / "src" / "new.lua").read_text() == "return 2", "the edit made again under w/ goes through", done)
    check("src/new.lua" in git("status", "--porcelain", cwd=w), "and shows in the worktree's changes", git("status", "--porcelain", cwd=w))
    shared = reply(a0, f"write {base / 'src' / 'app.lua'} oops", "blocked:")
    check("base clone is shared" in shared and str(w / "src" / "app.lua") in shared and (base / "src" / "app.lua").read_text() == "return 1\n",
          "with w made, an edit in the base clone is refused", shared)
    notes = iso.tmp / "notes.txt"
    reply(a1, f"write {notes} jotted", "write:")
    check(notes.read_text() == "jotted" and not (unit_dir("acme/app") / "a1" / "w").exists(),
          "an edit outside the repo goes through and makes no worktree")
    reply(g0, f"write {plain / 'x.txt'} x", "write:")
    check((plain / "x.txt").exists(), "a General agent's edits go through")

    print("\n# read-only")
    commit(app, {"src/later.lua": "return 3\n"}, "second")
    git("push", "-q", "origin", "main", cwd=app)
    rc, ro, err = run("spawn", "--repo", str(app), "--read-only", "--name", "ro")
    check(rc == 0 and record(ro).get("read_only") is True and record(ro).get("acp") is True, "iso spawn --read-only records read_only", (rc, ro, err))
    command, path = pane_start(ro)
    check(path and Path(path).resolve() == base.resolve(), "it runs in the repo's base clone", path)
    check((base / "src" / "later.lua").exists() and git("rev-parse", "HEAD", cwd=base) == git("rev-parse", "HEAD", cwd=app),
          "fetched at its start: the base clone is at origin's latest", git("log", "--oneline", "-3", cwd=base))
    refused = reply(ro, f"write {base / 'src' / 'app.lua'} changed", "blocked:")
    check("read-only agent" in refused and (base / "src" / "app.lua").read_text() == "return 1\n", "its write tool is refused", refused)
    read = reply(ro, f"read {base / 'src' / 'app.lua'}", "read:")
    check(read == "read: return 1", "its read works", read)
    git_refused = reply(ro, "bash git commit --allow-empty -m nope", "blocked:")
    check("`git commit`" in git_refused and git("rev-parse", "HEAD", cwd=base) == git("rev-parse", "HEAD", cwd=app),
          "a mutating git command is refused", git_refused)
    status = reply(ro, "bash git -C . status --short", "bash:")
    check("(exit 0)" in status, "a git command that only reads runs", status)
    check(not (unit_dir("acme/app") / ro.rsplit("/", 1)[1] / "w").exists(), "a read-only agent gets no worktree")

    print("\n# the sidebar's s")
    iso.focus_sidebar()

    def header(name):
        rows = lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
        return next((i for i, row in enumerate(rows) if row.strip().endswith(name) or f" {name} " in row), None)

    def agents_of(key):
        return {p.stem for p in (unit_dir(key) / "iso" / "agents").glob("a*.json")}

    before = agents_of("acme/app")
    i = iso.wait(lambda: header("app"), "the acme/app header")
    lua("vim.api.nvim_win_set_cursor(0, {..., 0})", i + 1)
    iso.keys("s")
    new = iso.wait(lambda: agents_of("acme/app") - before, "s spawned in acme/app", 30)
    s_agent = "acme/app/" + new.pop()
    check(record(s_agent).get("acp") is True and record(s_agent).get("kind") == "claude", "s on the repo makes its next aN, over ACP", record(s_agent))
    # Its chat opens with the composer focused: look for the chat in any window.
    iso.wait(lambda: lua(
        "for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do local b = vim.api.nvim_win_get_buf(w)"
        " if vim.b[b].isovim_id == 'acme/app' and vim.b[b].isovim_agent == ... then return true end end return false",
        s_agent.rsplit("/", 1)[1]), "its chat opened", 30)
    check(True, "and its chat opens")
    iso.focus_sidebar()
    lua("vim.cmd.stopinsert()")
    before = agents_of("general")
    i = iso.wait(lambda: header("general"), "the general header")
    lua("vim.api.nvim_win_set_cursor(0, {..., 0})", i + 1)
    iso.keys("s")
    new = iso.wait(lambda: agents_of("general") - before, "s spawned in General", 30)
    check(record("general/" + new.pop()).get("acp") is True, "s on General makes general/aN, over ACP")
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
