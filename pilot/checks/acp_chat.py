"""ACP agents in the TUI, with pilot/fake-acp-agent as the adapter: opening one shows its chat, drawn
from its journal (prompts, the agent's streamed text, each tool call one line updated in place), and
a composer below it whose Enter sends to the agent's supervisor over its socket; two agents side by
side keep their own chats; a message from another agent while you type in a composer goes in through
the socket and never touches what you typed; a prompt you send while the agent works shows in the queue
window between the chat and the composer and goes once the turn ends; a permission asked in the Inbox and denied there shows as lines; the chat's keys (]] [[ over
your own prompts, ]m [m over any message, za zo zc a tool call's folded output, gf, i to the
composer) and the composer's (<C-k> to the chat, <Up> <Down> your earlier prompts, <M-CR> a new
line and <C-j> not one, <C-c> cancels the turn) work; and closing the TUI leaves the
agents running (they keep working with it closed), and reopening it rebuilds each chat as it was.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/acp_chat.py"""

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

BIN = str(REPO / "bin" / "iso")
DOT = "⏺" if sys.platform == "darwin" else "●"
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


def git(*args):
    subprocess.run(["git", *args], check=True, capture_output=True)


iso = Iso("acp_chat", agent_delay=0.3)
iso.env["ISOVIM_SELF"] = "pilothost"


def run(*args, timeout=60):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def journal(agent):
    path = iso.tmp / "work" / "acme" / "app" / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def state(agent):
    path = iso.tmp / "home" / "run" / "acme+app" / f"{agent}.state"
    return path.read_text().strip() if path.exists() else None


def adapters():
    path = Path(iso.env["FAKE_ACP_LOG"])
    return [json.loads(line) for line in path.read_text().splitlines() if '"started"' in line] if path.exists() else []


def chat(agent):
    """The agent's chat lines, or None when it has no chat open."""
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', ...)"
                   " return c and vim.api.nvim_buf_get_lines(c.buf, 0, -1, false) or vim.NIL", agent)


def composer(agent):
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', ...)"
                   " return c and vim.api.nvim_buf_get_lines(c.composer, 0, -1, false) or vim.NIL", agent)


def on_screen(agent):
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', ...)"
                   " return c ~= nil and vim.fn.bufwinid(c.buf) ~= -1 and vim.fn.bufwinid(c.composer) ~= -1", agent)


def queued(agent):
    """The lines of the agent's queue window, or None while it shows none."""
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', ...)"
                   " local w = c and require('isovim.acp.queue').window(c)"
                   " return w and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false) or vim.NIL", agent)


def in_composer(agent):
    return iso.lua("return vim.b.isovim_composer == true and vim.b.isovim_agent == ...", agent)


def soon(fn, timeout=3):
    """Whether fn() turns true within a few seconds (keys can take a moment to land)."""
    try:
        return bool(iso.wait(fn, "a key's effect", timeout))
    except AssertionError:
        return False


def said(agent, text):
    """Whether the agent's journal has it saying text (one chunk)."""
    return any(e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk"
               and e["update"]["content"].get("text") == text for e in journal(agent))


def has(agent, text):
    return any(text in line for line in (chat(agent) or []))


