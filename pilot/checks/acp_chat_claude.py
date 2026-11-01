"""The ACP chat drawn as Claude Code draws its screen (docs/chat-compare/ has the two side by side),
with pilot/fake-acp-agent as the adapter: your prompt on its gray band; Claude's bullet before the
agent's text and each tool call, the tool's name bold with its arguments in parens, colored by
status; ⎿ before what came back, a long output collapsed to its first lines and "… +N lines"; a
diff numbered, its lines on red and green to the window's edge with the changed words brighter; a
read as its line count; a failing command's exit code; thinking dimmed and collapsed; markdown's
`code` and **bold**; the todo list; a permission and a question as Claude's numbered boxes,
answered from the composer and from the chat, then put away; the spinner line while it works (its
verb, the time, tokens, how to interrupt) and the turn's summary after; the composer between two
rules with ❯ and a hint; the colors for dark and light backgrounds; and the chat replayed from its
journal drawing exactly what it drew live. Screenshots go to pilot/out/acp_chat_claude-*.png.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/acp_chat_claude.py"""

import json
import subprocess
import sys
import time
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


iso = Iso("acp_chat_claude", cols=150, rows=50, agent_delay=0.2)
iso.env["ISOVIM_SELF"] = "pilothost"
WS, AGENT = "acme/app", "a0"


def run(*args, timeout=60):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def journal():
    path = iso.tmp / "work" / "acme" / "app" / "iso" / "journal" / f"{AGENT}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def chat():
    return iso.lua("local c = require('isovim.acp.chat').get(...) return c and vim.api.nvim_buf_get_lines(c.buf, 0, -1, false) or {}",
                   WS, AGENT)


def has(text):
    return any(text in line for line in chat())


def row_of(line, last=True):
    lines = chat()
    rows = [i for i, each in enumerate(lines) if each == line]
    return (rows[-1] if last else rows[0]) if rows else None


def marks(row):
    """The chat's highlight extmarks on a row: [(col, end_col, group, eol)]; a line hl is col -1."""
    return [tuple(m) for m in iso.lua("""
      local chat = require('isovim.acp.chat')
      local c = chat.get(...)
      local row = select(3, ...)
      local out = {}
      for _, ns in ipairs({ chat.ns.hl, chat.ns.md }) do
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(c.buf, ns, { row, 0 }, { row, -1 }, { details = true })) do
          local d = m[4]
          if d.line_hl_group then out[#out + 1] = { -1, -1, d.line_hl_group, false } end
          if d.hl_group then
            local stop = d.end_row and d.end_row > row and 9999 or (d.end_col or m[3])
            out[#out + 1] = { m[3], stop, d.hl_group, d.hl_eol == true }
          end
          if d.conceal then out[#out + 1] = { m[3], d.end_col, 'conceal', false } end
          if d.virt_text then out[#out + 1] = { -2, -2, 'virt:' .. d.virt_text[1][1], false } end
        end
      end
      return out""", WS, AGENT, row)]


def groups_at(row, col):
    return [m[2] for m in marks(row) if m[0] == -1 or (m[0] <= col < m[1])]


def turn_done(text):
    entries = journal()
    ids = [e["id"] for e in entries if e["kind"] == "prompt" and e["text"] == text]
    return ids and any(e["kind"] == "turn" and e["state"] == "end" and e["id"] == ids[-1] for e in entries)


def soon(fn, timeout=8):
    try:
        return bool(iso.wait(fn, "a change", timeout))
    except AssertionError:
        return False


def bar():
    return iso.lua("local c = require('isovim.acp.chat').get(...) local w = vim.fn.bufwinid(c.composer)"
                   " return w ~= -1 and vim.wo[w].winbar or vim.NIL", WS, AGENT)


def bar_text():
    return iso.lua("local chat = require('isovim.acp.chat') return chat.bar_text(chat.get(...))", WS, AGENT)


def send(text, wait=True):
    rc, _, err = run("send", f"{WS}/{AGENT}", text)
    if wait:
        iso.wait(lambda: turn_done(text), f"the turn for {text!r}", 20)


