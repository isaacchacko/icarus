"""The keymap: LazyVim's global keys turned to repos (<leader><leader> picks a repo or Root, General,
Terminals; <leader>ff, <leader>/ with transcripts, <leader>, scoped to the repo, <leader>fr recent
agents), the <leader>i group (needs-you, the Inbox, router and roots by role, worker and agent
pickers, the previous agent, General, Terminals, spawn, terminal, hosts, the keys not built yet), the
sidebar's s spawn, x, S and its retiring a/A/b/T, the retiring <leader>a keys, buffers scoped by repo,
and the help. Keys are pressed in the pilot's own TUI.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/keymap.py"""

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


def git(cwd, *args):
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True)


iso = Iso("keymap", cols=140, rows=40, agent_delay=0.3)
# A fake peer, so <leader>i< and <leader>i> have a host to step to.
(iso.tmp / "remote.json").write_text("[]")
(iso.tmp / "remote-iso").write_text(f"#!/bin/sh\ncat {iso.tmp / 'remote.json'}\n")
os.chmod(iso.tmp / "remote-iso", 0o755)
(iso.tmp / "ssh-env").write_text("")
iso.env.update(
    ISOVIM_PEERS="other=other",
    ISOVIM_SSH=str(REPO / "pilot" / "fake-ssh"),
    ISOVIM_REMOTE_BIN=str(iso.tmp / "remote-iso"),
    FAKE_SSH_ENV=str(iso.tmp / "ssh-env"),
)

