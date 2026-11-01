"""An ACP agent's prompt queue on screen by itself, with pilot/fake-acp-agent as the adapter: two prompts
queued while a turn runs open a window between the chat and the composer showing both, titled
"queued · 2" and sized to them, the composer keeping its height and the chat no longer drawing them;
<C-j> and <C-k> walk chat → queue → composer and back (<C-j> in the composer does nothing, <M-CR> is
a new line there, the hint says <C-k> goes to the queue); editing the queue and :w still works, a
prompt queued meanwhile neither redraws what you're editing nor is lost by the write; the window
closes when the queue drains, handing focus to the composer; it survives the layout: reopening the
agent, another agent taking the window and coming back, another workspace and back, the chat closed
and reopened, and the TUI restarted each leave exactly one queue window between that chat and its
composer and none of another's; q hides it until another prompt queues; and <leader>iq opens it
even when empty, a line written there is sent, and leaving it empty closes it.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/acp_queue.py"""

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

BIN = str(REPO / "bin" / "iso")
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


def git(*args):
    subprocess.run(["git", *args], check=True, capture_output=True)


iso = Iso("acp_queue", agent_delay=0.3)
iso.env["ISOVIM_SELF"] = "pilothost"


def run(*args, timeout=60):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def journal(agent, ws=("acme", "app")):
    path = iso.tmp / "work" / ws[0] / ws[1] / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def state(agent):
    path = iso.tmp / "home" / "run" / "acme+app" / f"{agent}.state"
    return path.read_text().strip() if path.exists() else None


def soon(fn, timeout=5):
    try:
        return bool(iso.wait(fn, "a change", timeout))
    except AssertionError:
        return False


def turn_done(agent, text):
    entries = journal(agent)
    ids = [e["id"] for e in entries if e["kind"] == "prompt" and e["text"] == text]
    return ids and any(e["kind"] == "turn" and e["state"] == "end" and e["id"] == ids[-1] for e in entries)


CHAT = "local c = require('isovim.acp.chat').get('acme/app', ...) "


def chat(agent="a0"):
    return iso.lua(CHAT + "return c and vim.api.nvim_buf_get_lines(c.buf, 0, -1, false) or vim.NIL", agent)


def qwin(agent="a0"):
    """The queue window between the agent's chat and composer, or None."""
    return iso.lua(CHAT + "return c and require('isovim.acp.queue').window(c) or vim.NIL", agent)


def qbuf(agent="a0"):
    return iso.lua("for b, q in pairs(_G.isovim_acp_queues) do"
                   " if vim.api.nvim_buf_is_valid(b) and q.agent == ... then return b end end return vim.NIL", agent)


def qlines(agent="a0"):
    buf = qbuf(agent)
    return iso.lua("return vim.api.nvim_buf_get_lines(..., 0, -1, false)", buf) if buf else None


def queue_windows(agent="a0"):
    """Every window showing the agent's queue buffer."""
    buf = qbuf(agent)
    return iso.lua("return vim.fn.win_findbuf(...)", buf) if buf else []


def column(agent="a0"):
    """The chat's, the queue's and the composer's windows: their top rows and heights (winbar in)."""
    return iso.lua(CHAT + """
      local function at(win)
        if not win or win == -1 then return vim.NIL end
        return { win = win, row = vim.api.nvim_win_get_position(win)[1], col = vim.api.nvim_win_get_position(win)[2],
          height = vim.api.nvim_win_get_height(win) }
      end
      return { chat = at(vim.fn.bufwinid(c.buf)), queue = at(require('isovim.acp.queue').window(c)),
        composer = at(vim.fn.bufwinid(c.composer)) }""", agent)


def between(agent="a0"):
    """The queue window sits right under the chat and right over the composer, in their column."""
    c = column(agent)
    if not (c["chat"] and c["queue"] and c["composer"]):
        return False
    ch, q, co = c["chat"], c["queue"], c["composer"]
    return (ch["row"] + ch["height"] + 1 == q["row"] and q["row"] + q["height"] + 1 == co["row"]
            and ch["col"] == q["col"] == co["col"])


