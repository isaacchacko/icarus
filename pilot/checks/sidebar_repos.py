"""The sidebar grouped by repo, with the Inbox hierarchy: the host root pinned first as "root"; each
repo under a header in its glyph and color (two legacy workspaces of one repo and its new-layout
agents, an ACP one among them, under one header), its router and repo-root, then the workers that
aren't a worker's, each with the size of the team behind it; general last, shown (with a hint, s on
it spawning a general/aN) even when empty. Enter on a header opens
the router. The host Inbox holds the root's surfaces and a row per repo with something waiting
(Enter opens that repo's Inbox), a repo's Inbox its surfaces (one row format per type), the top
Inbox the other hosts' waiting surfaces (Enter shows that host); the root-mode marker sits beside a
count. ii, ih and iI land in those Inboxes. Collapsing persists through a hot reload, < and > step
to a fake peer whose list groups by the repo its `iso ls` names, and the style meter counts the
ACP agent. A screenshot goes to pilot/out/ and the session's scratchpad.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/sidebar_repos.py"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

SHOT = Path("/tmp/claude-1000/-home-isaac-Programs-isovim/57b9fd6b-ae1b-44e9-a60c-d740bf473977/scratchpad/sidebar-repos.png")

fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


def git(cwd, *args):
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True)


iso = Iso("sidebar_repos", cols=150, rows=48, agent_delay=0.3)
iso.env["ISOVIM_SELF"] = "here"
# A fake peer that answers iso ls --json and iso __surfaces.
remote_rows = [
    {"id": "acme/zeta/a0", "workspace": "acme/zeta", "agent": "zrouter", "kind": "claude", "role": "router",
     "status": "idle", "hidden": False, "repo": {"name": "acme/zeta", "glyph": "Z", "color": "#9ece6a"}},
    {"id": "acme/zeta/a1", "workspace": "acme/zeta", "agent": "zworker", "kind": "claude", "role": "worker",
     "status": "working", "hidden": False, "parent": "acme/zeta/a0", "repo": {"name": "acme/zeta", "glyph": "Z", "color": "#9ece6a"}},
    {"id": "abc123/main", "workspace": "scratch", "agent": "main", "kind": "claude", "role": "worker", "status": "idle", "hidden": False},
]
remote_surfaces = [
    {"repo": "acme/zeta", "name": "deploy", "type": "question", "title": "Deploy zeta?", "question": "Deploy zeta?",
     "options": [{"label": "yes"}, {"label": "no"}], "needs_you": True, "created": 1},
]
(iso.tmp / "remote.json").write_text(json.dumps(remote_rows))
(iso.tmp / "remote-surfaces.json").write_text(json.dumps(remote_surfaces))
(iso.tmp / "remote-iso").write_text(
    "#!/bin/sh\ncase \"$1\" in\n"
    f"  __surfaces) cat {iso.tmp / 'remote-surfaces.json'} ;;\n"
    f"  *) cat {iso.tmp / 'remote.json'} ;;\nesac\n"
)
os.chmod(iso.tmp / "remote-iso", 0o755)
(iso.tmp / "ssh-env").write_text("")
iso.env.update(
    ISOVIM_PEERS="other=other",
    ISOVIM_SSH=str(REPO / "pilot" / "fake-ssh"),
    ISOVIM_REMOTE_BIN=str(iso.tmp / "remote-iso"),
    FAKE_SSH_ENV=str(iso.tmp / "ssh-env"),
)

# Two repos, clones of bare origins acme/web and acme/api.
src = iso.tmp / "src"
for repo in ("web", "api"):
    origin = iso.tmp / "origins" / "acme" / f"{repo}.git"
    clone = src / repo
    clone.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
    git(clone, "init", "-q", "-b", "main")
    (clone / "README.md").write_text(f"{repo}\n")
    git(clone, "add", ".")
    git(clone, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init")
    git(clone, "remote", "add", "origin", str(origin))
    git(clone, "push", "-q", "origin", "main")


def lua(code, *args):
    return iso.lua(code, *args)


def rows():
    """The list's rows as the sidebar builds them: kind and the fields the checks look at."""
    return lua(
        "local out = {} local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(...), 0, -1, false)"
        " for i, line in ipairs(lines) do out[i] = {line = line} end return out",
        iso.sidebar_win(),
    )


