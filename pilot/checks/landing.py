"""The landing (isovim.landing): on start with nothing to resume it opens in the editing area, focused,
a scratch page (filetype isovim_landing, not modifiable, no number or sign column) that leaves no
[No Name] behind. It lists the repos in the world's ~/.isovim/repos (writing none of their configs),
its keys' words come from isovim.keys and the sidebar's tables (a description changed there
follows), each quick action does
its thing (s spawns in the repo picked, p picks a repo, j jumps, i opens the host's Inbox, t opens a
terminal, m picks a repo and then the host, ? the help), the Inbox count shows and follows a surface
that comes, <leader>il brings it back from a chat (its composer closes), it belongs to no workspace's
layout and wiping it leaves an editing window, and a restarted TUI that resumes a chat doesn't cover it.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/landing.py"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


iso = Iso("landing", cols=140, rows=40, agent_delay=0.3)
# A fake peer, so m has a host to send to.
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
home = iso.tmp / "home"
for name in ("acme/app", "acme/web"):
    (home / "repos" / name).mkdir(parents=True)


def lua(code, *args):
    return iso.lua(code, *args)


def landing_win():
    return lua("for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do"
               " if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'isovim_landing' then return w end end return vim.NIL")


def page():
    win = landing_win()
    return "\n".join(lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(...), 0, -1, false)", win)) if win else ""


def focused():
    return lua("return vim.bo.filetype") == "isovim_landing"


def chat_shown():
    """The ACP chat in focus (its chat or composer) as ws/agent, else ''."""
    return lua("local c = require('isovim.acp.chat').of_buf() return c and (c.ws .. '/' .. c.agent) or ''")


def refresh():
    lua("require('isovim.landing').refresh()")


def leader(*keys):
    iso.keys("Escape")
    lua("vim.cmd.stopinsert()")
    iso.keys("Space", *keys)


def picker():
    return lua("local p = Snacks.picker.get()[1] return p and p.title or vim.NIL")


def close_picker():
    lua("for _, p in ipairs(Snacks.picker.get()) do p:close() end")
    iso.wait(lambda: not picker(), "the picker closed")


def soon(fn, timeout=5):
    try:
        return bool(iso.wait(fn, "it", timeout))
    except AssertionError:
        return False


try:
    iso.start()
    print("# on start")
    iso.wait(landing_win, "the landing on start")
    check(focused(), "it opens focused", lua("return vim.bo.filetype"))
    check(not lua("return require('isovim').is_sidebar(...)", landing_win()), "in the editing area, not the sidebar")
    opts = lua("local w = ... local b = vim.api.nvim_win_get_buf(w)"
               " return {vim.bo[b].modifiable, vim.bo[b].buftype, vim.bo[b].buflisted, vim.wo[w].number, vim.wo[w].relativenumber, vim.wo[w].signcolumn}",
               landing_win())
    check(opts == [False, "nofile", False, False, False, "no"], "a scratch page, not modifiable, no number or sign column", opts)
    check(iso.tabs() == [], "no [No Name] left in the tab bar", iso.tabs())
    shot = iso.screenshot("start")
    print("screenshot:", shot)

    print("\n# the repos, from ~/.isovim/repos")
    check("acme/app" in page() and "acme/web" in page(), "the world's repos are listed", page())
    check(not list((home / "repos").glob("*/*/config.json")), "drawing them writes no repo config (a color is the sidebar's to give)",
          list((home / "repos").glob("*/*/config.json")))
    (home / "repos" / "acme" / "new").mkdir()
    refresh()
    check("acme/new" in page(), "a repo set up later shows on the next refresh")

    print("\n# keys, from the tables")
    text = page()
    for want in ("spawn a worker over ACP in the repo", "space i s", "pick a repo", "space space", "next agent that needs you",
                 "send it to another host", "m in the sidebar", "space i l brings this page back"):
        check(want in text, f"shows {want!r}", text)
    lua("for _, k in ipairs(require('isovim.keys').GROUP) do if k[1] == 's' then k[3] = 'start a worker in the repo (changed)' end end"
        " for _, k in ipairs(require('isovim.sidebar').LIST_KEYS) do if k[1] == 'm' then k[3] = 'ship it elsewhere: changed' end end")
    refresh()
    text = page()
    check("start a worker in the repo" in text and "spawn a worker over ACP in the repo" not in text, "a GROUP description changed follows", text)
    check("ship it elsewhere" in text and "send it to another host" not in text, "a sidebar key's description changed follows", text)
    lua("for _, k in ipairs(require('isovim.keys').GROUP) do if k[1] == 's' then k[3] = 'spawn a worker over ACP in the repo' end end"
        " for _, k in ipairs(require('isovim.sidebar').LIST_KEYS) do if k[1] == 'm' then k[3] = 'send it to another host, picked from the peers' end end")
    refresh()
    check("Nothing waits on you." in page(), "the Inbox count says nothing waits")

    print("\n# quick actions")
    # vim.ui.select answers by prompt, and records what it was asked.
    lua("_G.asked, _G.answers = {}, {}"
        " vim.ui.select = function(items, opts, cb) table.insert(_G.asked, {prompt = opts.prompt, items = items}) cb(_G.answers[opts.prompt]) end")
    iso.keys("p")
    check(soon(lambda: picker() == "Repos"), "p picks a repo", picker())
    close_picker()
    iso.wait(focused, "back on the landing")
    iso.keys("j")
    check(soon(lambda: (picker() or "").startswith("Jump")), "j jumps", picker())
    close_picker()
    iso.wait(focused, "back on the landing")
    iso.keys("?")
    check(soon(lambda: lua("for _, w in ipairs(vim.api.nvim_list_wins()) do if vim.api.nvim_win_get_config(w).relative ~= '' then"
                           " for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do"
                           " if l == '# Host list' then return true end end end end return false")), "? opens the help")
    iso.keys("q")
    iso.wait(focused, "back on the landing")
    iso.keys("m")
    asked = lua("return _G.asked")
    check(len(asked) == 1 and asked[0]["prompt"] == "Send which repo to another host?" and asked[0]["items"] == ["acme/app", "acme/new", "acme/web"],
          "m asks which repo", asked)
    lua("_G.asked = {} _G.answers['Send which repo to another host?'] = 'acme/app'")
    iso.keys("m")
    asked = lua("return _G.asked")
    check(len(asked) == 2 and asked[1]["prompt"] == "Send acme/app's agents to" and asked[1]["items"] == ["other"],
          "then the host to send it to, as m on its row in the sidebar", asked)
    iso.keys("i")
    check(soon(lambda: lua("local w = vim.api.nvim_get_current_win() return vim.b[vim.api.nvim_win_get_buf(w)].isovim_sidebar") == "list"
               and lua("return require('isovim.sidebar').debug_kinds()[vim.fn.line('.')]") == "host_inbox"),
          "i opens the host's Inbox", lua("return require('isovim.sidebar').debug_kinds()"))
    leader("i", "l")
    check(soon(focused), "<leader>il brings it back from the sidebar")
    lua("_G.asked = {} _G.answers['Spawn a worker in which repo?'] = 'acme/app'")
    iso.keys("s")
    asked = lua("return _G.asked")
    check(asked and asked[0]["items"] == ["acme/app", "acme/new", "acme/web", "general"], "s asks which repo (or General)", asked)
    check(soon(lambda: chat_shown() == "acme/app/a0", 15), "and spawns a worker there, its chat in the landing's place", chat_shown())
    check(not landing_win() and not lua("for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[b].filetype == 'isovim_landing' then return true end end return false"),
          "the landing is gone, its buffer wiped")

    print("\n# back from a chat; the Inbox count")
    leader("i", "l")
    check(soon(focused), "<leader>il brings it back from the chat's composer")
    check(lua("for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do if vim.b[vim.api.nvim_win_get_buf(w)].isovim_composer then return false end end return true"),
          "the chat's composer closed with it")
    saved = lua("local out = {} local function walk(n) if n[1] == 'leaf' then out[#out + 1] = vim.bo[n[2].buf].filetype"
                " else for _, c in ipairs(n[2]) do walk(c) end end end"
                " local l = (vim.g.isovim_layouts or {})['acme/app'] if l then walk(l.tree) end return out")
    check(saved and "isovim_landing" not in saved, "acme/app's layout never holds the landing", saved)
    (iso.tmp / "work" / "acme" / "app" / "iso" / "note.md").write_text("---\nconsumable: true\n---\nread me\n")
    check(soon(lambda: "1 waiting on you here" in page(), 10), "a surface waiting shows in the Inbox count", page())
    iso.screenshot("inbox")

    print("\n# t, a terminal")
    iso.keys("t")
    check(soon(lambda: lua("return vim.bo.buftype == 'terminal' and vim.b.isovim_id ~= nil")), "t opens a terminal",
          lua("return {vim.bo.buftype, vim.bo.filetype}"))
    leader("i", "l")
    check(soon(focused), "<leader>il brings it back from a terminal")

    print("\n# wiping it")
    lua("for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[b].filetype == 'isovim_landing' then vim.api.nvim_buf_delete(b, {force = true}) end end")
    time.sleep(0.5)
    wins = lua("local m, s = 0, 0 for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do"
               " if require('isovim').is_sidebar(w) then s = s + 1 else m = m + 1 end end return {m, s}")
    check(wins[0] >= 1 and iso.sidebar_win(), "an editing window and the sidebar stay", wins)

    print("\n# a restored session")
    lua("require('isovim').open('acme/app', 'a0')")
    iso.wait(lambda: chat_shown() == "acme/app/a0", "a0's chat")
    layout_json = iso.tmp / "work" / "acme" / "app" / "iso" / "layout.json"
    iso.wait(lambda: layout_json.exists() and '"a0"' in layout_json.read_text(), "the layout saved with a0's chat")
    iso.close_tui()
    iso.start()
    check(soon(lambda: lua("for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do local b = vim.api.nvim_win_get_buf(w)"
                           " if vim.b[b].isovim_id == 'acme/app' and vim.b[b].isovim_agent == 'a0' then return true end end return false"), 10),
          "the restarted TUI resumes a0's chat")
    time.sleep(1)
    check(not landing_win(), "and the landing doesn't cover it", page())
    leader("i", "l")
    check(soon(focused) and "1 waiting on you here" in page(), "<leader>il still brings it back, the count read again", page())
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