def editing_windows():
    """The windows outside the sidebar, by what they show."""
    return iso.lua("""local out = {}
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if not require('isovim').is_sidebar(w) then
          local b = vim.api.nvim_win_get_buf(w)
          out[#out + 1] = vim.b[b].isovim_queue and ('queue:' .. _G.isovim_acp_queues[b].agent)
            or vim.b[b].isovim_composer and ('composer:' .. vim.b[b].isovim_agent)
            or vim.b[b].isovim_acp and ('chat:' .. vim.b[b].isovim_agent) or vim.api.nvim_buf_get_name(b)
        end
      end
      table.sort(out)
      return out""")


def current():
    return iso.lua("local b = vim.api.nvim_get_current_buf()"
                   " return vim.b[b].isovim_queue and 'queue' or vim.b[b].isovim_composer and 'composer'"
                   " or vim.b[b].isovim_acp and 'chat' or vim.bo[b].filetype")


def winbar(win):
    return iso.lua("return vim.wo[...].winbar", win)


def hint(agent="a0"):
    return iso.lua(CHAT + """local ns = vim.api.nvim_get_namespaces().isovim_acp_composer
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(c.composer, ns, 0, -1, { details = true })) do
        local lines = m[4].virt_lines
        if lines and lines[2] then return lines[2][1][1] end
      end""", agent)


def composer_lines(agent="a0"):
    return iso.lua(CHAT + "return vim.api.nvim_buf_get_lines(c.composer, 0, -1, false)", agent)


def queue():
    return [i["text"] for i in iso.lua("local ok, r = require('isovim.acp').call('acme/app', 'a0', 'queue') return r")["items"]]


def busy(seconds):
    run("send", a0, f"slow {seconds}")
    iso.wait(lambda: state("a0") == "working", "a0 working")


def column_ok(what, agent="a0"):
    check(soon(lambda: between(agent) and len(queue_windows(agent)) == 1), what, (column(agent), editing_windows()))


