"""The ACP chat's Claude look and what L1 added around it, with pilot/fake-acp-agent as the adapter:
the ⏺ ❯ ⎿ marks and their colors, tool output folded at first, a diff drawn with line numbers and
colored inline, Bash output streamed from terminal deltas with its exit code, thinking and a plan;
the agent's text streaming chunk by chunk through the supervisor's pushes (with the journal watch
off); the spinner above the composer while it works; the view following the bottom only when
you're there; the queue in its window between the chat and the composer, edited, reordered, cleared
and one prompt sent now (cancelling the turn), q hiding it;
@imports from the CLAUDE.md files in the session prompt; iso attach from a second nvim showing the
same chat and sending from it; and iso handover running claude --resume in the pane (a fake
claude), with what happened there put into the chat and the session reopened after.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/acp_chat_look.py"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import screenshot  # noqa: E402
from iso import OUT, REPO, Iso  # noqa: E402

BIN = str(REPO / "bin" / "iso")
DOT = "⏺" if sys.platform == "darwin" else "●"
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


def git(*args):
    subprocess.run(["git", *args], check=True, capture_output=True)


iso = Iso("acp_chat_look", agent_delay=0.3)
iso.env["ISOVIM_SELF"] = "pilothost"
iso.env["FAKE_STREAM_GAP"] = "0.4"

# Claude's config dir (CLAUDE.md, transcripts) and a fake claude for the handover, first on PATH.
config = iso.tmp / "claude-config"
config.mkdir()
iso.env["CLAUDE_CONFIG_DIR"] = str(config)
(config / "CLAUDE.md").write_text("# mine\n@RTK.md and `@not-this.md`\n```\n@nor-this.md\n```\n")
(config / "RTK.md").write_text("RTK SAYS HI\n@~/../../nonexistent.md\n@deeper.md\n")
(config / "deeper.md").write_text("DEEPER STILL\n")
(config / "not-this.md").write_text("NOT IMPORTED\n")
(config / "nor-this.md").write_text("NOR THIS\n")
fakebin = iso.tmp / "bin"
fakebin.mkdir()
(fakebin / "claude").write_text(f"""#!/usr/bin/env python3
import json, os, sys
argv = sys.argv[1:]
sid = argv[argv.index("--resume") + 1]
key = os.path.realpath(os.getcwd()).replace("/", "-").replace(".", "-")
project = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects", key)
os.makedirs(project, exist_ok=True)
json.dump({{"argv": argv, "acp": os.environ.get("ISOVIM_ACP"), "tty": os.isatty(0)}}, open({str(iso.tmp / "claude-ran.json")!r}, "w"))
rows = [
    {{"type": "user", "message": {{"role": "user", "content": "hello from claude's screen"}}}},
    {{"type": "assistant", "message": {{"content": [{{"type": "text", "text": "hi on claude's screen"}},
        {{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {{"command": "ls -la"}}}}]}}}},
    {{"type": "user", "message": {{"role": "user", "content": [{{"type": "tool_result", "tool_use_id": "toolu_1", "content": "total 0"}}]}}}},
    {{"type": "user", "isMeta": True, "message": {{"role": "user", "content": "meta, left out"}}}},
]
with open(os.path.join(project, sid + ".jsonl"), "a") as f:
    for row in rows:
        f.write(json.dumps(row) + "\\n")
print("FAKE CLAUDE ON SCREEN", flush=True)
sys.stdin.readline()
""")
(fakebin / "claude").chmod(0o755)
iso.env["PATH"] = f"{fakebin}:{iso.env['PATH']}"


def run(*args, timeout=60):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def journal(agent):
    path = iso.tmp / "work" / "acme" / "app" / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def state(agent):
    path = iso.tmp / "home" / "run" / "acme+app" / f"{agent}.state"
    return path.read_text().strip() if path.exists() else None


def frames():
    path = Path(iso.env["FAKE_ACP_LOG"])
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def chat(agent="a0"):
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', ...)"
                   " return c and vim.api.nvim_buf_get_lines(c.buf, 0, -1, false) or vim.NIL", agent)


def has(text, agent="a0"):
    return any(text in line for line in (chat(agent) or []))


def row_of(line, agent="a0"):
    lines = chat(agent) or []
    return lines.index(line) if line in lines else None


def hl_at(row, col=0, agent="a0"):
    """The highlight groups of the chat's extmarks covering (row, col), 0-based."""
    return iso.lua("""
      local c = require('isovim.acp.chat').get('acme/app', ...)
      local row, col = select(2, ...), select(3, ...)
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(c.buf, require('isovim.acp.chat').ns.hl, { row, 0 }, { row, -1 }, { details = true })) do
        local d = m[4]
        if d.line_hl_group then out[#out + 1] = d.line_hl_group end
        if d.hl_group and m[3] <= col and ((d.end_row or m[2]) > m[2] or (d.end_col or 0) > col) then out[#out + 1] = d.hl_group end
        if d.virt_text then out[#out + 1] = 'virt:' .. d.virt_text[1][1] end
      end
      return out""", agent, row, col)