def lines():
    return [r["line"] for r in rows()]


def shown():
    return lua("local b = vim.api.nvim_get_current_buf() return vim.b[b].isovim_id and (vim.b[b].isovim_id .. '/' .. (vim.b[b].isovim_agent or 'main')) or ''")


def line_index(text, after=0):
    for i, line in enumerate(lines()):
        if i >= after and text in line:
            return i
    return None


def put_cursor(text, after=0):
    i = iso.wait(lambda: line_index(text, after), f"a row with {text!r}")
    iso.focus_sidebar()
    lua("vim.cmd.stopinsert()")
    iso.keys("Escape")
    lua("vim.api.nvim_win_set_cursor(0, {..., 0})", i + 1)
    return i


def hl_at(line_no, col):
    return lua(
        "local win, row, col = ... local buf = vim.api.nvim_win_get_buf(win) local ns = vim.api.nvim_get_namespaces().isovim_sidebar"
        " for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, {row, 0}, {row, -1}, {details = true})) do"
        " if m[3] <= col and col < m[4].end_col then return m[4].hl_group end end return ''",
        iso.sidebar_win(), line_no, col,
    )


def leader(*keys):
    iso.keys("Escape")
    lua("vim.cmd.stopinsert() vim.api.nvim_set_current_win(require('isovim').main_win())")
    iso.keys("Space", *keys)


def record(key, agent):
    return Path(iso.env["ISOVIM_WORK"]) / key / "iso" / "agents" / f"{agent}.json"


