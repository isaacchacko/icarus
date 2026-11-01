"""Hot reload through the real file watcher, on a copy of isovim's source (a git repo of its own in the
world's dir) so no other running isovim reloads. With an ACP agent's chat and composer, a surface
view and the sidebar open: an edit to acp/chat.lua (a subdirectory, which inotify doesn't watch on
its own) and to surface_view.lua and sidebar.lua at the top reloads once, saying which files; the
chat's, the composer's, the view's and the sidebar's keys then run the new code, and the chat's
lines, where its window was scrolled, the composer's text and a tool call and thought opened with
za are kept, with no autocmd left twice. A change to starter/ says to restart, but for
config/keymaps.lua, which runs again. A file that doesn't compile, and a module that fails as it
loads, keep the old code and say so. A git pull that changes acp/, top-level files, a new directory
and starter/ reloads once, with the restart note.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/hot_reload.py"""

import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

DOT = "⏺" if sys.platform == "darwin" else "●"
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


def git(*args, cwd=None):
    subprocess.run(["git", "-c", "user.name=pilot", "-c", "user.email=pilot@example.com", *args],
                   check=True, capture_output=True, cwd=cwd)


iso = Iso("hot_reload", agent_delay=0.2)
iso.env["ISOVIM_SELF"] = "pilothost"
SRC = iso.tmp / "isovim"
for part in ("bin", "lua", "starter", "prompts"):
    shutil.copytree(REPO / part, SRC / part, symlinks=True)
git("init", "-q", "-b", "main", cwd=SRC)
git("add", "-A", cwd=SRC)
git("commit", "-q", "-m", "the copy", cwd=SRC)
iso.repo = SRC
BIN = str(SRC / "bin" / "iso")


def run(*args, timeout=60):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def edit(rel, old, new, root=SRC):
    path = root / rel
    text = path.read_text()
    assert old in text, (rel, old)
    path.write_text(text.replace(old, new))


def journal(agent):
    path = iso.tmp / "work" / "acme" / "app" / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def chat():
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', 'a0')"
                   " return c and vim.api.nvim_buf_get_lines(c.buf, 0, -1, false) or vim.NIL")


def composer():
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', 'a0')"
                   " return c and vim.api.nvim_buf_get_lines(c.composer, 0, -1, false) or vim.NIL")


def has(text):
    return any(text in line for line in (chat() or []))


def turn_ends():
    return sum(1 for e in journal("a0") if e["kind"] == "turn" and e["state"] == "end")


def send(text, after):
    ends = turn_ends()
    rc, _, err = run("send", "acme/app/a0", text)
    assert rc == 0, err
    iso.wait(lambda: turn_ends() > ends and has(after), f"the reply to {text}", 30)


def chat_win():
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', 'a0') return vim.fn.bufwinid(c.buf)")


def view_of_chat():
    return iso.lua("return vim.api.nvim_win_call(..., vim.fn.winsaveview)", chat_win())


def autocmds():
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', 'a0')"
                   " local function of(buf) local list = {} for _, au in ipairs(vim.api.nvim_get_autocmds({ buffer = buf })) do"
                   " if not au.group_name or au.group_name:match('^isovim') then table.insert(list, au.event .. ' ' .. (au.group_name or '-')) end"
                   " end table.sort(list) return list end"
                   " return { of(c.buf), of(c.composer) }")


def toasts_after(n, what, pred, timeout=15):
    return iso.wait(lambda: next((t for t in iso.toasts()[n:] if pred(t)), None), what, timeout)


def reloads_after(n):
    return [t for t in iso.toasts()[n:] if t.startswith("isovim reload")]


def probe(name):
    return iso.lua(f"return vim.g.hot_reload_{name}")


def press_in_chat(*keys):
    iso.lua("vim.cmd.stopinsert() vim.api.nvim_set_current_win(...)", chat_win())
    iso.keys("Escape")
    iso.keys(*keys)


def chat_probe():
    """Whether ]] in the open chat runs the code that sets vim.g.hot_reload_chat, and to what."""
    iso.lua("vim.g.hot_reload_chat = nil")
    press_in_chat("]", "]")
    time.sleep(0.3)
    return probe("chat")


