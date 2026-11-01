"""The ACP chat with the real claude-agent-acp on haiku, against what Claude Code's own screen shows
for the same prompts (docs/chat-compare/): a Read, an Edit whose diff shows, a Bash with long
output, each asking permission first (the session in default mode, ISOVIM_ACP_MODE), answered from
the chat; thinking; a todo list; and AskUserQuestion answered from the composer. It checks the
renderings a Claude Code user looks for and saves a screenshot of each to pilot/out/acp_chat_real-*.png,
and that replaying the journal draws the same chat. It spends a little of your Claude usage, so it
only runs with ISOVIM_ACP_REAL=1; otherwise it says it skipped.
Run from pilot/: ISOVIM_ACP_REAL=1 uv run --with pynvim --with pillow --with fonttools python checks/acp_chat_real.py"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

if os.environ.get("ISOVIM_ACP_REAL") != "1":
    print("skip: the real claude-agent-acp chat check runs only with ISOVIM_ACP_REAL=1 (it spends a little usage)")
    sys.exit(0)

BIN = str(REPO / "bin" / "iso")
DOT = "⏺" if sys.platform == "darwin" else "●"
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


iso = Iso("acp_chat_real", cols=150, rows=50)
iso.env.pop("ISOVIM_ACP_CMD")
iso.env.pop("ISOVIM_AUTH_CLAUDE")
iso.env["ANTHROPIC_MODEL"] = "haiku"
# Claude's own default mode, so Edit and Bash ask first, as on Claude's screen.
iso.env["ISOVIM_ACP_MODE"] = "default"
WS, AGENT = "general", "a0"


def run(*args, timeout=200, cwd=None):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    return r.returncode, r.stdout.strip(), r.stderr


def journal():
    path = iso.tmp / "work" / WS / "iso" / "journal" / f"{AGENT}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def chat():
    return iso.lua("local c = require('isovim.acp.chat').get(...) return c and vim.api.nvim_buf_get_lines(c.buf, 0, -1, false) or {}",
                   WS, AGENT)


def turns_ended():
    return len([e for e in journal() if e["kind"] == "turn" and e["state"] == "end"])


def pending(kind):
    """The last ask of kind (permission or question) still waiting."""
    open_ = {}
    for e in journal():
        if e["kind"] == "permission" and kind == "permission":
            if e["decision"] == "asked":
                open_[e.get("toolCallId")] = e
            else:
                open_.pop(e.get("toolCallId"), None)
        elif e["kind"] == "question" and kind == "question":
            if e["state"] == "asked":
                open_[e["id"]] = e
            else:
                open_.pop(e["id"], None)
    return list(open_.values())[-1] if open_ else None


def soon(fn, timeout=10):
    try:
        return bool(iso.wait(fn, "a change", timeout))
    except AssertionError:
        return False


def type_prompt(text):
    iso.lua("require('isovim.acp.chat').focus_composer(...)", WS, AGENT)
    iso.type(text)
    iso.keys("Enter")


def shot(label):
    iso.lua("local c = require('isovim.acp.chat').get(...) local w = vim.fn.bufwinid(c.buf)"
            " vim.api.nvim_win_call(w, function() vim.cmd('normal! G') end)", WS, AGENT)
    time.sleep(0.4)
    print("     screenshot:", iso.screenshot(label))


def has(text):
    return any(text in line for line in chat())


def row_of(text):
    lines = chat()
    return next((i for i, line in enumerate(lines) if line == text), None)


def snapshot():
    return iso.lua("""
      local chat = require('isovim.acp.chat')
      local c = chat.get(...)
      local out = { lines = vim.api.nvim_buf_get_lines(c.buf, 0, -1, false), marks = {} }
      for _, ns in ipairs({ chat.ns.hl, chat.ns.md, chat.ns.tools }) do
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(c.buf, ns, 0, -1, { details = true })) do
          local d = m[4]
          out.marks[#out.marks + 1] = table.concat({ ns, m[2], m[3], d.end_row or '', d.end_col or '', d.hl_group or '',
            d.line_hl_group or '', d.conceal or '', d.virt_text and d.virt_text[1][1] or '' }, ':')
        end
      end
      table.sort(out.marks)
      return out""", WS, AGENT)


try:
    iso.start()
    rc, addr, err = run("spawn", "--name", "cmp", "Reply with the single word: ready", cwd=iso.tmp)
    check(rc == 0 and addr == f"{WS}/{AGENT}", "an ACP agent on the real adapter, in Claude's default mode", (rc, addr, err))
    iso.wait(lambda: turns_ended() >= 1, "its first turn", 180)
    home = Path(iso.lua("return require('isovim.store').agent_dir(...)", WS, AGENT))
    (home / "app.py").write_text('def greet(name):\n    return "hello " + name\n\n\ndef add(a, b):\n    return a + b\n\n\n'
                                 'if __name__ == "__main__":\n    print(greet("world"))\n    print(add(1, 2))\n')
    (home / "count.sh").write_text('#!/bin/sh\nfor i in $(seq 1 40); do echo "line $i of the count"; done\n')
    (home / "count.sh").chmod(0o755)
    iso.cli("open", addr)
    iso.wait(lambda: any("ready" in line.lower() for line in chat()), "the chat drawn", 20)

    print("# a Read, an Edit and a Bash, each asking first, answered in the composer")
    type_prompt("Read app.py. Then edit it: make greet return 'hi ' + name, and add a function sub(a, b) after add. "
                "Then run ./count.sh with Bash. Keep replies short.")
    titles, answered = [], 0
    deadline = time.time() + 240
    while turns_ended() < 2 and time.time() < deadline:
        ask = pending("permission")
        if ask and ask["name"] not in titles:
            titles.append(ask["name"])
            iso.wait(lambda: has(" Do you want to"), "the permission box", 20)
            time.sleep(0.5)
            box = chat()
            if not answered:
                check(has(" Edit file") or has(" Bash command"), "Claude's box: Edit file or Bash command", box[-14:])
                check(has("   1. Yes") and has("   2. No"), "with numbered options", box[-8:])
            if has(" Bash command"):
                check(has("   ./count.sh"), "a Bash box shows the command", box[-12:])
                shot("permission-bash")
            else:
                check(any(line.startswith(" Do you want to make this edit to app.py?") for line in box), "an Edit box asks"
                      " about app.py", box[-12:])
                shot("permission-edit")
            type_prompt("1")
            answered += 1
            iso.wait(lambda: any(e["kind"] == "permission" and e.get("toolCallId") == ask.get("toolCallId")
                                 and e["decision"] != "asked" for e in journal()), "the answer taken", 30)
        time.sleep(0.3)
    check(turns_ended() >= 2, "the tools turn ended", journal()[-3:])
    check(answered >= 2, "each tool asked, and 1 in the composer allowed it", answered)
    allowed = [e for e in journal() if e["kind"] == "permission" and e["decision"] == "allowed"]
    check(len(allowed) == answered and all(e.get("by") == "user" for e in allowed), "allowed by you", allowed)
    check(not any(e["kind"] == "prompt" and e["text"] == "1" for e in journal()), "the answers weren't sent as prompts")
    check(not has(" Do you want to"), "the boxes gave way once answered", chat()[-20:])
    lines = chat()
    check(f"{DOT} Read(app.py)" in lines, "Read(app.py)", lines)
    r = row_of(f"{DOT} Read(app.py)")
    check(r is not None and lines[r + 1] == "  ⎿  Read 12 lines", "Read 12 lines under it", lines[r:r + 3] if r else None)
    updates = [i for i, line in enumerate(lines) if line == f"{DOT} Update(app.py)"]
    check(updates, "Edit as Update(app.py)", lines)
    diff = [line for i in updates for line in lines[i + 1:i + 16]]
    check(any(line.startswith("  ⎿  Added ") for line in diff), "its summary: Added N lines…", diff)
    check("       2 -    return \"hello \" + name" in diff and "       2 +    return \"hi \" + name" in diff,
          "the diff numbered from the file's own lines", diff)
    r = next((i for i, line in enumerate(lines) if line.startswith(f"{DOT} Bash(./count.sh")), None)
    check(r is not None and lines[r + 1:r + 5] == ["  ⎿  line 1 of the count", "     line 2 of the count", "     line 3 of the count",
                                                   "     … +37 lines (za to expand)"], "Bash(./count.sh), collapsed to its first"
          " lines and how many more", lines[r:r + 6] if r is not None else lines[-20:])
    check(any(line.startswith("✻ ") and " for " in line for line in lines), "the turn's summary (✻ … for Ns)", lines[-6:])
    shot("tools")

    print("# thinking and a todo list (haiku may do neither: it says so)")
    type_prompt("ultrathink: is 2^31-1 prime? Reason it through briefly. Then use TodoWrite to make a 3-step plan "
                "for adding tests to app.py, with the first step in progress. Don't do the steps.")
    spinner = None
    deadline = time.time() + 180
    while turns_ended() < 3 and time.time() < deadline:
        if spinner is None and iso.lua("return require('isovim.acp.chat').get(...).busy", WS, AGENT):
            time.sleep(2.5)
            spinner = iso.lua("local chat = require('isovim.acp.chat') return chat.bar_text(chat.get(...))", WS, AGENT)
            shot("spinner")
        time.sleep(0.3)
    print("     spinner:", spinner)
    check(spinner and re.search(r"… \(\d+s( · (thinking|↓ \d[\d.k]* tokens))? · <C-c> to interrupt\)", spinner),
          "Claude's spinner line while it works", spinner)
    thoughts = [e for e in journal() if e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_thought_chunk"]
    plans = [e for e in journal() if e["kind"] == "update" and e["update"].get("sessionUpdate") == "plan"]
    print(f"     thought chunks: {len(thoughts)}, plans: {len(plans)}")
    if thoughts:
        check(any(line.startswith("✻ Thought for ") for line in chat()), "its thinking, collapsed", chat()[-20:])
    if plans:
        check(f"{DOT} Update Todos" in chat(), "its todo list", chat()[-20:])
    shot("think-todo")

    print("# AskUserQuestion, answered in the composer")
    type_prompt("Use the AskUserQuestion tool to ask me which test framework to use, with options pytest, unittest and nose. "
                "Nothing else.")
    iso.wait(lambda: pending("question"), "the question", 120)
    iso.wait(lambda: has("   1. pytest"), "its box", 20)
    time.sleep(0.5)
    check(has("   2. unittest") and has("   3. nose"), "numbered options", chat()[-16:])
    check(any(line.startswith("  ☐ ") for line in chat()), "its header as a chip", chat()[-16:])
    shot("question")
    type_prompt("1")
    iso.wait(lambda: turns_ended() >= 4, "the question turn to end", 120)
    check(soon(lambda: has(f"{DOT} User answered Claude's questions:") and any(line.endswith("→ pytest") for line in chat())),
          "answered: as Claude puts it", chat()[-12:])
    check(not any(line.startswith(f"{DOT} AskUserQuestion") or "Asking for your input" in line for line in chat()),
          "no separate tool call for the question", chat()[-16:])
    shot("answered")

    print("# replay")
    live = snapshot()
    iso.lua("require('isovim.acp.chat').close(...)", WS, AGENT)
    iso.cli("open", addr)
    iso.wait(lambda: len(chat()) == len(live["lines"]), "the chat replayed", 20)
    time.sleep(0.5)
    again = snapshot()
    check(again["lines"] == live["lines"], "replaying the journal draws the same lines",
          [(i, a, b) for i, (a, b) in enumerate(zip(live["lines"], again["lines"])) if a != b][:5])
    diff = sorted(set(live["marks"]) ^ set(again["marks"]))
    check(not diff, "and the same highlights", diff[:8])
finally:
    out = REPO / "pilot" / "out" / "acp_chat_real-journal.jsonl"
    try:
        out.write_text("\n".join(json.dumps(e) for e in journal()))
        print("     journal:", out)
    except Exception as e:  # noqa: BLE001
        print("     no journal:", e)
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