def bar(agent="a0"):
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', ...)"
                   " local w = vim.fn.bufwinid(c.composer) return w ~= -1 and vim.wo[w].winbar or vim.NIL", agent)


def chat_win(agent="a0"):
    return iso.lua("return vim.fn.bufwinid(require('isovim.acp.chat').get('acme/app', ...).buf)", agent)


def call(name, payload=None, agent="a0"):
    return iso.lua("local ok, r = require('isovim.acp').call('acme/app', ...) return { ok, r }", agent, name, payload or {})


def soon(fn, timeout=5):
    try:
        return bool(iso.wait(fn, "a change", timeout))
    except AssertionError:
        return False


def turn_done(agent, text):
    entries = journal(agent)
    ids = [e["id"] for e in entries if e["kind"] == "prompt" and e["text"] == text]
    return ids and any(e["kind"] == "turn" and e["state"] == "end" and e["id"] == ids[-1] for e in entries)


try:
    iso.start()
    app = iso.tmp / "src" / "app"
    app.mkdir(parents=True)
    git("init", "-q", str(app))
    git("-C", str(app), "remote", "add", "origin", "git@github.com:Acme/app.git")
    # A project CLAUDE.md above the agent's dir, importing relative to itself.
    project = iso.tmp / "work" / "acme" / "app"
    (project / "docs").mkdir(parents=True)
    (project / "CLAUDE.md").write_text("project rules: see @docs/notes.md.\n")
    (project / "docs" / "notes.md").write_text("PROJECT NOTES\n")
    a0 = run("spawn", "--acp", "--repo", str(app), "--name", "alpha", "hello alpha")[1]
    check(a0 == "acme/app/a0", "an ACP agent", a0)
    iso.wait(lambda: turn_done("a0", "hello alpha"), "a0's first turn")

    print("# @imports in the session prompt")
    new = next(f["frame"] for f in frames() if f.get("frame", {}).get("method") == "session/new")
    appended = new["params"]["_meta"]["systemPrompt"]["append"]
    check("RTK SAYS HI" in appended and "DEEPER STILL" in appended and "PROJECT NOTES" in appended,
          "the files CLAUDE.md imports (and theirs, and the project's) are appended", appended[-400:])
    check("NOT IMPORTED" not in appended and "NOR THIS" not in appended, "not those in code spans or fenced blocks")
    check(appended.index("RTK SAYS HI") > appended.index("isovim") if "isovim" in appended else True, "after the role prompt")
    session = next(e for e in journal("a0") if e["kind"] == "session")
    check([Path(p).name for p in session.get("imports", [])] == ["RTK.md", "deeper.md", "notes.md"],
          "the journal names them", session.get("imports"))
    init = next(f["frame"] for f in frames() if f.get("frame", {}).get("method") == "initialize")
    check(init["params"]["clientCapabilities"].get("_meta") == {"terminal_output": True, "terminal_output_delta": True},
          "it asks for live terminal output", init["params"]["clientCapabilities"])

    print("\n# the look")
    iso.cli("open", a0)
    iso.wait(lambda: has(f"{DOT} reply to: hello alpha"), "a0's chat")
    lines = chat()
    r = row_of("❯ hello alpha")
    check(r is not None and "IsovimAcpPrompt" in hl_at(r, 4), "your prompt: ❯, colored", (r, hl_at(r) if r is not None else None))
    r = row_of(f"{DOT} Read(notes.md)")
    check(r is not None and "IsovimAcpToolDone" in hl_at(r, 0) and "IsovimAcpToolTitle" in hl_at(r, len(DOT.encode()) + 2),
          f"a finished tool call: green {DOT}, bold name", hl_at(r) if r is not None else lines)
    check(lines[r - 1] == "" and lines[r + 1] == "", "blocks are a blank line apart", lines[r - 1:r + 2])

    (iso.tmp / "work" / "acme" / "app" / "a0" / "src").mkdir(parents=True, exist_ok=True)
    run("send", a0, "diff")
    iso.wait(lambda: has(f"{DOT} edited src/app.lua"), "the diff turn")
    lines = chat()
    r = row_of(f"{DOT} Update(src/app.lua)")
    body = ["  ⎿  Added 2 lines, removed 1 line", "       1  local a = 1", "       2 -local b = 2",
            "       2 +local b = 20", "       3  local c = 3", "       4 +local d = 4", "       5  return a"]
    check(lines[r + 1:r + 8] == body, "the diff open under its summary, as Claude shows an edit", lines[r:r + 9])
    iso.lua("local c = require('isovim.acp.chat').get('acme/app', 'a0') local w = vim.fn.bufwinid(c.buf)"
            " vim.api.nvim_set_current_win(w) vim.cmd('stopinsert') vim.api.nvim_win_set_cursor(w, { ..., 0 })", r + 3)
    iso.keys("Escape")
    iso.keys("z", "c")
    check(soon(lambda: chat()[r + 1:r + 4] == [body[0], "     … +6 lines (za to expand)", ""]), "zc collapses it, saying how"
          " much is under it", chat()[r:r + 4])
    iso.keys("z", "a")
    check(soon(lambda: chat()[r + 1:r + 8] == body), "za shows the whole diff again", chat()[r:r + 8])
    hls = [hl_at(r + 1 + i, 12) for i in range(1, 7)]
    check("IsovimAcpDiffDelete" in hls[1] and "IsovimAcpDiffAdd" in hls[2] and not any("Diff" in h and "Nr" not in h for h in hls[0]),
          "removed lines red, added green, context plain", hls)
    iso.lua("vim.cmd('normal! G') require('isovim.acp.chat').focus_composer('acme/app', 'a0')")

    run("send", a0, "term for i in 1 2 3 4 5; do echo line $i; sleep 0.3; done; exit 3")
    iso.wait(lambda: has("⎿  line 1"), "the terminal output streaming")
    early = chat()
    iso.wait(lambda: has(f"{DOT} ran it"), "the command done")
    lines = chat()
    r = row_of(f"{DOT} Bash(for i in 1 2 3 4 5; do echo line $i; sleep 0.3; done; exit 3)")
    check(r is not None and lines[r + 1:r + 6] == ["  ⎿  Error: Exit code 3", "     line 1", "     line 2",
                                                   "     … +3 lines (za to expand)", ""],
          "Bash output from terminal deltas, under Bash(command), its exit code first, collapsed", lines[-9:])
    iso.lua("require('isovim.acp.chat').set_open('acme/app', 'a0', ..., true)", r)
    check(chat()[r + 2:r + 7] == ["     line 1", "     line 2", "     line 3", "     line 4", "     line 5"],
          "all of it when opened", chat()[r:r + 8])
    check(not any("line 5" in line for line in early), "it streamed in, line by line", early[-4:])
    check("IsovimAcpToolFailed" in hl_at(r, 0), f"a failing exit: red {DOT}", hl_at(r) if r is not None else None)

    run("send", a0, "think")
    run("send", a0, "plan")
    iso.wait(lambda: has(f"{DOT} planned"), "think and plan")
    lines = chat()
    r = next((i for i, line in enumerate(lines) if line.startswith("✻ Thought for ")), None)
    check(r is not None and "IsovimAcpThought" in hl_at(r, 4), "thinking: ✻, dimmed and collapsed", lines[-14:])
    r = row_of(f"{DOT} Update Todos")
    check(r is not None and lines[r + 1:r + 4] == ["  ⎿  ☒ read the code", "     ☐ write the fix", "     ☐ test it"],
          "a plan as a checklist", lines[-8:])
    long = "word " * 60
    run("send", a0, long.strip())
    iso.wait(lambda: turn_done("a0", long.strip()), "a long prompt")
    wrap = iso.lua("local w = ... return { vim.wo[w].wrap, vim.wo[w].linebreak, vim.wo[w].breakindent, vim.wo[w].breakindentopt }", chat_win())
    check(wrap == [True, True, True, "list:-1"], "long lines wrap under their text, no sideways scroll", wrap)
    iso.screenshot("look")

    print("\n# streaming, through the supervisor's pushes")
    check(iso.lua("local c = require('isovim.acp.chat').get('acme/app', 'a0') return c.chan ~= nil"
                  " and vim.api.nvim_get_chan_info(c.chan).id ~= nil"), "the chat subscribed to the supervisor")
    # The journal watch off: only pushes reach it now.
    iso.lua("require('isovim.acp.chat').get('acme/app', 'a0').unfollow()")
    iso.lua("vim.api.nvim_win_set_cursor(..., { vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(...)), 0 })", chat_win())
    run("send", a0, "stream 6")
    seen, spin = [], None
    deadline = time.time() + 15
    while time.time() < deadline:
        last = next((line for line in reversed(chat() or []) if line.startswith(f"{DOT} w")), "")
        if last.startswith(f"{DOT} w") and (not seen or seen[-1] != last):
            seen.append(last)
        if last.rstrip().endswith("w6"):
            break
        if seen:
            spin = bar()
        time.sleep(0.1)
    check(seen and seen[-1].rstrip() == f"{DOT} w1 w2 w3 w4 w5 w6", "the text arrives with the journal watch off", seen)
    check(len(seen) >= 4, "chunk by chunk, not all at the end", seen)
    spin = re.sub(r"%#\w+#", "", spin or "")
    check("… (" in spin and "<C-c> to interrupt" in spin, "the bar above the composer has Claude's spinner line while it"
          " works", spin)
    spins = set()
    run("send", a0, "slow 2")
    for _ in range(12):
        spins.add((bar() or "")[:40])
        time.sleep(0.12)
    check(len(spins) >= 3, "the spinner turns", spins)
    iso.wait(lambda: turn_done("a0", "slow 2"), "slow 2 done")
    check(soon(lambda: "to interrupt" not in bar() and "alpha" in bar()), "idle: the bar names the agent", bar())

    print("\n# follow the bottom only when you're there")
    win = chat_win()
    iso.lua("vim.api.nvim_win_set_cursor(..., { 1, 0 })", win)
    run("send", a0, "stream 3")
    iso.wait(lambda: has(f"{DOT} w1 w2 w3"), "streamed while scrolled up")
    check(iso.lua("return vim.api.nvim_win_get_cursor(...)[1]", win) == 1, "scrolled up, the view stays put")
    check("↓ more below" in bar(), "and the bar says there's more below", bar())
    iso.lua("vim.api.nvim_win_call(..., function() vim.cmd('normal! G') end)", win)
    check(soon(lambda: "↓ more below" not in bar()), "back at the bottom it's gone", bar())
    run("send", a0, "stream 2")
    iso.wait(lambda: turn_done("a0", "stream 2"), "streamed at the bottom")
    check(iso.lua("local w = ... return vim.api.nvim_win_get_cursor(w)[1] == vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(w))", win),
          "at the bottom, it follows")
    # The journal watch back on, for what follows.
    iso.lua("require('isovim.acp.chat').close('acme/app', 'a0')")
    iso.cli("open", a0)
    iso.wait(lambda: has(f"{DOT} w1 w2") and any(line.startswith(f"{DOT} w1 w2") for line in chat()[-3:]), "the chat reopened")

    print("\n# the queue")
    run("send", a0, "slow 8")
    iso.wait(lambda: state("a0") == "working", "a0 working")
    for text in ("slow 2 q1", "slow 2 q2", "slow 2 q3"):
        run("send", a0, text)
    qwin = lambda: iso.lua("return require('isovim.acp.queue').window(require('isovim.acp.chat').get('acme/app', 'a0')) or vim.NIL")  # noqa: E731
    iso.wait(lambda: qwin() and iso.lua("return vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(...))", qwin()) == 3,
             "three queued, in the queue window")
    check(not any("(queued)" in line for line in chat()), "the chat doesn't draw them", chat()[-5:])
    check("3 queued" in bar(), "the bar counts them", bar())
    iso.lua("vim.api.nvim_set_current_win(...)", chat_win())
    iso.keys("Escape")
    iso.keys("Space", "i", "q")
    iso.wait(lambda: iso.lua("return vim.bo.filetype") == "isovim_queue", "<leader>iq goes to the queue")
    check(iso.lua("return vim.api.nvim_get_current_win()") == qwin(), "its window between the chat and the composer")
    qbuf = iso.lua("return vim.api.nvim_get_current_buf()")
    qlines = lambda: iso.lua("return vim.api.nvim_buf_get_lines(..., 0, -1, false)", qbuf)  # noqa: E731
    check(qlines() == ["#1 slow 2 q1", "#2 slow 2 q2", "#3 slow 2 q3"], "one line a prompt", qlines())
    # Reorder, edit, delete one and add one, then :w.
    iso.lua("vim.api.nvim_buf_set_lines(..., 0, -1, false, { '#3 slow 2 q3', '#1 slow 3 q1 edited', 'slow 2 q4 new' })", qbuf)
    iso.keys("Escape")
    iso.type(":w")
    iso.keys("Enter")
    queue = lambda: [i["text"] for i in call("queue")[1]["items"]]  # noqa: E731
    check(soon(lambda: queue() == ["slow 2 q3", "slow 3 q1 edited", "slow 2 q4 new"]), "edited, reordered, cut and added", queue())
    check(soon(lambda: "3 queued" in bar() and "queued · 3" in iso.lua("return vim.wo[...].winbar", qwin())),
          "the bar and the window's title follow", bar())
    check(qlines() == ["#1 slow 2 q3", "#2 slow 3 q1 edited", "#3 slow 2 q4 new"] and not iso.lua("return vim.bo.modified"),
          "the buffer shows the queue as written", qlines())
    iso.screenshot("queue")
    # Send one now: the running turn is cancelled and it goes next.
    iso.lua("vim.api.nvim_win_set_cursor(0, { 2, 0 })")
    iso.keys("Enter")
    iso.wait(lambda: any(e["kind"] == "prompt" and e["text"] == "slow 3 q1 edited" for e in journal("a0")), "sent now")
    ends = [e for e in journal("a0") if e["kind"] == "turn" and e["state"] == "end"]
    check(ends[-1].get("stopReason") == "cancelled", "the running turn was cancelled for it", ends[-1])
    check(soon(lambda: qlines() == ["#1 slow 2 q3", "#2 slow 2 q4 new"]), "the queue buffer follows", qlines())
    # Clear it while that one works.
    iso.lua("vim.api.nvim_buf_set_lines(..., 0, -1, false, {})", qbuf)
    iso.type(":w")
    iso.keys("Enter")
    check(soon(lambda: queue() == []), "deleting every line and :w clears it", queue())
    check(soon(lambda: qwin() is None and "queued" not in bar()), "the queue window closes, the bar's count goes")
    iso.wait(lambda: turn_done("a0", "slow 3 q1 edited"), "the sent-now prompt answered", 15)
    time.sleep(1)
    texts = [e["text"] for e in journal("a0") if e["kind"] == "prompt"]
    check(not any(t in texts for t in ("slow 2 q1", "slow 2 q2", "slow 2 q3", "slow 2 q4 new")), "nothing cleared or cut was sent", texts[-4:])
    # q hides it while prompts wait.
    run("send", a0, "slow 4")
    iso.wait(lambda: state("a0") == "working", "a0 working")
    run("send", a0, "slow 1 q5")
    iso.wait(lambda: qwin(), "queued again, the window back")
    iso.lua("vim.api.nvim_set_current_win(...)", qwin())
    iso.keys("q")
    iso.wait(lambda: qwin() is None and iso.lua("return vim.bo.filetype") != "isovim_queue", "q hides it")
    iso.wait(lambda: turn_done("a0", "slow 1 q5"), "the queued one answered", 15)

    print("\n# iso attach from a second nvim")
    att = f"isot-att-{os.getpid()}"
    subprocess.run(["tmux", "-L", iso.ui, "new-session", "-d", "-s", att, "-x", "110", "-y", "36", BIN, "attach", a0],
                   env=iso.env, check=True)

    def att_screen():
        return subprocess.run(["tmux", "-L", iso.ui, "capture-pane", "-p", "-t", f"={att}:"], capture_output=True, text=True).stdout

    iso.wait(lambda: f"{DOT} reply to: slow 1 q5" in att_screen() and "alpha" in att_screen(), "the attached chat", 20)
    check(True, "it shows the same chat, its bar naming the agent")
    subprocess.run(["tmux", "-L", iso.ui, "send-keys", "-t", f"={att}:", "-l", "from the attached nvim"])
    time.sleep(0.2)
    subprocess.run(["tmux", "-L", iso.ui, "send-keys", "-t", f"={att}:", "Enter"])
    iso.wait(lambda: turn_done("a0", "from the attached nvim"), "its prompt answered")
    check(soon(lambda: "reply to: from the attached nvim" in att_screen()), "it sends, and the reply streams in", att_screen()[-400:])
    check(soon(lambda: has("❯ from the attached nvim") and has(f"{DOT} reply to: from the attached nvim")), "and the TUI's chat shows it too")
    ansi = subprocess.run(["tmux", "-L", iso.ui, "capture-pane", "-p", "-e", "-t", f"={att}:"], capture_output=True, text=True).stdout
    screenshot.render(ansi, OUT / "acp_chat_look-attach.png", 110, 36)
    subprocess.run(["tmux", "-L", iso.ui, "send-keys", "-t", f"={att}:", "Escape", ":qa", "Enter"])
    check(soon(lambda: att not in subprocess.run(["tmux", "-L", iso.ui, "list-sessions", "-F", "#{session_name}"],
                                                 capture_output=True, text=True).stdout.split()), ":qa leaves it")

    print("\n# iso handover")
    iso.wait(lambda: state("a0") in ("idle", "ready"), "a0 idle")
    started = len([f for f in frames() if f.get("started")])
    rc, out, err = run("handover", "--no-attach", a0)
    check(rc == 0 and "claude --resume" in out, "iso handover hands it over", (rc, out, err))
    sid = next(e for e in journal("a0") if e["kind"] == "session")["sessionId"]
    iso.wait(lambda: (iso.tmp / "claude-ran.json").exists(), "claude running in the pane")
    ran = json.loads((iso.tmp / "claude-ran.json").read_text())
    check(ran["argv"][-2:] == ["--resume", sid] and "--append-system-prompt" in ran["argv"] and "bypassPermissions" in ran["argv"],
          "it's claude --resume <session>, with the agent's prompt and bypass mode", ran["argv"][:3] + ran["argv"][-2:])
    check(ran["tty"] and ran["acp"] is None, "on the pane's tty, its hooks reporting state", ran)
    pane = subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], "capture-pane", "-p", "-t", "=iso2-acme+app+a0:"],
                          capture_output=True, text=True).stdout
    check("FAKE CLAUDE ON SCREEN" in pane, "Claude has the pane", pane[-300:])
    check(soon(lambda: has("[handed over to Claude's screen: claude --resume " + sid + "]")), "the chat says so")
    check(soon(lambda: "on Claude's screen" in bar()), "and its bar", bar())
    status = call("status")[1]
    check(status["handover"] and not status["ready"], "one writer: the supervisor holds no session", status)
    rc, _, err = run("handover", "--no-attach", a0)
    check(rc != 0 and "already" in err, "a second handover is refused", err)
    run("send", a0, "while handed over")
    check(soon(lambda: [i["text"] for i in call("queue")[1]["items"]] == ["while handed over"]
               and iso.lua("return require('isovim.acp.queue').window(require('isovim.acp.chat').get('acme/app', 'a0')) ~= nil")),
          "a prompt meanwhile waits in the queue, its window showing")
    check(not any(e["kind"] == "prompt" and e["text"] == "while handed over" for e in journal("a0")), "and isn't sent")
    subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], "send-keys", "-t", "=iso2-acme+app+a0:", "bye", "Enter"])
    iso.wait(lambda: has("[back from Claude's screen]"), "Claude exited", 15)
    check(has("❯ hello from claude's screen") and has(f"{DOT} hi on claude's screen") and has(f"{DOT} Bash(ls -la)"),
          "what happened on Claude's screen is in the chat", chat()[-14:])
    check(not has("meta, left out"), "without Claude's bookkeeping")
    iso.wait(lambda: turn_done("a0", "while handed over"), "the queued prompt sent after", 20)
    resumed = [f["frame"] for f in frames() if f.get("frame", {}).get("method") == "session/resume"]
    check(len([f for f in frames() if f.get("started")]) == started + 1 and resumed and resumed[-1]["params"]["sessionId"] == sid,
          "the session reopened on a new adapter, the same session", (started, len(resumed)))
    iso.screenshot("handover")
    check(soon(lambda: "alpha" in bar()), "the bar is back to idle", bar())
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
