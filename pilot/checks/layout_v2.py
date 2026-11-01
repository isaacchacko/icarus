"""The new layout, opt-in (iso agent --v2): an agent in a repo is <owner>/<repo>/aN, with its own dir
~/iso/<owner>/<repo>/aN/, its record in ~/iso/<owner>/<repo>/iso/agents/aN.json and a tmux session
iso2-<owner>+<repo>+aN; one outside any repo is _/aN under ~/iso/_/. aN numbers come from a per-repo
counter and are never given out twice, even after the agent and the counter file go. The sidebar,
iso ls and --json list them beside legacy workspaces; a restart resumes the conversation by session
id (from the run dir, or the record when the run dir lost it); iso msg parent from a child reaches its
spawner with a stamp the receiver's hook verifies; rm deletes the record and hands children to the
grandparent; iso-hook's desktop notice reads either record shape; a read-only agent starts in the
repo's base clone; a legacy workspace works as before.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/layout_v2.py"""

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

ISO = str(REPO / "bin" / "iso")


def git(*args):
    subprocess.run(["git", *args], check=True, capture_output=True)


def tmux(iso, *args):
    return subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], *args], capture_output=True, text=True)


def sessions(iso):
    return tmux(iso, "list-sessions", "-F", "#{session_name}").stdout.split()


def screen(iso, session):
    return tmux(iso, "capture-pane", "-p", "-J", "-t", f"={session}:").stdout


def rows(iso):
    return {row["id"]: row for row in json.loads(iso.cli("ls", "--json"))}