try:
    iso.start()
    app = iso.tmp / "src" / "app"
    app.mkdir(parents=True)
    git("init", "-q", str(app))
    git("-C", str(app), "remote", "add", "origin", "git@github.com:Acme/app.git")
    a0 = run("spawn", "--acp", "--repo", str(app), "--name", "alpha", "hello alpha")[1]
    a1 = run("spawn", "--acp", "--repo", str(app), "--name", "beta")[1]
    check((a0, a1) == ("acme/app/a0", "acme/app/a1"), "two ACP agents", (a0, a1))
    iso.wait(lambda: any(e["kind"] == "turn" and e["state"] == "end" for e in journal("a0")), "a0's first turn")

    print("# the chat and its composer")
    iso.cli("open", a0)
    iso.wait(lambda: has("a0", "reply to: hello alpha"), "a0's chat drawn from its journal")
    lines = chat("a0")
    check("❯ hello alpha" in lines, "the prompt shows", lines)
    check(lines.count(f"{DOT} Read(notes.md)") == 1, "the tool call is one line, updated in place", lines)
    check(on_screen("a0") and in_composer("a0") and iso.mode() == "i", "the composer is below it, in insert mode",
          (on_screen("a0"), in_composer("a0"), iso.mode()))
    iso.type("first from the composer")
    iso.keys("Enter")
    iso.wait(lambda: has("a0", "reply to: first from the composer"), "the composer's prompt answered")
    check(composer("a0") == [""], "Enter sends and empties the composer", composer("a0"))
    check(any(e["kind"] == "prompt" and e["text"] == "first from the composer" and not e.get("from") for e in journal("a0")),
          "it reached the agent as your prompt (no sender)", [e for e in journal("a0") if e["kind"] == "prompt"])

    print("\n# two agents side by side")
    iso.lua("local c = require('isovim.acp.chat').get('acme/app', 'a0')"
            " local w = vim.api.nvim_open_win(c.buf, true, { split = 'right', win = vim.fn.bufwinid(c.buf) })"
            " require('isovim').open('acme/app', 'a1', w)")
    iso.wait(lambda: on_screen("a0") and on_screen("a1"), "both chats and composers on screen")
    check(in_composer("a1"), "a1's composer has focus")
    run("send", a1, "beta says hi")
    iso.wait(lambda: has("a1", "reply to: beta says hi"), "a1's chat")
    check(not has("a0", "beta says hi"), "a0's chat doesn't get a1's turn")
    iso.screenshot("side-by-side")

    print("\n# a message while you type")
    iso.lua("require('isovim.acp.chat').focus_composer('acme/app', 'a0')")
    iso.wait(lambda: in_composer("a0") and iso.mode() == "i", "a0's composer focused")
    iso.type("half typed")
    iso.wait(lambda: composer("a0") == ["half typed"], "the half-typed text")
    run("send", a1, f"run {BIN} worker msg {a0} ping-from-beta")
    iso.wait(lambda: has("a0", "reply to: [from pilothost:acme/app/a1"), "beta's message answered in a0's chat", 20)
    check(any(line.startswith("❯ [from pilothost:acme/app/a1 · m") and "ping-from-beta" in line for line in chat("a0")),
          "the stamped message shows as a prompt in a0's chat", chat("a0")[-8:])
    check(composer("a0") == ["half typed"], "what you typed is untouched", composer("a0"))
    check(in_composer("a0") and iso.mode() == "i", "and you're still typing there", (in_composer("a0"), iso.mode()))
    iso.type(" and finished")
    iso.keys("Enter")
    iso.wait(lambda: has("a0", "reply to: half typed and finished"), "your prompt answered")
    prompts = [e["text"] for e in journal("a0") if e["kind"] == "prompt"]
    check(prompts[-1] == "half typed and finished" and "ping-from-beta" in prompts[-2], "the two arrived as separate prompts", prompts)

    print("\n# a prompt while it works")
    run("send", a0, "slow 2")
    iso.wait(lambda: state("a0") == "working", "a0 working")
    iso.type("while busy")
    iso.keys("Enter")
    iso.wait(lambda: queued("a0") == ["#1 while busy"], "shown in the queue window")
    check(not any(e["kind"] == "prompt" and e["text"] == "while busy" for e in journal("a0")), "not sent during the turn")
    iso.wait(lambda: has("a0", "reply to: while busy"), "sent and answered after the turn", 20)
    lines = chat("a0")
    check(soon(lambda: queued("a0") is None), "the queue window gives way to the prompt", queued("a0"))
    check(lines.index("❯ while busy") > lines.index(f"{DOT} reply to: slow 2"), "after the turn it waited on", lines[-10:])

    print("\n# a denied permission")
    run("send", a1, "perm")
    asked = iso.wait(lambda: next((e for e in journal("a1") if e["kind"] == "permission" and e["decision"] == "asked"), None),
                     "the permission asked in the Inbox")
    iso.wait(lambda: has("a1", " Bash command") and has("a1", "   rm -rf build") and has("a1", "   2. No"),
             "the chat shows Claude's box, waiting on you")
    rc, _, err = run("answer", asked["name"], "deny")
    check(rc == 0, "iso answer denies it", err)
    iso.wait(lambda: has("a1", "permission: reject"), "the permission answered")
    check(soon(lambda: has("a1", "  ⎿  Denied by you · Bash: rm -rf build won't run") and not has("a1", " Bash command")),
          "the box gives way to saying it was denied", chat("a1"))
    iso.screenshot("chats")

    print("\n# chat keys")
    # In a0's chat, at its end, in normal mode.
    iso.keys("Escape")
    iso.keys("C-k")
    check(iso.lua("return vim.b.isovim_acp == true and vim.b.isovim_agent") == "a0" and iso.mode() == "n",
          "<C-k> in the composer goes to the chat", (iso.current_buffer(), iso.mode()))
    iso.lua("vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })")
    seen = []
    for _ in range(5):
        iso.keys("[", "[")
        seen.append(iso.lua("return vim.api.nvim_get_current_line()"))
    check(seen == ["❯ while busy", "❯ half typed and finished", "❯ first from the composer", "❯ hello alpha", "❯ hello alpha"],
          "[[ walks back over your own prompts only (not iso send's or another agent's)", seen)
    iso.keys("]", "]")
    check(iso.lua("return vim.api.nvim_get_current_line()") == "❯ first from the composer", "]] goes forward", iso.lua("return vim.api.nvim_get_current_line()"))
    iso.keys("]", "m")
    check(iso.lua("return vim.api.nvim_get_current_line()") == f"{DOT} reply to: first from the composer", "]m stops at the agent's message too",
          iso.lua("return vim.api.nvim_get_current_line()"))
    iso.keys("]", "m")
    line = iso.lua("return vim.api.nvim_get_current_line()")
    check(line.startswith("❯ [from pilothost:acme/app/a1"), "and at another agent's message", line)
    iso.keys("[", "m")
    check(iso.lua("return vim.api.nvim_get_current_line()") == f"{DOT} reply to: first from the composer", "[m goes back")

    # A tool call's output is collapsed to its first line under it until za opens it.
    (iso.tmp / "work" / "acme" / "app" / "a0" / "notes.txt").write_text("the notes\n")
    run("send", a0, "run echo notes.txt; seq 1 6")
    iso.wait(lambda: has("a0", f"{DOT} ran: echo notes.txt; seq 1 6"), "the run's tool call")
    row = iso.lua(f"for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do if l == '{DOT} Bash(echo notes.txt; seq 1 6)' then return i end end")
    check(row and chat("a0")[row] == "  ⎿  notes.txt", "its output is under its line", chat("a0")[row - 1:row + 2] if row else chat("a0")[-6:])
    iso.lua("vim.api.nvim_win_set_cursor(0, { ..., 0 })", row)
    folded = lambda: chat("a0")[row + 3] == "     … +4 lines (za to expand)"  # noqa: E731
    check(folded() and chat("a0")[row + 1:row + 3] == ["     1", "     2"] and chat("a0")[row + 4] == "",
          "collapsed at first: its first lines and how many more", chat("a0")[row - 1:row + 5])
    iso.keys("z", "o")
    check(soon(lambda: not folded()), "zo opens it", chat("a0")[row - 1:row + 3])
    iso.lua("vim.api.nvim_win_set_cursor(0, { ... + 2, 0 })", row)
    iso.keys("z", "c")
    check(soon(lambda: folded()), "zc on its output closes it", chat("a0")[row - 1:row + 3])
    check(iso.lua("return vim.api.nvim_win_get_cursor(0)[1]") == row + 2, "leaving the cursor on what's left of it")
    iso.keys("z", "a")
    check(soon(lambda: not folded()), "za toggles it")
    iso.lua("vim.api.nvim_win_set_cursor(0, { ... + 2, 0 })", row)
    iso.keys("z", "a")
    check(soon(lambda: folded()), "za on its output closes it again")
    bare = iso.lua("for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do"
                   f" if l == '{DOT} Read(notes.md)' then return i end end")
    iso.lua("vim.api.nvim_win_set_cursor(0, { ..., 0 })", bare)
    iso.lua("vim.v.errmsg = ''")
    before = chat("a0")
    iso.keys("z", "a")
    check(soon(lambda: iso.lua("return vim.fn.mode()") == "n") and iso.lua("return vim.v.errmsg") == ""
          and iso.lua("return vim.api.nvim_win_get_cursor(0)[1]") == bare and chat("a0") == before,
          "za on a tool call without output does nothing", iso.lua("return vim.v.errmsg"))
    iso.lua("vim.api.nvim_win_set_cursor(0, { ... + 1, 8 })", row)
    iso.keys("g", "f")
    check(iso.lua("return vim.api.nvim_buf_get_name(0)").endswith("a0/notes.txt"), "gf opens the file on the line beside the chat",
          iso.lua("return vim.api.nvim_buf_get_name(0)"))
    iso.lua("vim.cmd('close')")
    iso.lua("vim.api.nvim_set_current_win(vim.fn.bufwinid(require('isovim.acp.chat').get('acme/app', 'a0').buf))")
    iso.keys("i")
    check(in_composer("a0") and iso.mode() == "i", "i in the chat goes to the composer, typing", (in_composer("a0"), iso.mode()))

    # <Up>/<Down> walk your earlier prompts while the composer is empty.
    iso.keys("Up")
    check(composer("a0") == ["while busy"], "<Up> brings back your last prompt", composer("a0"))
    iso.keys("Up")
    check(composer("a0") == ["half typed and finished"], "and the one before", composer("a0"))
    iso.keys("Down")
    check(composer("a0") == ["while busy"], "<Down> comes forward", composer("a0"))
    iso.keys("Down")
    check(composer("a0") == [""], "and past the last, empty again", composer("a0"))
    iso.type("two")
    iso.keys("C-j")
    iso.keys("M-Enter")
    iso.type("lines")
    blink = iso.lua("local ok, b = pcall(require, 'blink.cmp') if not ok then return vim.NIL end"
                    " return { visible = b.is_visible(), enabled = require('blink.cmp.config').enabled() }")
    check(blink is not None and not blink["visible"] and not blink["enabled"], "no completion menu in the composer", blink)
    check(composer("a0") == ["two", "lines"], "<M-CR> is a new line, <C-j> nothing, neither a send", composer("a0"))
    iso.keys("Up")
    check(composer("a0") == ["two", "lines"], "<Up> in text you typed only moves", composer("a0"))
    iso.lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, { '' })")

    # <C-c> cancels the turn.
    run("send", a0, "slow 10")
    iso.wait(lambda: state("a0") == "working", "a0 working on the slow one")
    iso.keys("C-c")
    iso.wait(lambda: has("a0", "  ⎿  Interrupted · What should Claude do instead?"), "the turn cancelled")
    check(any(e["kind"] == "turn" and e.get("stopReason") == "cancelled" for e in journal("a0")), "<C-c> sent session/cancel")
    iso.wait(lambda: state("a0") == "idle", "a0 idle after the cancel")

    print("\n# closing and reopening the TUI")
    iso.wait(lambda: state("a0") == "idle" and state("a1") == "idle", "both idle")
    before = {agent: chat(agent) for agent in ("a0", "a1")}
    started = len(adapters())
    iso.close_tui()
    sessions = subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], "list-sessions", "-F", "#{session_name}"],
                              capture_output=True, text=True).stdout.split()
    check({"iso2-acme+app+a0", "iso2-acme+app+a1"} <= set(sessions), "the agents keep running with the TUI closed", sessions)
    rc, _, err = run("send", a0, "while closed")
    check(rc == 0, "and take prompts", err)
    iso.wait(lambda: said("a0", "while closed"), "answered with the TUI closed")
    iso.start()
    iso.cli("open", a0)
    iso.wait(lambda: has("a0", "reply to: while closed"), "a0's chat rebuilt")
    after = chat("a0")
    check(after[:len(before["a0"])] == before["a0"], "it's the same chat as before, line for line",
          [x for x in zip(before["a0"], after) if x[0] != x[1]][:3])
    check(after.index("❯ while closed") >= len(before["a0"]), "with what happened while closed after it")
    iso.cli("open", a1)
    iso.wait(lambda: chat("a1") is not None and has("a1", "permission: reject"), "a1's chat rebuilt")
    check(chat("a1") == before["a1"], "a1's too", (before["a1"][-4:], chat("a1")[-4:]))
    check(len(adapters()) == started, "no adapter was restarted", (started, len(adapters())))
    iso.type("after reopening")
    iso.keys("Enter")
    iso.wait(lambda: has("a1", "reply to: after reopening"), "the composer works after reopening")
    iso.screenshot("reopened")
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