def compose(text):
    """Types text in the composer and sends it, as you would."""
    iso.lua("require('isovim.acp.chat').focus_composer(...)", WS, AGENT)
    iso.type(text)
    iso.keys("Enter")


def bottom():
    iso.lua("local c = require('isovim.acp.chat').get(...) local w = vim.fn.bufwinid(c.buf)"
            " vim.api.nvim_win_call(w, function() vim.cmd('normal! G') end)", WS, AGENT)


def shot(label):
    bottom()
    time.sleep(0.3)
    return iso.screenshot(label)


def snapshot():
    """The chat's lines and every highlight on them, to compare a replay with what was drawn live."""
    return iso.lua("""
      local chat = require('isovim.acp.chat')
      local c = chat.get(...)
      local out = { lines = vim.api.nvim_buf_get_lines(c.buf, 0, -1, false), marks = {} }
      for _, ns in ipairs({ chat.ns.hl, chat.ns.md, chat.ns.tools, chat.ns.boxes }) do
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(c.buf, ns, 0, -1, { details = true })) do
          local d = m[4]
          out.marks[#out.marks + 1] = table.concat({ ns, m[2], m[3], d.end_row or '', d.end_col or '', d.hl_group or '',
            d.line_hl_group or '', d.conceal or '', d.virt_text and d.virt_text[1][1] or '',
            d.virt_lines and d.virt_lines[1][1][1]:sub(1, 6) or '' }, ':')
        end
      end
      table.sort(out.marks)
      return out""", WS, AGENT)