try:
    iso.start()
    app = iso.tmp / "src" / "app"
    app.mkdir(parents=True)
    git("init", "-q", str(app))
    git("-C", str(app), "remote", "add", "origin", "git@github.com:Acme/app.git")
    lib = iso.tmp / "src" / "lib"
    lib.mkdir(parents=True)
    git("init", "-q", str(lib))
    git("-C", str(lib), "remote", "add", "origin", "git@github.com:Acme/lib.git")
    a0 = run("spawn", "--acp", "--repo", str(app), "--name", "alpha", "hello alpha")[1]
    a1 = run("spawn", "--acp", "--repo", str(app), "--name", "beta")[1]
    l0 = run("spawn", "--acp", "--repo", str(lib), "--name", "gamma")[1]
    check((a0, a1, l0) == ("acme/app/a0", "acme/app/a1", "acme/lib/a0"), "three ACP agents, two repos", (a0, a1, l0))
    iso.wait(lambda: turn_done("a0", "hello alpha"), "a0's first turn")
    iso.cli("open", a0)
    iso.wait(lambda: any("reply to: hello alpha" in line for line in chat() or []), "a0's chat")
    composer_height = column()["composer"]["height"]

    print("\n# two prompts queued while a turn runs")
    busy(6)
    check(qwin() is None and qbuf() is None, "nothing queued: no queue window", editing_windows())
    iso.wait(lambda: current() == "composer" and iso.mode() == "i", "typing in the composer")
    for text in ("q one", "q two"):
        iso.type(text)
        iso.keys("Enter")
    iso.wait(lambda: qwin() is not None, "the queue window opens by itself")
    check(soon(lambda: qlines() == ["#1 q one", "#2 q two"]), "it shows both, one a line", qlines())
    column_ok("between the chat and the composer, in their column")
    win = qwin()
    check("queued · 2" in winbar(win), "titled queued · 2", winbar(win))
    check(column()["queue"]["height"] == 3, "sized to its two lines (and its title)", column()["queue"])
    check(column()["composer"]["height"] == composer_height, "the composer keeps its height", (column(), composer_height))
    check(not any("(queued)" in line for line in chat()), "the chat doesn't draw them again", chat()[-4:])
    check(current() == "composer" and iso.mode() == "i", "you're still typing in the composer", (current(), iso.mode()))
    check("<C-k> the queue" in (hint() or ""), "the composer's hint says <C-k> goes to the queue", hint())
    print("screenshot:", iso.screenshot("queue"))

    print("\n# <C-j> / <C-k> walk the column")
    scope = iso.lua("return require('isovim').current_scope")
    iso.keys("C-k")
    check(soon(lambda: current() == "queue" and iso.mode() == "n"), "<C-k> in the composer's insert mode: up to the queue",
          (current(), iso.mode()))
    iso.keys("C-k")
    check(soon(lambda: current() == "chat"), "<C-k> in the queue: up to the chat", current())
    iso.keys("C-j")
    check(soon(lambda: current() == "queue"), "<C-j> in the chat: down to the queue", current())
    iso.keys("C-j")
    check(soon(lambda: current() == "composer" and iso.mode() == "i"), "<C-j> in the queue: down to the composer, typing",
          (current(), iso.mode()))
    iso.type("ab")
    iso.keys("C-j")
    time.sleep(0.3)
    check(current() == "composer" and composer_lines() == ["ab"], "<C-j> in the composer stays, adding nothing", composer_lines())
    iso.keys("M-Enter")
    iso.type("cd")
    check(soon(lambda: composer_lines() == ["ab", "cd"]), "<M-CR> is a new line there", composer_lines())
    iso.lua(CHAT + "vim.api.nvim_buf_set_lines(c.composer, 0, -1, false, { '' })", "a0")
    iso.keys("Escape")
    iso.keys("C-j")
    check(soon(lambda: current() == "composer") and iso.mode() == "n", "<C-j> in the composer's normal mode stays too", current())
    iso.keys("C-k")
    check(soon(lambda: current() == "queue"), "<C-k> in its normal mode: up to the queue", current())
    listed = iso.lua(CHAT + "return { vim.bo[c.composer].buflisted, vim.bo[select(2, ...)].buflisted }", "a0", qbuf())
    check(iso.lua("return require('isovim').current_scope") == scope and listed == [False, False],
          "the scope stays the chat's, and neither the queue nor the composer is listed as a buffer", (scope, listed))

    print("\n# editing it, with a prompt queuing meanwhile")
    buf = qbuf()
    iso.lua("vim.api.nvim_buf_set_lines(..., 0, -1, false, { '#2 q two edited', 'q three added' })", buf)
    run("send", a0, "q four")
    iso.wait(lambda: any(e["kind"] == "queued" and e["text"] == "q four" for e in journal("a0")), "q four queued")
    time.sleep(0.5)
    check(qlines() == ["#2 q two edited", "q three added"] and iso.lua("return vim.bo[...].modified", buf),
          "what you're editing isn't redrawn", qlines())
    check("queued · 3" in winbar(qwin()), "the title counts it", winbar(qwin()))
    iso.type(":w")
    iso.keys("Enter")
    check(soon(lambda: queue() == ["q two edited", "q three added", "q four"]),
          ":w makes it the queue, the prompt queued meanwhile kept after yours", queue())
    check(soon(lambda: qlines() == ["#1 q two edited", "#2 q three added", "#3 q four"]) and not iso.lua("return vim.bo[...].modified", buf),
          "the buffer shows the queue as written", qlines())
    column_ok("still between the chat and the composer, three lines tall")
    check(column()["queue"]["height"] == 4, "it grew to three lines", column()["queue"])

    print("\n# the queue drains")
    iso.wait(lambda: turn_done("a0", "q four"), "every queued prompt answered", 20)
    check(soon(lambda: qwin() is None and queue_windows() == []), "the queue window closes", editing_windows())
    check(current() == "composer", "focus goes to the composer", current())
    check(soon(lambda: column()["composer"]["height"] == composer_height), "which keeps its height", column())
    prompts = [e["text"] for e in journal("a0") if e["kind"] == "prompt"]
    check(prompts[-3:] == ["q two edited", "q three added", "q four"] and "q one" not in prompts, "sent as written", prompts[-4:])
    check("<C-k> the chat" in (hint() or ""), "the hint says <C-k> goes to the chat again", hint())

    print("\n# the layout around it")
    busy(30)
    run("send", a0, "r one")
    run("send", a0, "r two")
    iso.wait(lambda: qwin() is not None, "queued again, the window back")
    iso.cli("open", a0)
    time.sleep(0.5)
    column_ok("opening the agent again: still one queue window, between")
    iso.cli("open", a1)
    check(soon(lambda: queue_windows() == [] and editing_windows() == ["chat:a1", "composer:a1"]),
          "another agent in its window: a0's queue window goes with a0's composer", editing_windows())
    iso.cli("open", a0)
    column_ok("back to a0: its queue window is back")
    iso.cli("open", l0)
    check(soon(lambda: queue_windows() == [] and editing_windows() == ["chat:a0", "composer:a0"] and
               iso.lua("return require('isovim').current") == "acme/lib"),
          "another workspace: no a0 queue window left", editing_windows())
    iso.cli("open", a0)
    column_ok("its workspace again: the layout comes back with one queue window, between")
    check(editing_windows() == ["chat:a0", "composer:a0", "queue:a0"], "and nothing stray", editing_windows())
    check(column()["composer"]["height"] == composer_height, "the composer at its height", column())
    saved = iso.lua("return vim.json.encode(vim.g.isovim_layouts['acme/app'].tree)")
    check(f'"buf":{qbuf()}' not in saved.replace(" ", ""), "the saved layout leaves the queue window out", saved)
    iso.lua("require('isovim.acp.chat').close('acme/app', 'a0')")
    check(soon(lambda: queue_windows() == [] and qbuf() is None), "the chat closed: its queue goes too", editing_windows())
    iso.cli("open", a0)
    column_ok("reopened: the queue window is back")
    check(soon(lambda: qlines() == ["#1 r one", "#2 r two"]), "showing the queue", qlines())
    iso.close_tui()
    layout_json = (iso.tmp / "work" / "acme" / "app" / "iso" / "layout.json")
    check(layout_json.exists() and "queue" not in layout_json.read_text(), "layout.json has no queue in it",
          layout_json.read_text() if layout_json.exists() else None)
    iso.start()
    iso.wait(lambda: chat() is not None, "the TUI resumes a0's chat", 20)
    column_ok("after a restart: the queue window between the chat and the composer")
    check(editing_windows() == ["chat:a0", "composer:a0", "queue:a0"], "nothing stray", editing_windows())

    print("\n# q hides it until another prompt queues")
    iso.lua("vim.api.nvim_set_current_win(...)", qwin())
    iso.keys("Escape")
    iso.keys("q")
    check(soon(lambda: qwin() is None and current() == "composer"), "q hides it, back to the composer", (editing_windows(), current()))
    run("send", a0, "r three")
    check(soon(lambda: qwin() is not None and qlines() == ["#1 r one", "#2 r two", "#3 r three"]), "the next prompt brings it back",
          qlines())
    iso.lua("require('isovim.acp').call('acme/app', 'a0', 'queue_set', { items = {} })")
    check(soon(lambda: qwin() is None), "cleared, it closes")
    iso.lua(CHAT + "vim.api.nvim_set_current_win(vim.fn.bufwinid(c.composer))", "a0")
    iso.keys("Escape")
    iso.keys("C-c")
    iso.wait(lambda: state("a0") == "idle", "a0 idle after the cancel")

    print("\n# <leader>iq")
    iso.lua(CHAT + "vim.api.nvim_set_current_win(vim.fn.bufwinid(c.buf))", "a0")
    iso.keys("Space", "i", "q")
    check(soon(lambda: current() == "queue" and qlines() == [""]), "<leader>iq opens it empty, focused", (current(), qlines()))
    column_ok("between the chat and the composer")
    iso.keys("C-j")
    check(soon(lambda: current() == "composer" and qwin() is None), "left empty, it closes", editing_windows())
    iso.lua(CHAT + "vim.api.nvim_set_current_win(vim.fn.bufwinid(c.buf))", "a0")
    iso.keys("Escape")
    iso.keys("Space", "i", "q")
    iso.wait(lambda: current() == "queue", "the queue again")
    iso.keys("i")
    iso.type("by hand")
    iso.keys("Escape")
    iso.type(":w")
    iso.keys("Enter")
    iso.wait(lambda: turn_done("a0", "by hand"), "the line written there is sent", 15)
    check(soon(lambda: qwin() is None), "and once it's gone the window goes", editing_windows())
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