iso = Iso("layout_v2")
iso.env["ISOVIM_SELF"] = "pilothost"
try:
    iso.start()
    work = iso.tmp / "work"
    app = iso.tmp / "src" / "app"
    app.mkdir(parents=True)
    git("init", "-q", str(app))
    git("-C", str(app), "remote", "add", "origin", "git@github.com:Acme/app.git")
    plain = iso.tmp / "plain"
    plain.mkdir()
    unit = work / "acme" / "app"
    records = unit / "iso" / "agents"

    # A legacy workspace in the same repo, untouched by any of it.
    legacy = iso.cli("new", "legacy", "--dir", str(app))
    assert len(legacy) == 6, legacy
    iso.cli("open", f"{legacy}/main")
    iso.wait(lambda: rows(iso)[f"{legacy}/main"]["status"] != "stopped", "legacy agent running")

    # Spawned by the user, from the repo's dir: acme/app/a0.
    boss = iso.cli("agent", str(app), "claude", "--v2", "--name", "boss")
    assert boss == "acme/app/a0", boss
    assert (unit / "a0").is_dir()
    record = json.loads((records / "a0.json").read_text())
    for key, value in {"id": "a0", "name": "boss", "kind": "claude", "role": "worker", "read_only": False, "repo": "acme/app"}.items():
        assert record[key] == value, (key, record)
    assert "parent" not in record and isinstance(record["created"], int), record
    assert "iso2-acme+app+a0" in sessions(iso), sessions(iso)
    assert (unit / "iso" / "next").read_text().strip() == "1"
    iso.wait(lambda: rows(iso)[boss]["status"] == "idle", "a0 ready")
    env = tmux(iso, "show-environment", "-t", "=iso2-acme+app+a0").stdout
    for line in ("ISOVIM_WS=acme/app", "ISOVIM_AGENT=boss", "ISOVIM_ADDR=acme/app/a0", f"ISOVIM_META={records / 'a0.json'}"):
        assert line in env.splitlines(), (line, env)
    assert f"ISOVIM_STATE={iso.tmp / 'home' / 'run' / 'acme+app' / 'a0.state'}" in env.splitlines(), env

    # a0 spawns a child from inside its pane (the repo named as a key); it is a0's child.
    iso.cli("send", boss, f"run {ISO} agent acme/app claude --v2 --name kid")
    iso.wait(lambda: (records / "a1.json").exists(), "a1 spawned by a0")
    kid = "acme/app/a1"
    iso.wait(lambda: rows(iso).get(kid, {}).get("status") == "idle", "a1 ready")
    assert rows(iso)[kid]["parent"] == boss, rows(iso)[kid]
    assert (unit / "a1").is_dir()

    # The sidebar lists the repo's agents (in the legacy grouping, under a row for the key).
    iso.wait(lambda: any("acme/app" in row for row in iso.sidebar()), "repo row in the sidebar")
    iso.lua("require('isovim').expanded['acme/app'] = true; require('isovim.sidebar').refresh()")
    iso.wait(lambda: any("boss" in row for row in iso.sidebar()) and any("kid" in row for row in iso.sidebar()), "agents in the sidebar")
    iso.wait(lambda: any("legacy" in row for row in iso.sidebar()), "legacy row in the sidebar")
    # Opened in the TUI: its chat shows, and the selection's layout is kept in the repo's iso/.
    iso.cli("open", boss)
    iso.wait(lambda: iso.lua("return vim.b.isovim_id") == "acme/app" and iso.lua("return vim.b.isovim_agent") == "a0", "a0's chat open")
    iso.wait(lambda: "fake agent ready" in "\n".join(iso.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")), "a0's chat drawn")
    iso.wait(lambda: (unit / "iso" / "layout.json").exists(), "layout.json in iso/")
    iso.screenshot("sidebar")

    # iso msg parent from the child reaches the spawner, stamped, and a0's hook verifies the stamp.
    iso.cli("send", kid, f"run {ISO} msg parent hello-from-kid")
    iso.wait(lambda: "hello-from-kid" in screen(iso, "iso2-acme+app+a0"), "message at a0")
    a0_screen = iso.wait(lambda: (s := screen(iso, "iso2-acme+app+a0")) and "isovim verified" in s and s, "stamp verified")
    assert "[from pilothost:acme/app/a1 · m" in a0_screen, a0_screen

    # Addresses: a repo key alone means its first agent; a host prefix naming this host is here.
    assert iso.cli("status", "acme/app") == iso.cli("status", boss)
    assert iso.cli("status", "pilothost:acme/app/a1") == iso.cli("status", kid)

    # A restart resumes its conversation by session id: from the run dir, else from the record.
    claude_dir = iso.tmp / "claude"
    (claude_dir / "projects" / "-x").mkdir(parents=True)
    (claude_dir / "projects" / "-x" / "s-boss.jsonl").write_text("{}\n")
    session_file = iso.tmp / "home" / "run" / "acme+app" / "a0.session"
    session_file.write_text("s-boss\n")
    command = """
      local store, panes = require('isovim.store'), require('isovim.panes')
      local saved = vim.env.ISOVIM_AGENT_CMD
      vim.env.ISOVIM_AGENT_CMD, vim.env.CLAUDE_CONFIG_DIR = nil, ...
      local cmd = panes.agent_cmd('acme/app', store.agent('acme/app', select(2, ...)), '/tmp')
      vim.env.ISOVIM_AGENT_CMD, vim.env.CLAUDE_CONFIG_DIR = saved, nil
      return table.concat(cmd, ' ')
    """
    assert "--resume s-boss" in iso.lua(command, str(claude_dir), "a0")
    session_file.unlink()
    record = json.loads((records / "a0.json").read_text())
    record["session"] = "s-boss"
    (records / "a0.json").write_text(json.dumps(record))
    assert "--resume s-boss" in iso.lua(command, str(claude_dir), "a0")
    # A fresh one is given an id, kept in its run dir and its record.
    fresh = iso.lua(command, str(claude_dir), "a1")
    kid_session = json.loads((records / "a1.json").read_text())["session"]
    assert f"--session-id {kid_session}" in fresh, fresh
    assert (iso.tmp / "home" / "run" / "acme+app" / "a1.session").read_text().strip() == kid_session
    iso.cli("restart", boss)
    iso.wait(lambda: rows(iso)[boss]["status"] == "idle" and "iso2-acme+app+a0" in sessions(iso), "a0 back after restart")

    # rm deletes the record (its children go to its parent); numbers are never given out again.
    grandkid = iso.cli("agent", "acme/app", "terminal", "--v2", "--parent", kid)
    assert grandkid == "acme/app/a2", grandkid
    assert rows(iso)[grandkid]["parent"] == kid
    iso.cli("rm", kid)
    assert not (records / "a1.json").exists()
    assert "iso2-acme+app+a1" not in sessions(iso)
    assert kid not in rows(iso)
    assert rows(iso)[grandkid]["parent"] == boss, rows(iso)[grandkid]
    assert iso.cli("agent", "acme/app", "terminal", "--v2") == "acme/app/a3"
    iso.cli("rm", boss)
    assert not (records / "a0.json").exists()
    assert rows(iso)[grandkid].get("parent") is None, rows(iso)[grandkid]
    (unit / "iso" / "next").unlink()
    # Without --v2 too, as the repo key already has agents.
    assert iso.cli("agent", "acme/app", "terminal") == "acme/app/a4"
    assert not (records / "a0.json").exists() and not (records / "a1.json").exists()

    # Outside any repo: _/aN under ~/iso/_/.
    loose = iso.cli("agent", str(plain), "terminal", "--v2", "--name", "loose")
    assert loose == "_/a0", loose
    assert (work / "_" / "a0").is_dir() and (work / "_" / "iso" / "agents" / "a0.json").exists()
    assert "iso2-_+a0" in sessions(iso)
    assert iso.cli("agent", "_", "terminal", "--v2") == "_/a1"
    # Spawned at once, each takes its own number.
    racing = [subprocess.Popen([ISO, "agent", "_", "terminal", "--v2", "--hidden"], env=iso.env, stdout=subprocess.PIPE, text=True) for _ in range(4)]
    taken = sorted(p.communicate()[0].strip() for p in racing)
    assert taken == ["_/a2", "_/a3", "_/a4", "_/a5"], taken

    # A read-only one starts in the repo's base clone, when there is one.
    base = iso.tmp / "home" / "repos" / "acme" / "app" / "base-clone"
    base.mkdir(parents=True)
    reader = iso.cli("agent", "acme/app", "terminal", "--v2", "--read-only")
    listed = rows(iso)
    assert listed[reader]["dir"] == str(base) and listed[reader]["read_only"] is True, listed[reader]
    assert "ISOVIM_READONLY=1" in tmux(iso, "show-environment", "-t", f"=iso2-acme+app+{reader.split('/')[-1]}").stdout

    # iso ls: every agent, legacy and new, by address; --json carries where each works and its repo.
    text = iso.cli("ls")
    for address in (f"{legacy}/main", grandkid, "acme/app/a3", "_/a0", "_/a1"):
        assert address in text, (address, text)
        assert address in listed, address
    assert listed["acme/app/a3"]["dir"] == str(unit / "a3"), listed["acme/app/a3"]
    assert listed["acme/app/a3"]["repo"]["name"] == "acme/app", listed["acme/app/a3"]
    assert listed["_/a0"]["workspace"] == "_" and listed["_/a0"]["agent"] == "loose"
    assert listed[f"{legacy}/main"]["dir"] == str(app) and listed[f"{legacy}/main"]["status"] != "stopped"

    # A repo key isn't a workspace: no archive, no move, no project dir.
    for args in (["archive", "acme/app"], ["move", "acme/app", "elsewhere", "--force"], ["dir", "acme/app", str(plain)]):
        assert subprocess.run([ISO, *args], env=iso.env, capture_output=True).returncode != 0, args
    assert (records / "a3.json").exists() and (unit / "iso").is_dir() and "iso2-acme+app+a3" in sessions(iso)
    assert rows(iso)[grandkid].get("parent") is None and rows(iso)["acme/app/a3"]["status"] != "stopped"

    # iso-hook names the agent in its desktop notice from either shape of $ISOVIM_META.
    state = iso.tmp / "state"
    state.write_text("")
    for meta, ws, expected in ((records / "a3.json", "acme/app", "acme/app · a3 needs you"),
                               (iso.tmp / "home" / "workspaces" / legacy / ".isovim.json", legacy, "legacy · main needs you")):
        hook_env = {**iso.env, "ISOVIM_META": str(meta), "ISOVIM_WS": ws, "ISOVIM_SOCK": str(iso.tmp / "none"),
                    "ISOVIM_STATE": str(iso.tmp / ("a3.state" if ws == "acme/app" else "main.state"))}
        subprocess.run([str(REPO / "bin" / "iso-hook"), "ask"], env=hook_env, check=True)
        assert expected in iso.desktop_notifications(), (expected, iso.desktop_notifications())

    # The legacy workspace still answers.
    iso.cli("send", f"{legacy}/main", "still here")
    iso.wait(lambda: "reply to: still here" in screen(iso, f"isovim-{legacy}-main"), "legacy reply")
    print("layout_v2: ok")
finally:
    iso.stop()