try:
    iso.start()
    app = iso.tmp / "src" / "app"
    app.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(app)], check=True)
    subprocess.run(["git", "-C", str(app), "remote", "add", "origin", "git@github.com:Acme/app.git"], check=True)
    rc, addr, err = run("spawn", "--acp", "--repo", str(app), "--name", "alpha", "hello alpha")
    check(addr == f"{WS}/{AGENT}", "an ACP agent", (rc, addr, err))
    iso.wait(lambda: turn_done("hello alpha"), "the first turn")
    iso.cli("open", addr)
    iso.wait(lambda: has(f"{DOT} reply to: hello alpha"), "the chat")

    print("# your prompt, the agent's text, a read")
    lines = chat()
    r = row_of("❯ hello alpha")
    check(r is not None, "your prompt after ❯", lines[:6])
    if r is not None:
        check("IsovimAcpPromptGlyph" in groups_at(r, 0) and "IsovimAcpPrompt" in groups_at(r, 4),
              "on Claude's gray band, the ❯ dimmed", marks(r))
    r = row_of(f"{DOT} Read(notes.md)")
    check(r is not None, "a tool call as Claude names it: Read(notes.md), its path short", lines)
    if r is not None:
        check("IsovimAcpToolDone" in groups_at(r, 0) and "IsovimAcpToolTitle" in groups_at(r, len(DOT.encode()) + 1)
              and "IsovimAcpToolTitle" not in groups_at(r, len(DOT.encode()) + 6), "its bullet green when done, its name bold,"
              " the parens not", marks(r))
        check(lines[r - 1] == "" and lines[r + 1] == "", "blocks a blank line apart", lines[r - 1:r + 2])
    r = row_of(f"{DOT} reply to: hello alpha")
    check(r is not None and "IsovimAcpMessage" in groups_at(r, 0), "the agent's text after its bullet")
    done = [line for line in lines if line.startswith("✻ ") and " for " in line]
    check(len(done) == 1 and done[0].split()[1] in ("Baked", "Brewed", "Churned", "Cogitated", "Cooked", "Crunched", "Sautéed",
                                                    "Worked"), "the turn's summary after it: ✻ Brewed for 0s", done)
    r = row_of(done[0]) if done else None
    check(r is not None and "IsovimAcpTurnDone" in groups_at(r, 2), "dimmed", marks(r) if r else None)

    print("\n# a diff")
    (iso.tmp / "work" / "acme" / "app" / "a0" / "src").mkdir(parents=True, exist_ok=True)
    send("diff")
    lines = chat()
    r = row_of(f"{DOT} Update(src/app.lua)")
    body = ["  ⎿  Added 2 lines, removed 1 line",
            "       1  local a = 1",
            "       2 -local b = 2",
            "       2 +local b = 20",
            "       3  local c = 3",
            "       4 +local d = 4",
            "       5  return a"]
    check(r is not None and lines[r + 1:r + 8] == body, "Edit is Update(path); its diff open, numbered from the file's line,"
          " under its summary", lines[r:r + 9] if r is not None else lines[-12:])
    if r is not None:
        check("IsovimAcpBold" in groups_at(r + 1, 13) and "IsovimAcpResultGlyph" in groups_at(r + 1, 2),
              "the summary's numbers bold, the ⎿ dimmed", marks(r + 1))
        dele, add = marks(r + 3), marks(r + 4)
        check(any(m[2] == "IsovimAcpDiffDelete" and m[3] for m in dele) and any(m[2] == "IsovimAcpDiffAdd" and m[3] for m in add),
              "removed lines red and added green, to the window's edge", (dele, add))
        check("IsovimAcpDiffDeleteNr" in groups_at(r + 3, 7) and "IsovimAcpDiffAddNr" in groups_at(r + 4, 7),
              "their numbers colored", (dele, add))
        word = [m for m in add if m[2] == "IsovimAcpDiffAddWord"]
        check(word and body[3][word[0][0]:word[0][1]] == "0", "the changed part brighter: 2 -> 20 marks the 0", word)
        check("IsovimAcpDiffNr" in groups_at(r + 2, 7) and not any(m[2].startswith("IsovimAcpDiffA") for m in marks(r + 2)),
              "context lines plain, their numbers dim", marks(r + 2))
        bottom()
        iso.lua("local c = require('isovim.acp.chat').get(...) local w = vim.fn.bufwinid(c.buf)"
                " vim.api.nvim_set_current_win(w) vim.cmd('stopinsert') vim.api.nvim_win_set_cursor(w, { select(3, ...), 0 })",
                WS, AGENT, r + 3)
        iso.keys("Escape")
        iso.keys("z", "a")
        check(soon(lambda: chat()[r + 1:r + 3] == [body[0], "     … +6 lines (za to expand)"]),
              "za collapses it to its summary and the count", chat()[r:r + 4])
        iso.keys("z", "a")
        check(soon(lambda: chat()[r + 1:r + 8] == body), "and opens it again", chat()[r:r + 8])

    print("\n# a long output, a failing command")
    send("term for i in $(seq 1 40); do echo line $i; done")
    lines = chat()
    r = row_of(f"{DOT} Bash(for i in $(seq 1 40); do echo line $i; done)")
    check(r is not None and lines[r + 1:r + 6] == ["  ⎿  line 1", "     line 2", "     line 3", "     … +37 lines (za to expand)", ""],
          "Bash(command), its first lines and how many more", lines[r:r + 6] if r is not None else lines[-8:])
    if r is not None:
        check("IsovimAcpResultNote" in groups_at(r + 4, 6), "the count dimmed", marks(r + 4))
        iso.lua("require('isovim.acp.chat').set_open(select(1, ...), select(2, ...), select(3, ...), true)", WS, AGENT, r)
        check(chat()[r + 40] == "     line 40" and chat()[r + 41] == "", "opened, all of it", chat()[r + 38:r + 42])
        iso.lua("require('isovim.acp.chat').set_open(select(1, ...), select(2, ...), select(3, ...), false)", WS, AGENT, r)
    send("term echo oops; exit 3")
    lines = chat()
    r = row_of(f"{DOT} Bash(echo oops; exit 3)")
    check(r is not None and lines[r + 1:r + 3] == ["  ⎿  Error: Exit code 3", "     oops"], "a failing command says its exit code",
          lines[r:r + 4] if r is not None else lines[-6:])
    if r is not None:
        check("IsovimAcpToolFailed" in groups_at(r, 0) and "IsovimAcpError" in groups_at(r + 1, 8), "in red, its bullet too",
              (marks(r), marks(r + 1)))
    send("run true")
    r = row_of(f"{DOT} Bash(true)")
    check(r is not None and chat()[r + 1] == "  ⎿  (No content)", "no output: (No content)", chat()[r:r + 3] if r else None)

    print("\n# thinking, markdown, the todo list")
    send("think")
    lines = chat()
    r = next((i for i, line in enumerate(lines) if line.startswith("✻ Thought for ")), None)
    check(r is not None and lines[r + 1] == "", "thinking: ✻ Thought for Ns, collapsed", lines[-8:])
    if r is not None:
        check("IsovimAcpThought" in groups_at(r, 4) and any(m[2] == "virt:  (za to expand)" for m in marks(r)),
              "dimmed, saying za opens it", marks(r))
        iso.lua("require('isovim.acp.chat').set_open(select(1, ...), select(2, ...), select(3, ...), true)", WS, AGENT, r)
        check(chat()[r + 1:r + 3] == ["  pondering the question", "  and then some more"] and
              "IsovimAcpThought" in groups_at(r + 1, 4), "opened: its text, dim and italic", chat()[r:r + 4])
        iso.lua("require('isovim.acp.chat').set_open(select(1, ...), select(2, ...), select(3, ...), false)", WS, AGENT, r)
    send("markdown")
    r = row_of(f"{DOT} Use `greet` and **bold** here.")
    check(r is not None, "markdown streams as written", chat()[-8:])
    if r is not None:
        m = marks(r)
        line = chat()[r]
        code = [x for x in m if x[2] == "IsovimAcpCode"]
        check(code and line.encode()[code[0][0]:code[0][1]] == b"greet", "`code` in Claude's code color", m)
        check(len([x for x in m if x[2] == "conceal"]) == 4, "its backticks and asterisks hidden", m)
        check(any(x[2] == "IsovimAcpBold" and line.encode()[x[0]:x[1]] == b"bold" for x in m), "**bold** bold", m)
        h = row_of("  ## A heading")
        check(h is not None and "IsovimAcpHeading" in groups_at(h, 6), "a heading bold", marks(h) if h else chat()[-5:])
        conceal = iso.lua("local c = require('isovim.acp.chat').get(...) local w = vim.fn.bufwinid(c.buf)"
                          " return { vim.wo[w].conceallevel, vim.wo[w].concealcursor }", WS, AGENT)
        check(conceal == [2, "nc"], "hidden on the cursor's line too", conceal)
    send("plan")
    lines = chat()
    r = row_of(f"{DOT} Update Todos")
    check(r is not None and lines[r + 1:r + 4] == ["  ⎿  ☒ read the code", "     ☐ write the fix", "     ☐ test it"],
          "the todo list as Claude's", lines[-8:])
    if r is not None:
        check("IsovimAcpPlanDone" in groups_at(r + 1, 12) and "IsovimAcpPlanActive" in groups_at(r + 2, 10),
              "done struck through, the one in progress bold", (marks(r + 1), marks(r + 2)))
    look = shot("tools")

    print("\n# a permission, answered from the composer")
    send("perm", wait=False)
    iso.wait(lambda: has(" Bash command"), "the permission box")
    lines = chat()
    r = row_of(" Bash command")
    box = ["   rm -rf build", "   Remove the build dir", "", " Do you want to proceed?", "   1. Yes", "   2. No"]
    check(lines[r + 1:r + 7] == box, "Claude's box: the command, its description, the question, numbered options",
          lines[r - 2:r + 9])
    check("IsovimAcpAskTitle" in groups_at(r, 2) and "IsovimAcpOptionNr" in groups_at(r + 5, 3), "its title and numbers in"
          " Claude's colors", (marks(r), marks(r + 5)))
    rule = iso.lua("""local chat = require('isovim.acp.chat') local c = chat.get(...)
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(c.buf, chat.ns.hl, { select(3, ...), 0 }, { select(3, ...), -1 }, { details = true })) do
        if m[4].virt_lines then return { m[4].virt_lines_above, m[4].virt_lines[1][1][1]:sub(1, 9), m[4].virt_lines[1][1][2] } end
      end""", WS, AGENT, r)
    check(rule and rule[0] is True and rule[1] == "───" and rule[2] == "IsovimAcpAskRule", "a rule above it", rule)
    check(soon(lambda: "waiting for your permission" in bar_text()), "the bar says it waits on you", bar_text())
    shot("permission")
    compose("2")
    iso.wait(lambda: any(e["kind"] == "permission" and e["decision"] == "denied" for e in journal()), "the answer")
    check(soon(lambda: not has(" Bash command") and has("  ⎿  Denied by you · Bash: rm -rf build won't run")),
          "2 in the composer denies it, and the box gives way to that", chat()[-8:])
    check(not any(e["kind"] in ("prompt", "queued") and e["text"] == "2" for e in journal()),
          "the answer isn't sent as a prompt")

    print("\n# a question, answered from the composer and the chat")
    send("ask", wait=False)
    iso.wait(lambda: has(" Which color?"), "the question box")
    lines = chat()
    r = row_of("  ☐ Color ")
    check(r is not None and lines[r + 2:r + 9] == [" Which color?", "", "   1. Red", "   2. Blue", "      the calm one",
                                                   "   3. Type something.", ""],
          "its header as a chip, the question, numbered options with their notes, and room for your words",
          lines[-24:])
    if r is not None:
        check("IsovimAcpAskChip" in groups_at(r, 3), "the chip in Claude's colors", marks(r))
    shot("question")
    compose("2")
    time.sleep(0.6)
    # The second question (sizes, any of them): <CR> on its option L in the chat.
    row = row_of("   3. L")
    iso.lua("local c = require('isovim.acp.chat').get(...) local w = vim.fn.bufwinid(c.buf)"
            " vim.api.nvim_set_current_win(w) vim.cmd('stopinsert') vim.api.nvim_win_set_cursor(w, { select(3, ...) + 1, 0 })",
            WS, AGENT, row)
    iso.keys("Escape")
    iso.keys("Enter")
    iso.wait(lambda: any(e["kind"] == "question" and e["state"] == "answered" for e in journal()), "the answers")
    check(soon(lambda: has(f"{DOT} User answered Claude's questions:") and has("  ⎿  · Which color? → Blue")
               and has("     · Which sizes? → L")), "answered: the box gives way to what you said, as Claude puts it",
          chat()[-10:])
    check(soon(lambda: has('answer: {"action": "accept", "content": {"question_0": "Blue", "question_1": ["L"]}}')),
          "and the agent has it", chat()[-4:])

    print("\n# the spinner line, the composer")
    send("slow 3", wait=False)
    iso.wait(lambda: iso.lua("return require('isovim.acp.chat').get(...).busy", WS, AGENT), "busy")
    time.sleep(1.3)
    text = bar_text()
    verb = iso.lua("return require('isovim.acp.chat').get(...).verb", WS, AGENT)
    check(verb and f"{verb}… (1s · <C-c> to interrupt)" in text, "Claude's spinner: glyph, the turn's verb, the time, how to"
          " interrupt", text)
    check(text.strip()[0] in "·✢✳✶✻✽", "its glyph first", text)
    b = bar() or ""
    check("%#IsovimAcpSpinner#" in b and "%#IsovimAcpSpinnerVerb#" in b and "%#IsovimAcpSpinnerNote#" in b,
          "orange glyph and verb, the rest dim", b)
    spins = set()
    for _ in range(8):
        spins.add(bar_text().strip()[0])
        time.sleep(0.12)
    check(len(spins) >= 3, "the glyph turns", spins)
    shot("spinner")
    iso.wait(lambda: turn_done("slow 3"), "slow 3 done")
    send("stream 8")
    tokens = iso.lua("return require('isovim.acp.chat').get(...).turn_chars", WS, AGENT)
    check(tokens and tokens > 0, "it counts what streamed, for the tokens it shows", tokens)
    comp = iso.lua("""local c = require('isovim.acp.chat').get(...) local w = vim.fn.bufwinid(c.composer)
      local out = { statuscolumn = vim.wo[w].statuscolumn, virt = {} }
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(c.composer, -1, 0, -1, { details = true })) do
        local d = m[4]
        if d.virt_lines then
          for _, l in ipairs(d.virt_lines) do out.virt[#out.virt + 1] = { d.virt_lines_above == true, l[1][1]:sub(1, 12), l[1][2] } end
        end
        if d.virt_text then out.virt[#out.virt + 1] = { 'text', d.virt_text[1][1], d.virt_text[1][2] } end
      end
      return out""", WS, AGENT)
    check("❯ " in comp["statuscolumn"], "the composer: ❯ before your text", comp["statuscolumn"])
    virt = comp["virt"]
    check([True, "────", "IsovimAcpRule"] in virt and [False, "────", "IsovimAcpRule"] in virt,
          "between two rules", virt)
    check(any(v[0] is False and v[2] == "IsovimAcpHint" and "<CR> send" in v[1] + "<CR> send" for v in virt),
          "a hint under it", virt)
    topfill = iso.lua("local c = require('isovim.acp.chat').get(...) local w = vim.fn.bufwinid(c.composer)"
                      " return vim.api.nvim_win_call(w, function() return vim.fn.winsaveview().topfill end)", WS, AGENT)
    check(topfill == 1, "the rule above shows (the window keeps its filler line)", topfill)
    check(["text", "Message alpha…", "IsovimAcpHint"] in virt, "what to type while it's empty", virt)

    print("\n# colors for dark and light")
    def hl(name):
        return iso.lua("local h = vim.api.nvim_get_hl(0, { name = ..., link = false })"
                       " return { h.fg and ('#%06X'):format(h.fg) or vim.NIL, h.bg and ('#%06X'):format(h.bg) or vim.NIL }", name)
    dark = {n: hl(n) for n in ("IsovimAcpDiffAdd", "IsovimAcpDiffDelete", "IsovimAcpSpinner", "IsovimAcpPrompt", "IsovimAcpNotice")}
    check(dark["IsovimAcpDiffAdd"][1] == "#022800" and dark["IsovimAcpDiffDelete"][1] == "#3D0100" and
          dark["IsovimAcpSpinner"][0] == "#D77757" and dark["IsovimAcpPrompt"][1] == "#373737" and
          dark["IsovimAcpNotice"][0] == "#999999", "dark: Claude's dark theme (orange accent, dim gray, its diff colors)", dark)
    iso.lua("vim.o.background = 'light'")
    light = {n: hl(n) for n in dark}
    check(light["IsovimAcpDiffAdd"][1] == "#DCFFDC" and light["IsovimAcpDiffDelete"][1] == "#FFDCDC" and
          light["IsovimAcpSpinner"][0] == "#D77757" and light["IsovimAcpPrompt"][1] == "#F0F0F0" and
          light["IsovimAcpNotice"][0] == "#666666", "light: its light theme", light)
    iso.lua("vim.o.background = 'dark' vim.api.nvim_set_hl(0, 'IsovimAcpCode', { fg = '#123456' })"
            " require('isovim.acp.look').highlights()")
    check(hl("IsovimAcpCode")[0] == "#123456" and hl("IsovimAcpDiffAdd")[1] == "#022800",
          "a group you set yourself is kept when isovim sets its own again", hl("IsovimAcpCode"))
    iso.lua("vim.o.background = 'light'")
    shot("light")
    iso.lua("vim.api.nvim_set_hl(0, 'IsovimAcpCode', {}) vim.o.background = 'dark'")

    print("\n# replay draws what live drew")
    live = snapshot()
    iso.lua("require('isovim.acp.chat').close(...)", WS, AGENT)
    iso.cli("open", addr)
    iso.wait(lambda: len(chat()) == len(live["lines"]), "the chat replayed")
    time.sleep(0.5)
    again = snapshot()
    check(again["lines"] == live["lines"], "the same lines", [(i, a, b) for i, (a, b) in enumerate(zip(live["lines"], again["lines"]))
                                                             if a != b][:5])
    missing = sorted(set(live["marks"]) ^ set(again["marks"]))
    check(not missing, "the same highlights, marks and boxes", missing[:8])
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