try:
    iso.start()
    work = Path(iso.env["ISOVIM_WORK"])
    # An empty General still shows, with the hint under it, and s on it spawns a general/aN.
    kinds_now = lambda: lua("return require('isovim.sidebar').debug_kinds()")  # noqa: E731
    iso.wait(lambda: "repo" in kinds_now(), "general's header")
    ls, kinds = lines(), kinds_now()
    general = next(i for i, (l, k) in enumerate(zip(ls, kinds)) if k == "repo" and "general" in l)
    check(ls[general + 1].strip() == "no agents · s spawn · ? keys" and "agent" not in kinds, "an empty General shows, with the hint", ls)
    iso.focus_sidebar()
    lua("vim.cmd.stopinsert()")
    iso.keys("Escape")
    lua("vim.api.nvim_win_set_cursor(0, {..., 0})", general + 1)
    iso.keys("s")
    spawned = iso.wait(lambda: lua("return require('isovim.store').agent('general', 'a0')"), "s spawned general/a0", timeout=30)
    check(spawned.get("acp") is True, "s on the empty General spawns general/a0 over ACP", spawned)
    iso.wait(lambda: any("a0" in l for l in lines()[general:]) and "no agents · s spawn" not in "\n".join(lines()), "general/a0 under General, the hint gone")
    check(True, "General lists it and drops the hint")
    # Legacy workspaces: two in acme/web, one in acme/api, the root's, one in no repo.
    ws = {}
    for name, dir_ in (("web1", src / "web"), ("web2", src / "web"), ("api1", src / "api"), ("boss", None), ("notes", None)):
        ws[name] = iso.cli("new", name, *(["--dir", str(dir_)] if dir_ else []))
    # boss holds the root role, and root mode is on for the host (as iso rootmode on host leaves it).
    iso.cli("role", f"{ws['boss']}/main", "root")
    (Path(iso.env["ISOVIM_HOME"]) / "rootmode.json").write_text(json.dumps({"host": {"agent": f"{ws['boss']}/main", "since": 0}, "repos": {}}))
    # acme/web's new layout: an ACP router (a0), a worker of the router's (a1), and a1's team (a2, a3).
    lead = iso.cli("spawn", "--acp", "--repo", str(src / "web"), "--name", "lead")
    check(lead == "acme/web/a0", "an ACP agent in acme/web", lead)
    for name in ("tabfix", "helper", "subhelper"):
        iso.cli("agent", str(src / "web"), "claude", "--v2", "--name", name)
    iso.cli("role", "acme/web/a0", "router")
    for agent, parent in (("a1", "acme/web/a0"), ("a2", "acme/web/a1"), ("a3", "acme/web/a2")):
        path = record("acme/web", agent)
        rec = json.loads(path.read_text())
        rec["parent"] = parent
        path.write_text(json.dumps(rec))
    iso.wait(lambda: json.loads(record("acme/web", "a0").read_text()).get("role") == "router", "a0 is the router")

    # Surfaces: acme/web's question, chat, Task Board and a markdown one; acme/api's markdown; general's file.
    web_iso = work / "acme" / "web" / "iso"
    (web_iso / "ship.surface").write_text(json.dumps({"type": "question", "question": "Ship the tab fix?",
                                                       "options": [{"label": "yes"}, {"label": "not yet"}], "created": int(time.time())}))
    (web_iso / "look.surface").write_text(json.dumps({"type": "chat", "agent": "acme/web/a1"}))
    (web_iso / "tasks.md").write_text("# doing\n- tab line fix\n# blocked\n- vocab rework\n# done\n- setup\n")
    (web_iso / "plan.md").write_text("---\nname: The plan\nicon: P\ncolor: purple\n---\nStep one.\n")
    api_iso = work / "acme" / "api" / "iso"
    api_iso.mkdir(parents=True, exist_ok=True)
    (api_iso / "deploy.md").write_text("---\nname: Deploy notes\nconsumable: true\n---\nGo.\n")
    general_iso = work / "general" / "iso"
    general_iso.mkdir(parents=True, exist_ok=True)
    (general_iso / "readme.surface").write_text(json.dumps({"type": "file", "path": str(src / "api" / "README.md")}))
    # The root's question, in the root pseudo-repo's iso/: the host Inbox lists it.
    root_iso = work / "root" / "iso"
    root_iso.mkdir(parents=True, exist_ok=True)
    (root_iso / "spend.surface").write_text(json.dumps({"type": "question", "question": "Approve the spend?",
                                                        "options": [{"label": "yes"}, {"label": "no"}], "created": int(time.time())}))
    lua("require('isovim.sidebar').refresh()")

    # The list: host Inbox, root pinned first, the repos by name, general last.
    def ready():
        ls = lines()
        return (any("Ship the tab fix?" in l for l in ls) and any("tabfix" in l for l in ls) and any("general" in l for l in ls)
                and any("Approve the spend?" in l for l in ls) and any("readme" in l.lower() for l in ls) and ls)
    ls = iso.wait(ready, "the grouped list", timeout=20)
    print("\n".join(ls))
    kinds = lua("local s = require('isovim.sidebar') return s.debug_kinds()")
    print(kinds)
    first_root = kinds.index("agent")
    check(kinds[0] == "host_inbox" and lines()[first_root].strip().endswith("root") or "root" in lines()[first_root],
          "the host Inbox, then the root pinned first", (kinds, ls))
    headers = [l.strip() for l, k in zip(ls, kinds) if k == "repo"]
    check([h.split()[-1] if h.split()[-1] != "general" else "general" for h in headers][-1] == "general"
          and any("api" in h for h in headers) and any("web" in h for h in headers)
          and headers.index(next(h for h in headers if "api" in h)) < headers.index(next(h for h in headers if "web" in h)),
          "repo headers by name, general last", headers)
    web = line_index("web", line_index("api") or 0)
    web = next(i for i, (l, k) in enumerate(zip(ls, kinds)) if k == "repo" and l.strip().endswith("web"))
    general = next(i for i, (l, k) in enumerate(zip(ls, kinds)) if k == "repo" and "general" in l)
    nxt = next((i for i in range(web + 1, len(kinds)) if kinds[i] == "repo"), len(kinds))
    under_web = ls[web + 1:nxt]
    joined = "\n".join(under_web)
    check(all(n in joined for n in ("web1", "web2", "router", "tabfix (+2)")) and "helper" not in joined,
          "acme/web holds both legacy workspaces, its router and a1 with its team counted (+2), not listed", under_web)
    check(any("router" in l for l in under_web) and under_web.index(next(l for l in under_web if "router" in l))
          < under_web.index(next(l for l in under_web if "tabfix" in l)), "the router before the workers", under_web)
    style = lua("return require('isovim.repos').style('acme/web')")
    glyph_col = len(ls[web].encode()) - len("web".encode()) - 1 - len(style["glyph"].encode())
    check(style["glyph"] in ls[web] and hl_at(web, glyph_col) == "IsovimRepo" + style["color"][1:],
          "the web header in its glyph and color", (ls[web], style, hl_at(web, glyph_col)))
    check("notes" in "\n".join(ls[general:]), "a workspace in no repo goes under general", ls[general:])
    # One row per surface type in the repo's Inbox.
    inbox_rows = "\n".join(ls[web:nxt])
    check("Inbox 2" in inbox_rows, "acme/web's Inbox counts the question and the chat", inbox_rows)
    for text, what in (("? Ship the tab fix?", "question"), ("● chat", "chat"), ("P The plan", "markdown"), ("Task Board", "tasks")):
        check(text in inbox_rows or (what == "tasks" and "tasks" in inbox_rows.lower()), f"a {what} row", inbox_rows)
    check("2 options" in inbox_rows, "the question says how many options", inbox_rows)
    # The host Inbox: busy repos, the root-mode marker (root mode is on for the host).
    host_end = first_root
    host_inbox = ls[:host_end]
    check("root mode" in host_inbox[0] and any("web" in l and "2" in l for l in host_inbox[1:])
          and any("api" in l for l in host_inbox[1:]) and not any("general" in l for l in host_inbox[1:]),
          "the host Inbox: root mode marker, a row per busy repo (general's file surface doesn't wait on you)", host_inbox)
    check(any("Approve the spend?" in l for l in host_inbox[1:]) and "4" in host_inbox[0],
          "the host Inbox lists the root's surfaces from root/iso/ and counts them", host_inbox)
    check("readme" in "\n".join(ls[general:]).lower(), "general's Inbox lists its surface from general/iso/", ls[general:])
    # The meter counts the live agents, the ACP router among them.
    live = iso.wait(lambda: (n := lua("return tonumber(require('isovim.meter').chunks()[2][1]:match('%d+'))")) and n >= 1 and n, "the meter")
    check(live >= 1 and lua("return require('isovim.sidebar').is_live({running = true, acp = true, kind = 'x'})"),
          "the meter counts ACP agents", live)
    iso.screenshot("grouped")
    SHOT.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(Path(REPO / "pilot" / "out" / "sidebar_repos-grouped.png"), SHOT)

    # Enter on the header opens the router.
    put_cursor("web", web)
    lua("vim.api.nvim_win_set_cursor(0, {..., 0})", web + 1)
    iso.keys("Enter")
    # An ACP agent's chat opens with its composer focused: look for the chat in any window.
    iso.wait(lambda: lua(
        "for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do local b = vim.api.nvim_win_get_buf(w)"
        " if vim.b[b].isovim_id == 'acme/web' and vim.b[b].isovim_agent == 'a0' then return true end end return false"
    ), "the router opened from its header")
    check(True, "Enter on a repo header opens its router")

    # Enter on a busy repo in the host Inbox opens that repo's Inbox.
    iso.focus_sidebar()
    lua("vim.cmd.stopinsert()")
    iso.keys("Escape")
    i = next(i for i, l in enumerate(lines()[:first_root]) if "api" in l)
    lua("vim.api.nvim_win_set_cursor(0, {..., 0})", i + 1)
    iso.keys("Enter")
    iso.wait(lambda: "Inbox" in lua("return vim.api.nvim_get_current_line()"), "the cursor on api's Inbox")
    check("Deploy notes" in lines()[lua("return vim.api.nvim_win_get_cursor(0)[1]")], "api's surfaces under its Inbox", lines())

    # Enter on the chat surface opens the chat and consumes it.
    put_cursor("● chat")
    iso.keys("Enter")
    iso.wait(lambda: shown() == "acme/web/a1", "the chat surface opened a1")
    iso.wait(lambda: not (web_iso / "look.surface").exists(), "the chat surface consumed")
    iso.wait(lambda: not any("● chat" in l for l in lines()), "its row gone")
    check(True, "Enter on a chat surface opens the agent and consumes it")

    # ii, ih, iI.
    lua("require('isovim').open(...)", ws["web1"], "main")
    iso.wait(lambda: shown() == f"{ws['web1']}/main", "web1 open")
    leader("i", "i")
    iso.wait(lambda: lua("return vim.b.isovim_sidebar") == "list", "the list focused")
    line = lua("return vim.api.nvim_get_current_line()")
    check("Ship the tab fix?" in line, "<leader>ii: the repo's first waiting surface", line)
    leader("i", "h")
    iso.wait(lambda: lua("return vim.b.isovim_sidebar") == "list", "the list focused")
    line = lua("return vim.api.nvim_get_current_line()")
    check(lua("return vim.api.nvim_win_get_cursor(0)[1]") > 1 and "Approve the spend?" in line,
          "<leader>ih: the host Inbox's first waiting surface, the root's question", line)

    # Collapsing persists through a hot reload.
    i = put_cursor("web", next(i for i, k in enumerate(lua("return require('isovim.sidebar').debug_kinds()")) if k == "repo"))
    i = next(i for i, (l, k) in enumerate(zip(lines(), lua("return require('isovim.sidebar').debug_kinds()"))) if k == "repo" and l.strip().endswith("web"))
    lua("vim.api.nvim_win_set_cursor(0, {..., 0})", i + 1)
    iso.keys("Tab")
    iso.wait(lambda: lines()[i].startswith("▸"), "web collapsed")
    check(not any("tabfix" in l for l in lines()), "collapsed, web's agents are gone", lines())
    lua("require('isovim.reload').reload()")
    time.sleep(1)
    iso.wait(lambda: any(l.strip().endswith("web") or "web " in l for l in lines()), "the list after the reload")
    check(not any("tabfix" in l for l in lines()) and any(l.startswith("▸") and "web" in l for l in lines()),
          "web stays collapsed through a hot reload", lines())
    i = next(i for i, l in enumerate(lines()) if l.startswith("▸") and "web" in l)
    iso.focus_sidebar()
    lua("vim.cmd.stopinsert()")
    iso.keys("Escape")
    lua("vim.api.nvim_win_set_cursor(0, {..., 0})", i + 1)
    iso.keys("Tab")
    iso.wait(lambda: any("tabfix" in l for l in lines()), "web open again")

    # The top Inbox: the other host's waiting surface; iI lands on it, Enter shows that host.
    top = iso.wait(lambda: (r := iso.sidebar("inbox")) and len(r) > 1 and r, "the other host's surface in the top Inbox", timeout=20)
    check(top[0].startswith("▾ Inbox 1") and "other" in top[1] and "Deploy zeta?" in top[1], "the top Inbox lists other hosts' waiting surfaces", top)
    leader("i", "I")
    iso.wait(lambda: lua("return vim.b.isovim_sidebar") == "inbox", "the top Inbox focused")
    check("Deploy zeta?" in lua("return vim.api.nvim_get_current_line()"), "<leader>iI: the other hosts' first surface")
    iso.keys("Enter")
    iso.wait(lambda: lua("return vim.g.isovim_sidebar_host") == "other", "Enter shows the other host")
    iso.wait(lambda: any("zworker" in l for l in lines()), "the other host's list")
    remote = lines()
    print("\n".join(remote))
    kinds = lua("return require('isovim.sidebar').debug_kinds()")
    zeta = next(i for i, (l, k) in enumerate(zip(remote, kinds)) if k == "repo" and "zeta" in l)
    check("Z" in remote[zeta] and any("router" in l for l in remote[zeta:]) and "general" in "\n".join(remote)
          and any("scratch" in l for l in remote[remote.index(next(l for l in remote if "general" in l)):]),
          "the peer's list groups by the repo its iso ls names; a row without one under general", remote)
    check(any("Deploy zeta?" in l for l in remote), "the peer's repo Inbox shows its surface", remote)
    iso.screenshot("peer")
    iso.focus_sidebar()
    lua("vim.cmd.stopinsert()")
    iso.keys("Escape")
    iso.keys("<")
    iso.wait(lambda: lua("return vim.g.isovim_sidebar_host") is None, "back to this host")
    iso.wait(lambda: any("tabfix" in l for l in lines()), "this host's list")
    check(True, "< steps back to this host")
finally:
    if fails:
        try:
            print(iso.screen())
        except Exception:
            pass
    iso.stop()

print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