# Two repos, each a clone of a bare origin named acme/<repo>.
for repo in ("web", "api"):
    origin = iso.tmp / "origins" / "acme" / f"{repo}.git"
    src = iso.tmp / "src" / repo
    src.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
    git(src, "init", "-q", "-b", "main")
    (src / "README.md").write_text(f"{repo} readme\n")
    git(src, "add", ".")
    git(src, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init")
    git(src, "remote", "add", "origin", str(origin))
    git(src, "push", "-q", "origin", "main")
    git(src, "remote", "set-head", "origin", "main")
loose = iso.tmp / "loose.txt"
loose.write_text("outside every repo\n")


def lua(code, *args):
    return iso.lua(code, *args)


def shown():
    return lua("local b = vim.api.nvim_get_current_buf() return vim.b[b].isovim_id and (vim.b[b].isovim_id .. '/' .. (vim.b[b].isovim_agent or 'main')) or ''")


def scope():
    return lua("return require('isovim').current_scope")


def leader(*keys):
    iso.keys("Escape")
    lua("vim.cmd.stopinsert()")
    iso.keys("Space", *keys)


def picker():
    return lua(
        "local p = Snacks.picker.get()[1] if not p then return nil end"
        " return {title = p.title, items = vim.tbl_map(function(i) return i.text end, p:items()), cwd = p:cwd(), dirs = p.opts.dirs}"
    )


def close_picker():
    lua("for _, p in ipairs(Snacks.picker.get()) do p:close() end")
    iso.wait(lambda: not lua("return Snacks.picker.get()[1] ~= nil"), "the picker closed")


def toasts():
    return iso.toasts()


def toasted(text):
    return iso.wait(lambda: any(text in t for t in toasts()) and True, f"a toast with {text!r}")


def edit(path):
    lua("vim.api.nvim_set_current_win(require('isovim').main_win()) vim.cmd.edit(...)", path)


def open_agent(address):
    ws, agent = address.split("/")
    lua("require('isovim').open(...)", ws, agent)
    iso.wait(lambda: shown() == address, f"{address} on screen")


def tabs_scopes():
    return lua(
        "local out = {} for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[b].buflisted then"
        " out[#out + 1] = vim.b[b].isovim_scope or '?' end end return out"
    )


try:
    iso.start()
    src = iso.tmp / "src"
    ws = {}
    for name, dir_ in (("web1", src / "web"), ("web2", src / "web"), ("api1", src / "api"), ("notes", None), ("boss", None)):
        args = ["new", name] + (["--dir", str(dir_)] if dir_ else [])
        ws[name] = iso.cli(*args)
    iso.cli("role", f"{ws['web1']}/main", "router")
    iso.cli("root", f"{ws['boss']}/main")
    # Four workspaces by name, and the root's pinned first as "root".
    iso.wait(lambda: sum(1 for row in iso.sidebar() if any(n in row for n in ws)) == 4 and any(row.endswith(" root") for row in iso.sidebar()), "five workspaces")

    # Every global and <leader>i key is isovim's, over LazyVim's.
    maps = lua(
        "local keys = require('isovim.keys') local out = {}"
        " for _, k in ipairs(keys.GLOBAL) do out[k[1]] = vim.fn.maparg(k[1], 'n', false, true).desc or '' end"
        " for _, k in ipairs(keys.GROUP) do local lhs = '<leader>i' .. k[1] out[lhs] = vim.fn.maparg(lhs, 'n', false, true).desc or '' end"
        " out['<leader>e'] = vim.fn.maparg('<leader>e', 'n', false, true).desc or '' return out"
    )
    others = {lhs: desc for lhs, desc in maps.items() if not desc.startswith("isovim: ")}
    check(not others and len(maps) == 28, f"{len(maps)} keys, all isovim's", others)
    group = lua("local ok, config = pcall(require, 'which-key.config') if not ok then return 'no which-key' end"
                " for _, m in ipairs(config.mappings or {}) do if m.lhs == '<leader>i' or m[1] == '<leader>i' then return m.desc end end return ''")
    check(group == "isovim", "which-key group isovim under <leader>i", group)

    # <leader><leader>: Root pinned first, the repos, then General and Terminals.
    leader("Space")
    p = iso.wait(picker, "the repo picker")
    iso.screenshot("repos")
    print("repos:", p["items"])
    check(p["title"] == "Repos" and p["items"][0] == "Root" and p["items"][-2:] == ["General", "Terminals"]
          and {"acme/web", "acme/api"} <= set(p["items"]), "the repo picker lists Root, the repos, General, Terminals", p)
    iso.type("acme/api")
    iso.keys("Enter")
    iso.wait(lambda: shown() == f"{ws['api1']}/main", "api1 opened from the picker")
    check(scope() == "acme/api", "picking a repo makes it the scope", scope())
    iso.screenshot("api")

    # Buffers are listed by repo: web's two workspaces share a scope; a file outside every repo is General's.
    edit(str(src / "api" / "README.md"))
    open_agent(f"{ws['web1']}/main")
    open_agent(f"{ws['web2']}/main")
    check(set(tabs_scopes()) == {"acme/web"} and len(tabs_scopes()) == 2, "web's buffers listed, both workspaces'", tabs_scopes())
    leader(",")
    p = iso.wait(picker, "the buffers picker")
    check(p["title"].startswith("Buffers · acme/web") and len(p["items"]) == 2, "<leader>, lists the repo's buffers", p)
    close_picker()
    edit(str(loose))
    iso.wait(lambda: scope() == "general", "a file outside every repo makes General the scope")
    check(tabs_scopes() == ["general"], "only General's buffers listed", tabs_scopes())
    open_agent(f"{ws['web2']}/main")
    check(scope() == "acme/web", "back to web", scope())

    # Roles: the repo's router, the host root, the nearest root.
    leader("i", "r")
    iso.wait(lambda: shown() == f"{ws['web1']}/main", "<leader>ir: web's router")
    check(True, "<leader>ir opens the repo's router")
    leader("i", "H")
    iso.wait(lambda: shown() == f"{ws['boss']}/main", "<leader>iH: the host root")
    check(scope() == "root", "the root's chat is Root's scope", scope())
    leader("i", "b")
    iso.wait(lambda: shown() == f"{ws['web1']}/main", "<leader>ib: back to web1")
    check(True, "<leader>ib opens the previous agent")
    leader("i", "R")
    iso.wait(lambda: shown() == f"{ws['boss']}/main", "<leader>iR without a repo-root: the host root")
    check(True, "<leader>iR falls back to the host root")
    open_agent(f"{ws['api1']}/main")
    leader("i", "r")
    toasted("No router in acme/api")
    check(True, "<leader>ir in a repo with no router says so")

    # Pickers: recent agents, workers in the repo, any agent.
    leader("f", "r")
    p = iso.wait(picker, "recent agents")
    print("recent:", p["items"][:3])
    check(p["title"] == "Recent agents" and p["items"][0].startswith("boss main") and not any(i.startswith("api1") for i in p["items"]),
          "<leader>fr: recent agents, the last one first, not the one shown", p["items"])
    close_picker()
    open_agent(f"{ws['web1']}/main")
    leader("i", "w")
    p = iso.wait(picker, "workers")
    check(p["title"] == "Workers · acme/web" and [i.split()[0] for i in p["items"]] == ["web2"], "<leader>iw: the repo's workers", p)
    iso.type("web2")
    iso.keys("Enter")
    iso.wait(lambda: shown() == f"{ws['web2']}/main", "web2 from the worker picker")
    leader("i", "a")
    p = iso.wait(picker, "any agent")
    check(len(p["items"]) == 5, "<leader>ia: every agent", p["items"])
    close_picker()
    iso.cli("role", f"{ws['web2']}/main", "repo-root")
    open_agent(f"{ws['web1']}/main")
    leader("i", "R")
    iso.wait(lambda: shown() == f"{ws['web2']}/main", "<leader>iR: the repo-root")
    check(True, "<leader>iR opens the repo's repo-root")

    # Files and grep in the repo, grep with its agents' transcripts.
    leader("f", "f")
    p = iso.wait(picker, "files")
    check(os.path.realpath(p["cwd"]) == os.path.realpath(src / "web") and "README.md" in " ".join(p["items"]), "<leader>ff: the repo's files", p)
    close_picker()
    transcripts = Path(lua("return require('isovim.store').path(...)", ws["web1"])) / "transcripts"
    transcripts.mkdir(exist_ok=True)
    (transcripts / "main.txt").write_text("user: the zebra crossing\n")
    leader("/")
    iso.wait(picker, "grep")
    iso.type("zebra")
    p = iso.wait(lambda: (q := picker()) and q["items"] and q, "a grep hit")
    check(str(transcripts) in (p["dirs"] or []) and any("zebra" in i for i in p["items"]), "<leader>/ greps the transcripts too", p)
    close_picker()

    # Needs you: next, and the Inbox by repo / host / other hosts.
    lua("require('isovim.root').raise(..., 'main', 'api?')", ws["api1"])
    lua("require('isovim.root').raise(..., 'main', 'web?')", ws["web2"])
    iso.wait(lambda: sum(r["status"] == "attention" for r in json.loads(iso.cli("ls", "--json"))) == 2, "two raised")
    # With no surface waiting, <leader>in opens a legacy agent that needs you.
    open_agent(f"{ws['notes']}/main")
    leader("i", "n")
    iso.wait(lambda: shown() in (f"{ws['api1']}/main", f"{ws['web2']}/main"), "<leader>in: an agent that needs you")
    check(True, "<leader>in opens an agent that needs you when no surface waits")
    # Inboxes show only surfaces: a question in acme/web's, which <leader>in now opens first.
    web_iso = Path(iso.env["ISOVIM_WORK"]) / "acme" / "web" / "iso"
    web_iso.mkdir(parents=True, exist_ok=True)
    (web_iso / "q.surface").write_text(json.dumps({"type": "question", "question": "Merge web?", "options": [{"label": "yes"}]}))
    lua("require('isovim.sidebar').refresh()")
    iso.wait(lambda: any("Merge web?" in row for row in iso.sidebar()), "the question in web's Inbox")
    open_agent(f"{ws['notes']}/main")
    leader("i", "n")
    iso.wait(lambda: "Merge web? ─" in iso.screen(), "<leader>in: the waiting question's picker")
    check(True, "<leader>in opens the waiting surface first")
    iso.keys("Escape")
    iso.keys("Escape")
    iso.wait(lambda: "Merge web? ─" not in iso.screen(), "the picker closed")
    open_agent(f"{ws['web1']}/main")
    leader("i", "i")
    iso.wait(lambda: lua("return vim.b.isovim_sidebar") == "list", "the list focused")
    line = lua("return vim.api.nvim_get_current_line()")
    check("Merge web?" in line, "<leader>ii: the repo's waiting surface", line)
    leader("i", "I")
    iso.wait(lambda: lua("return vim.b.isovim_sidebar") == "inbox", "the top Inbox focused")
    row = lua("return vim.api.nvim_win_get_cursor(0)[1]")
    check(row == 1, "<leader>iI: no other host's surface, the title", row)
    leader("i", "h")
    iso.wait(lambda: lua("return vim.b.isovim_sidebar") == "list", "the list focused")
    line = lua("return vim.api.nvim_get_current_line()")
    check("web" in line and "1" in line, "<leader>ih: the host Inbox's busy repo", line)

    # Terminals, General, a new terminal.
    leader("i", "T")
    iso.wait(lambda: lua("return vim.b.isovim_sidebar") == "terminals", "<leader>iT: the Terminals window")
    check(True, "<leader>iT focuses the Terminals window")
    leader("i", "g")
    iso.wait(lambda: shown() == f"{ws['notes']}/main", "<leader>ig: General's agent")
    check(scope() == "general", "General is the scope", scope())
    leader("i", "t")
    iso.wait(lambda: lua("return vim.b.isovim_agent") == "terminal", "<leader>it: a new terminal")
    check(scope() == "general", "a terminal leaves the scope as it was", scope())
    leader("Space")
    iso.wait(picker, "the repo picker")
    iso.type("Terminals")
    iso.keys("Enter")
    iso.wait(lambda: scope() == "terminals", "Terminals picked")
    check(lua("return vim.b.isovim_sidebar") == "terminals" and tabs_scopes() == ["terminals"], "picking Terminals lists only terminals", tabs_scopes())

    # Hosts, from anywhere.
    open_agent(f"{ws['web1']}/main")
    leader("i", ">")
    iso.wait(lambda: lua("return vim.g.isovim_sidebar_host") == "other", "<leader>i>: the next host")
    leader("i", "<")
    iso.wait(lambda: lua("return vim.g.isovim_sidebar_host") is None, "<leader>i<: back")
    check(True, "<leader>i< and <leader>i> step the host list")

    # Not yet.
    leader("i", "q")
    toasted("The prompt queue: open an ACP agent's chat first")
    leader("i", "x")
    toasted("Root mode: not yet")
    leader("i", "u")
    toasted("rewind: put the cursor on one of your prompts in an ACP agent's chat")
    leader("i", "f")
    toasted("fork: open an ACP agent's chat first")
    check(True, "ix says not yet; iq, iu and if that they need an ACP chat")

    # Retiring <leader>a keys: they still work, and say once what replaced them.
    lua("require('isovim.root').raise(..., 'main', 'again?')", ws["api1"])
    open_agent(f"{ws['notes']}/main")
    leader("a", "j")
    toasted("<leader>aj is retiring: <leader>in")
    iso.wait(lambda: shown() != f"{ws['notes']}/main", "<leader>aj still jumps")
    count = sum("<leader>aj is retiring" in t for t in toasts())
    leader("a", "j")
    check(sum("<leader>aj is retiring" in t for t in toasts()) == count == 1, "the hint shows once", toasts()[-3:])

    # Sidebar: s spawns in the repo under the cursor; x, S; a/A/b/T still work with a hint.
    iso.focus_sidebar()
    rows = iso.sidebar()
    target = next(i for i, r in enumerate(lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")) if "api1" in r)
    lua("vim.api.nvim_win_set_cursor(0, {..., 0})", target + 1)
    iso.keys("s")
    # A legacy workspace's row spawns in the repo its dir is a clone of: its next aN, over ACP.
    feat = iso.wait(lambda: lua("return require('isovim.store').agent('acme/api', 'a0')"), "s spawned acme/api/a0", timeout=30)
    check(feat.get("acp") is True and feat.get("repo") == "acme/api" and feat.get("checkout"),
          "s spawns a worker over ACP, the repo's next aN", feat)
    iso.wait(lambda: lua(
        "for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do local b = vim.api.nvim_win_get_buf(w)"
        " if vim.b[b].isovim_id == 'acme/api' and vim.b[b].isovim_agent == 'a0' then return true end end return false"),
        "the spawned agent's chat opened", 30)
    # <leader>is from its chat spawns beside it, in the same repo.
    lua("vim.cmd.stopinsert()")
    iso.keys("Escape")
    leader("i", "s")
    iso.wait(lambda: lua("return require('isovim.store').agent('acme/api', 'a1')"), "<leader>is spawned acme/api/a1", timeout=30)
    check(True, "<leader>is spawns in the shown agent's repo")
    composers = lambda: lua(  # noqa: E731
        "local n = 0 for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do"
        " if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match('composer$') then n = n + 1 end end return n")
    iso.wait(lambda: lua(
        "for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do local b = vim.api.nvim_win_get_buf(w)"
        " if vim.b[b].isovim_id == 'acme/api' and vim.b[b].isovim_agent == 'a1' then return true end end return false"),
        "a1's chat opened", 30)
    check(composers() == 1, "its chat replaces a0's, composer and all", composers())
    iso.focus_sidebar()
    lua("vim.cmd.stopinsert()")
    iso.keys("Escape")
    iso.keys("x")
    toasted("Root mode: not yet")
    sort = lua("return require('isovim').sort")
    iso.keys("S")
    iso.wait(lambda: lua("return require('isovim').sort") != sort, "S sorts")
    iso.keys("a")
    toasted("a in the sidebar is retiring: s spawns")
    iso.wait(lambda: "New workspace" in iso.screen(), "a still asks for a new workspace")
    iso.keys("Escape")
    iso.keys("Escape")
    iso.focus_sidebar()
    before = lua("return require('isovim').show_tasks")
    iso.keys("T")
    toasted("T in the sidebar is retiring")
    check(lua("return require('isovim').show_tasks") != before, "T still toggles tasks", before)
    iso.keys("T")
    check(True, "sidebar x, S, a, T")

    # The help: the global keys, the <leader>i group, the retiring keys.
    iso.keys("?")
    help_lines = iso.wait(
        lambda: lua(
            "for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do if vim.api.nvim_win_get_config(w).relative ~= '' then"
            " local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)"
            " if lines[1] and lines[1]:match('^# Sidebar') then return lines end end end"
        ),
        "help",
    )
    text = "\n".join(help_lines)

    def section(title):
        start = next(i for i, l in enumerate(help_lines) if l.startswith("# " + title))
        end = next((i for i in range(start + 1, len(help_lines)) if help_lines[i].startswith("# ")), len(help_lines))
        return "\n".join(help_lines[start:end])

    host_list = section("Host list")
    check("  s " in host_list and "  x " in host_list and "  a " not in host_list and "  T " not in host_list, "the host list's keys: s and x, no a or T", host_list)
    check("<leader><leader>" in section("Anywhere") and "<leader>ff" in section("Anywhere"), "the global keys", section("Anywhere"))
    group_help = section("<leader>i")
    check(all(f"<leader>i{k}" in group_help for k in "niIhrRHwabgTstxjquf") and "not yet" in group_help, "the <leader>i group", group_help)
    check("<leader>aj" in section("Retiring") and "<leader>in" in section("Retiring"), "the retiring keys", section("Retiring"))
    iso.screenshot("help")
    iso.keys("G")
    iso.screenshot("help-leader")
    iso.keys("q")
finally:
    iso.stop()

if fails:
    print(f"\n{len(fails)} failed: {fails}")
    sys.exit(1)
print("\nall keymap checks passed")