try:
    iso.start()
    app = iso.tmp / "src" / "app"
    app.mkdir(parents=True)
    git("init", "-q", str(app))
    git("-C", str(app), "remote", "add", "origin", "git@github.com:Acme/app.git")
    rc, a0, err = run("spawn", "--acp", "--repo", str(app), "--name", "alpha", "hello alpha")
    check(a0 == "acme/app/a0", "an ACP agent", (rc, a0, err))
    iso.wait(lambda: turn_ends() >= 1, "a0's first turn", 30)
    iso.cli("open", a0)
    iso.wait(lambda: has("reply to: hello alpha"), "a0's chat")
    send("run seq 1 40", "ran: seq 1 40")
    send("think", "thought about it")
    send("after the run", "reply to: after the run")

    print("# a chat, a composer, a surface view and the sidebar open")
    (iso.tmp / "work" / "acme" / "app" / "iso" / "notes.md").write_text("---\nname: Notes\n---\n\nThe plan.\n")
    iso.wait(lambda: iso.lua("return vim.iter(require('isovim.surfaces').list('acme/app')):find(function(e)"
                             " return e.name == 'notes' end) ~= nil"), "the surface", 15)
    iso.lua("require('isovim.surface_view').open(vim.iter(require('isovim.surfaces').list('acme/app')):find(function(e)"
            " return e.name == 'notes' end))")
    lines = chat()
    run_row = lines.index(f"{DOT} Bash(seq 1 40)")
    thought_row = next(i for i, line in enumerate(lines) if line.startswith("✻ Thought"))
    iso.lua("local chat = require('isovim.acp.chat') chat.set_open('acme/app', 'a0', ..., true)", run_row)
    lines = chat()
    thought_row = next(i for i, line in enumerate(lines) if line.startswith("✻ Thought"))
    iso.lua("local chat = require('isovim.acp.chat') chat.set_open('acme/app', 'a0', ..., true)", thought_row)
    lines = chat()
    check("     40" in lines and "pondering the question" in "".join(lines), "the run's output and the thought opened", lines[-30:])
    iso.lua("require('isovim.acp.chat').focus_composer('acme/app', 'a0')")
    iso.type("half typed")
    iso.wait(lambda: composer() == ["half typed"], "the half-typed text")
    iso.lua("vim.cmd.stopinsert() vim.api.nvim_set_current_win(...)"
            " vim.fn.winrestview({ topline = 12, lnum = 20, col = 0 })", chat_win())
    view = view_of_chat()
    check(view["topline"] == 12 and view["lnum"] == 20, "the chat scrolled up, away from its end", view)
    before_autocmds = autocmds()
    check(iso.sidebar_win() is not None and probe("chat") is None, "the sidebar is open, and nothing has set a probe yet")
    iso.screenshot("before")

    print("\n# an edit in acp/ and at the top, through the watcher")
    n = len(iso.toasts())
    edit("lua/isovim/acp/chat.lua", "local function jump(chat, dir, mine)\n",
         "local function jump(chat, dir, mine)\n  vim.g.hot_reload_chat = \"v2\"\n")
    edit("lua/isovim/acp/chat.lua", "local function recall(chat, dir)\n",
         "local function recall(chat, dir)\n  vim.g.hot_reload_composer = \"v2\"\n")
    edit("lua/isovim/surface_view.lua", "function M.submit(view)\n", "function M.submit(view)\n  vim.g.hot_reload_view = \"v2\"\n")
    edit("lua/isovim/sidebar.lua", "  isovim_toggle_expand = function(item)\n",
         "  isovim_toggle_expand = function(item)\n    vim.g.hot_reload_sidebar = \"v2\"\n")
    toast = toasts_after(n, "the reload's toast", lambda t: t.startswith("isovim reload"))
    check(toast == "isovim reloaded: acp/chat.lua, sidebar.lua, surface_view.lua", "it reloads, naming the files", toast)
    time.sleep(1.5)
    check(len(reloads_after(n)) == 1, "once", reloads_after(n))
    check(chat() == lines, "the chat draws the same lines, the opened tool call and thought still open",
          [line for line in chat() if line not in lines][:5] or chat()[-10:])
    after = view_of_chat()
    check((after["topline"], after["lnum"]) == (12, 20), "its window is where it was scrolled", after)
    check(composer() == ["half typed"], "the composer keeps its text", composer())
    check(autocmds() == before_autocmds, "no autocmd on the chat or composer twice", (before_autocmds, autocmds()))
    check(chat_probe() == "v2", "]] in the open chat runs the new code")
    iso.lua("require('isovim.acp.chat').focus_composer('acme/app', 'a0')")
    iso.keys("Up")
    check(iso.wait(lambda: probe("composer"), "the composer's <Up>") == "v2", "<Up> in the open composer runs the new code")
    check(composer() == ["half typed"], "and leaves its text", composer())
    iso.keys("Escape")
    iso.lua("vim.api.nvim_set_current_win(vim.fn.bufwinid(require('isovim.surface_view').views['acme/app/notes'].input))")
    iso.keys("Enter")
    check(iso.wait(lambda: probe("view"), "the view's <CR>") == "v2", "<CR> in the open surface view's input box runs the new code")
    iso.focus_sidebar()
    iso.lua("vim.api.nvim_win_set_cursor(0, { 1, 0 })")
    iso.keys("Tab")
    check(iso.wait(lambda: probe("sidebar"), "the sidebar's <Tab>") == "v2", "<Tab> in the sidebar runs the new code")
    iso.keys("Tab")
    iso.screenshot("after")

    print("\n# starter/")
    n = len(iso.toasts())
    edit("starter/lua/plugins/isovim.lua", "return {\n", "-- touched by the pilot\nreturn {\n")
    edit("starter/lua/config/keymaps.lua", "-- Loaded after", "vim.g.hot_reload_keymaps = \"v2\"\n-- Loaded after")
    toast = toasts_after(n, "the starter toast", lambda t: "starter/" in t)
    check("starter/ changed (lua/plugins/isovim.lua): restart to apply" in toast, "a starter/ change says to restart", toast)
    check("starter/lua/config/keymaps.lua ran again" in toast and probe("keymaps") == "v2", "config/keymaps.lua runs again", toast)
    check(not reloads_after(n), "and isovim's modules aren't reloaded for it", reloads_after(n))

    print("\n# code that fails keeps the old")
    n = len(iso.toasts())
    iso.lua("require('isovim.acp.chat').old_code = true")
    look = (SRC / "lua/isovim/acp/look.lua").read_text()
    (SRC / "lua/isovim/acp/look.lua").write_text(look + "\nthis is not lua\n")
    toast = toasts_after(n, "the failed reload's toast", lambda t: t.startswith("isovim reload"))
    check(toast.startswith("isovim reload failed, kept the old code:") and "look.lua" in toast, "a syntax error keeps the old code and says so", toast)
    check(iso.lua("return require('isovim.acp.chat').old_code") is True and chat_probe() == "v2",
          "the old modules stay loaded, and the chat's keys work", probe("chat"))
    n = len(iso.toasts())
    (SRC / "lua/isovim/acp/look.lua").write_text("error('look fails as it loads')\n" + look)
    toast = toasts_after(n, "the second failed reload's toast", lambda t: t.startswith("isovim reload"))
    check(toast.startswith("isovim reload failed, kept the old code:") and "look fails as it loads" in toast,
          "a module that fails as it loads keeps the old code too", toast)
    check(chat_probe() == "v2" and composer() == ["half typed"] and chat() == lines,
          "the chat is made again by the old code, as it was", (probe("chat"), composer()))
    n = len(iso.toasts())
    (SRC / "lua/isovim/acp/look.lua").write_text(look)
    toast = toasts_after(n, "the fixed reload's toast", lambda t: t.startswith("isovim reload"))
    check(toast == "isovim reloaded: acp/look.lua" and iso.lua("return require('isovim.acp.chat').old_code") is None,
          "fixed, it reloads", toast)

    print("\n# a git pull")
    git("add", "-A", cwd=SRC)
    git("commit", "-q", "-m", "the edits", cwd=SRC)
    up = iso.tmp / "upstream"
    git("clone", "-q", str(SRC), str(up))
    text = (up / "lua/isovim/acp/chat.lua").read_text()
    (up / "lua/isovim/acp/chat.lua").write_text(text.replace('hot_reload_chat = "v2"', 'hot_reload_chat = "v3"'))
    for rel in ("lua/isovim/acp/queue.lua", "lua/isovim/sidebar.lua", "lua/isovim/init.lua", "starter/lua/plugins/isovim.lua"):
        (up / rel).write_text((up / rel).read_text() + "-- pulled\n")
    (up / "lua/isovim/extra").mkdir()
    (up / "lua/isovim/extra/probe.lua").write_text("return {}\n")
    git("add", "-A", cwd=up)
    git("commit", "-q", "-m", "upstream", cwd=up)
    n = len(iso.toasts())
    git("pull", "-q", "--ff-only", str(up), "main", cwd=SRC)
    toast = toasts_after(n, "the pull's toast", lambda t: t.startswith("isovim reload"))
    time.sleep(2)
    check(len(reloads_after(n)) == 1, "a pull of many files reloads once", reloads_after(n))
    check(toast.startswith("isovim reloaded: 5 files") and "starter/ changed (lua/plugins/isovim.lua): restart to apply" in toast,
          "naming how many, with the restart note for starter/", toast)
    check(chat_probe() == "v3" and composer() == ["half typed"], "the open chat runs the pulled code", probe("chat"))
finally:
    iso.stop()

print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
