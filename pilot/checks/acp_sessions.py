"""An ACP agent's sessions (L2), with pilot/fake-acp-agent as the adapter (it keeps its sessions on
disk, forks them at a messageId, and answers "history" with the session's earlier prompts): a
restart resumes the session; a rewind (<leader>iu on an earlier prompt, edited in the composer)
forks the session before that prompt, sends the edited one, and puts the files back from the
snapshot taken before its turn; /fork forks the agent whole and <leader>if at the message under the
cursor, each a new agent whose chat starts with the history up to there; /clear and /new start a
new session, /resume picks one back from the history picker (or by id), its chat as it was;
AskUserQuestion (a form elicitation) and a permission request become question surfaces in the
repo's Inbox, and the answer (iso answer, or the question's buffer) reaches the agent; a cancelled
turn takes down what it asked.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/acp_sessions.py"""

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
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], check=True, capture_output=True,
                          text=True).stdout


iso = Iso("acp_sessions", agent_delay=0.2)
iso.env["ISOVIM_SELF"] = "pilothost"
WORK = iso.tmp / "work" / "acme" / "app"


def run(*args, timeout=60):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def journal(agent):
    path = WORK / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def record(agent):
    return json.loads((WORK / "iso" / "agents" / f"{agent}.json").read_text())


def frames(method):
    path = Path(iso.env["FAKE_ACP_LOG"])
    lines = path.read_text().splitlines() if path.exists() else []
    return [f["frame"] for f in map(json.loads, lines) if f.get("frame", {}).get("method") == method]


def state(agent):
    path = iso.tmp / "home" / "run" / "acme+app" / f"{agent}.state"
    return path.read_text().strip() if path.exists() else None


def said(agent, text):
    return any(e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk"
               and e["update"]["content"].get("text") == text for e in journal(agent))


def said_since(agent, text, seq):
    return any(e["seq"] > seq and e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk"
               and e["update"]["content"].get("text") == text for e in journal(agent))


def last_seq(agent):
    entries = journal(agent)
    return entries[-1]["seq"] if entries else 0


def ask(agent, text, reply, typed=False):
    """Sends text (typed in its composer: your own prompt) and waits for the reply (a chunk) after it."""
    seq = last_seq(agent)
    if typed:
        type_in_composer(agent, text)
    else:
        rc, _, err = run("send", f"acme/app/{agent}", text)
        assert rc == 0, err
    iso.wait(lambda: said_since(agent, reply, seq) and state(agent) == "idle", f"{agent}'s reply {reply!r}", 20)


def history(agent):
    """What the agent's session remembers: its "history" reply."""
    seq = last_seq(agent)
    run("send", f"acme/app/{agent}", "history")

    def got():
        for e in journal(agent):
            if e["seq"] > seq and e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk":
                text = e["update"]["content"].get("text", "")
                if text.startswith("history:"):
                    return text
    text = iso.wait(got, f"{agent}'s history", 20)
    iso.wait(lambda: state(agent) == "idle", f"{agent} idle")
    return text


def sessions_of(agent):
    return [e for e in journal(agent) if e["kind"] == "session"]


def chat(agent):
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', ...)"
                   " return c and vim.api.nvim_buf_get_lines(c.buf, 0, -1, false) or vim.NIL", agent)


def has(agent, text):
    return any(text in line for line in (chat(agent) or []))


def composer(agent):
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', ...)"
                   " return c and vim.api.nvim_buf_get_lines(c.composer, 0, -1, false) or vim.NIL", agent)


def to_chat(agent, line):
    """Puts the cursor on line in the agent's chat window, in normal mode."""
    iso.keys("Escape")
    iso.lua("vim.cmd.stopinsert()")
    row = iso.lua("local c = require('isovim.acp.chat').get('acme/app', ...)"
                  " local w = vim.fn.bufwinid(c.buf) vim.api.nvim_set_current_win(w)"
                  " for i, l in ipairs(vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)) do"
                  " if l == select(2, ...) then vim.api.nvim_win_set_cursor(w, { i, 0 }) return i end end", agent, line)
    assert row, f"no line {line!r} in {agent}'s chat: {chat(agent)}"
    return row


def type_in_composer(agent, text):
    iso.lua("require('isovim.acp.chat').focus_composer('acme/app', ...)", agent)
    iso.wait(lambda: iso.lua("return vim.b.isovim_composer == true") and iso.mode() == "i", "the composer")
    iso.type(text)
    iso.keys("Enter")


def surfaces():
    return iso.lua("return vim.tbl_map(function(s) return { name = s.name, type = s.type, question = s.question,"
                   " needs_you = s.needs_you, options = vim.tbl_map(function(o) return o.label end, s.options or {}),"
                   " multi = s.multi, other = s.other } end, require('isovim.surfaces').scan('acme/app'))")


try:
    iso.start()
    app = iso.tmp / "src" / "app"
    app.mkdir(parents=True)
    git("init", "-q", str(app))
    git("-C", str(app), "remote", "add", "origin", "git@github.com:Acme/app.git")
    rc, a0, err = run("spawn", "--acp", "--repo", str(app), "--name", "alpha")
    check(rc == 0 and a0 == "acme/app/a0", "an ACP agent", (rc, a0, err))
    # Its files in a checkout, so each turn snapshots them.
    a0_dir = WORK / "a0"
    git("init", "-q", str(a0_dir))
    (a0_dir / "notes.txt").write_text("v0\n")
    (a0_dir / ".gitignore").write_text("ignored.log\n")
    git("-C", str(a0_dir), "add", "-A")
    git("-C", str(a0_dir), "commit", "-qm", "start")
    iso.wait(lambda: state("a0") in ("ready", "idle"), "a0's session up")
    sid = record("a0")["session"]

    print("# a restart resumes the session")
    ask("a0", "one", "one")
    iso.cli("open", a0)
    iso.wait(lambda: has("a0", f"{DOT} reply to: one"), "a0's chat")
    rc, _, err = run("restart", a0)
    check(rc == 0, "iso restart", err)
    iso.wait(lambda: any(f["params"]["sessionId"] == sid for f in frames("session/resume")), "session/resume", 20)
    iso.wait(lambda: state("a0") in ("ready", "idle"), "a0 back up")
    check(not frames("session/new")[1:], "no new session for it", len(frames("session/new")))
    check(history("a0") == "history: one", "the resumed session remembers what came before", history)
    iso.wait(lambda: has("a0", f"[resumed session {sid}]"), "the chat says it resumed")
    check(has("a0", f"{DOT} reply to: one"), "and keeps what it had")

    print("\n# rewind: edit an earlier prompt, the agent goes on from before it, the files come back")
    ask("a0", "run echo v1 > notes.txt", "ran: echo v1 > notes.txt", typed=True)
    ask("a0", "run echo v2 > notes.txt; echo new > extra.txt; echo log > ignored.log",
        "ran: echo v2 > notes.txt; echo new > extra.txt; echo log > ignored.log", typed=True)
    check((a0_dir / "notes.txt").read_text() == "v2\n" and (a0_dir / "extra.txt").exists(), "the turns changed the files")
    starts = [e for e in journal("a0") if e["kind"] == "turn" and e["state"] == "start"]
    check(all(e.get("snapshot") for e in starts[-3:]) and starts[-1]["snapshot_dir"] == str(a0_dir.resolve()),
          "each turn starts with a snapshot of the checkout", starts[-1])
    refs = git("-C", str(a0_dir), "for-each-ref", "--format=%(refname)", "refs/isovim/snapshots/a0/")
    check(len(refs.split()) >= 3, "kept under refs/isovim/snapshots/a0/", refs)
    check(git("-C", str(a0_dir), "status", "--porcelain").strip() != "" and git("-C", str(a0_dir), "log", "--oneline").count("\n") == 1,
          "with HEAD and the index left alone", git("-C", str(a0_dir), "log", "--oneline"))
    old_sid = record("a0")["session"]
    row = to_chat("a0", "❯ run echo v2 > notes.txt; echo new > extra.txt; echo log > ignored.log")
    iso.keys("Space", "i", "u")
    iso.wait(lambda: composer("a0") == ["run echo v2 > notes.txt; echo new > extra.txt; echo log > ignored.log"],
             "<leader>iu puts the prompt in the composer")
    check(iso.lua("return vim.b.isovim_composer == true") and iso.mode() == "i", "to edit, in insert mode")
    bar = iso.lua("local c = require('isovim.acp.chat').get('acme/app', 'a0') return vim.wo[vim.fn.bufwinid(c.composer)].winbar")
    check("rewind" in bar, "the bar says it's a rewind", bar)
    iso.lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, { '' })")
    seq = last_seq("a0")
    iso.type("history")
    iso.keys("Enter")
    rewound = iso.wait(lambda: next((s for s in sessions_of("a0") if s["how"] == "rewind"), None), "the rewind's session", 20)
    text = iso.wait(lambda: next((e["update"]["content"]["text"] for e in journal("a0") if e["kind"] == "update"
                                  and e["seq"] > rewound["seq"] and e["update"].get("sessionUpdate") == "agent_message_chunk"
                                  and e["update"]["content"].get("text", "").startswith("history:")), None), "the edited prompt's reply")
    check(text == "history: one | history | run echo v1 > notes.txt",
          "the new session goes on from before the rewound prompt", text)
    forks = frames("session/fork")
    check(forks and forks[-1]["params"]["sessionId"] == old_sid
          and forks[-1]["params"]["_meta"]["jetbrains"]["air"]["fork"]["messageId"].startswith("msg_"),
          "it forked the session at the agent's message before it", forks[-1:] and forks[-1]["params"].get("_meta", {}).get("jetbrains"))
    check((a0_dir / "notes.txt").read_text() == "v1\n" and not (a0_dir / "extra.txt").exists(),
          "the files are as they were before its turn", ((a0_dir / "notes.txt").read_text(), (a0_dir / "extra.txt").exists()))
    check((a0_dir / "ignored.log").exists(), "ignored files are left alone")
    rewind = next(s for s in sessions_of("a0") if s["how"] == "rewind")
    check(rewind["previous"] == old_sid and "restored" in rewind.get("files", ""), "the session entry says so", rewind)
    iso.wait(lambda: has("a0", "[rewound:"), "the chat says it rewound")
    lines = chat("a0")
    check("❯ run echo v1 > notes.txt" in lines and "❯ run echo v2 > notes.txt; echo new > extra.txt; echo log > ignored.log" not in lines
          and lines.count("❯ history") == 2, "the chat shows what came before and the edited prompt, not the old one", lines[-12:])
    check((WORK / "iso" / "journal" / "a0.sessions" / f"{old_sid}.jsonl").exists(), "the old session's journal is kept")
    iso.screenshot("rewound")

    print("\n# /fork forks the agent whole")
    iso.wait(lambda: state("a0") == "idle", "a0 idle")
    type_in_composer("a0", "/fork")
    iso.wait(lambda: (WORK / "iso" / "agents" / "a1.json").exists() and any(s["how"] == "fork" for s in sessions_of("a1")),
             "a1, a fork of a0", 30)
    check(composer("a0") == [""], "the composer empties")
    rec = record("a1")
    check(rec.get("acp") and rec["fork_of"] == record("a0")["session"] and rec["fork_from"] == "acme/app/a0"
          and rec["parent"] == "acme/app/a0", "an ACP agent whose record says what it forked", rec)
    iso.wait(lambda: chat("a1") is not None, "a1's chat opens")
    prompts = lambda agent: [e["text"] for e in journal(agent) if e["kind"] == "prompt"]  # noqa: E731
    check(prompts("a1") == prompts("a0"), "with a0's history", (prompts("a1"), prompts("a0")))
    iso.wait(lambda: has("a1", "[forked from acme/app/a0"), "a1's chat says it's a fork")
    check(history("a1") == "history: one | history | run echo v1 > notes.txt | history", "and its session remembers it all")

    print("\n# <leader>if forks at the message under the cursor")
    iso.cli("open", a0)
    iso.wait(lambda: iso.lua("return require('isovim.acp.chat').get('acme/app', 'a0') ~= nil"
                             " and vim.fn.bufwinid(require('isovim.acp.chat').get('acme/app', 'a0').buf) ~= -1"), "a0 on screen")
    to_chat("a0", f"{DOT} reply to: one")
    iso.keys("Space", "i", "f")
    iso.wait(lambda: any(s["how"] == "fork" for s in sessions_of("a2")), "a2, forked at that message", 30)
    check(prompts("a2") == ["one"], "its journal goes up to that message", prompts("a2"))
    iso.wait(lambda: chat("a2") is not None and has("a2", f"{DOT} reply to: one"), "its chat shows it")
    check(not has("a2", "❯ history"), "and nothing after it")
    check(history("a2") == "history: one", "its session remembers only that far")
    check(record("a2").get("fork_at", "").startswith("msg_"), "forked at the message's id", record("a2"))

    print("\n# /clear and /new start new sessions; /resume brings one back")
    iso.cli("open", a0)
    iso.wait(lambda: iso.lua("return vim.fn.bufwinid(require('isovim.acp.chat').get('acme/app', 'a0').buf) ~= -1"), "a0 on screen")
    rewound_sid = record("a0")["session"]
    type_in_composer("a0", "/clear")
    iso.wait(lambda: record("a0")["session"] != rewound_sid and any(s.get("cleared") for s in sessions_of("a0")), "/clear's session")
    iso.wait(lambda: has("a0", "[new session"), "the chat starts again")
    check(not has("a0", "❯ one"), "without the old conversation", chat("a0"))
    check(history("a0") == "history: ", "and the session remembers nothing")
    cleared_sid = record("a0")["session"]
    type_in_composer("a0", "/new")
    iso.wait(lambda: record("a0")["session"] != cleared_sid, "/new's session")
    check(sessions_of("a0")[-1]["previous"] == cleared_sid, "/new too")
    # The history picker: vim.ui.select, here answered with the rewound session.
    iso.lua("_G.picked = nil local select, want = vim.ui.select, ..."
            " vim.ui.select = function(items, opts, on_choice) vim.ui.select = select"
            " _G.picked = vim.tbl_map(function(i) return { id = i.id, current = i.current, label = opts.format_item(i) } end, items)"
            " for _, i in ipairs(items) do if i.id == want then return on_choice(i) end end end", rewound_sid)
    type_in_composer("a0", "/resume")
    iso.wait(lambda: record("a0")["session"] == rewound_sid, "the picked session resumed", 20)
    picked = iso.lua("return _G.picked")
    check(len(picked) >= 4 and sum(1 for p in picked if p["current"]) == 1 and picked[0]["current"],
          "the picker lists the agent's sessions, its current one first", picked)
    check(any(" · one · " + sid[:8] in p["label"] for p in picked), "each with its first prompt", picked)
    iso.wait(lambda: has("a0", f"[resumed session {rewound_sid}]"), "the chat says so")
    check(has("a0", "❯ run echo v1 > notes.txt") and has("a0", f"{DOT} reply to: one"), "with that session's conversation back", chat("a0"))
    check(frames("session/resume")[-1]["params"]["sessionId"] == rewound_sid, "through session/resume")
    check(history("a0") == "history: one | history | run echo v1 > notes.txt | history", "and the agent remembers it")
    type_in_composer("a0", f"/resume {cleared_sid}")
    iso.wait(lambda: record("a0")["session"] == cleared_sid, "/resume <id>")
    check(history("a0") == "history: history", "back in the cleared one")
    # A switch while it works cancels the turn first.
    run("send", a0, "slow 10")
    iso.wait(lambda: state("a0") == "working", "a0 working")
    before = record("a0")["session"]
    type_in_composer("a0", "/new")
    iso.wait(lambda: record("a0")["session"] != before, "/new while it works", 20)
    check(any(e["kind"] == "turn" and e.get("stopReason") == "cancelled" for e in json.loads(
        "[" + ",".join((WORK / "iso" / "journal" / "a0.sessions" / f"{before}.jsonl").read_text().splitlines()) + "]")),
        "its turn was cancelled first")

    print("\n# AskUserQuestion: questions in the repo's Inbox, the answers back to the agent")
    seq = last_seq("a0")
    run("send", a0, "ask")
    asked = iso.wait(lambda: next((e for e in journal("a0") if e["kind"] == "question" and e["seq"] > seq), None), "the questions asked")
    names = [q["name"] for q in asked["questions"]]
    found = {s["name"]: s for s in surfaces()}
    check(all(n in found and found[n]["type"] == "question" and found[n]["needs_you"] for n in names) and len(names) == 2,
          "one question surface a question, in acme/app's Inbox, waiting on you", found)
    q0, q1 = found[names[0]], found[names[1]]
    check(q0["question"] == "alpha (a0) asks: Color: Which color?" and q0["options"] == ["Red", "Blue"] and q0["other"]
          and not q0["multi"], "the first with its options, and room for your own words", q0)
    check(q1["multi"] and q1["options"] == ["S", "M", "L"], "the second a multi-select", q1)
    iso.wait(lambda: has("a0", "  ☐ Color ") and has("a0", " Which color?") and has("a0", "   2. Blue"),
             "the chat shows them in Claude's box")
    inbox = iso.wait(lambda: any("Color" in row for row in iso.sidebar()) and iso.sidebar(), "the sidebar's Inbox lists them")
    check(True, "the sidebar's Inbox lists them")
    rc, _, err = run("answer", names[0], "Blue")
    check(rc == 0, "iso answer the first", err)
    check(not said_since("a0", "answer: ", seq), "the agent waits for both")
    run("answer", names[1], "S", "L")
    iso.wait(lambda: said_since("a0", 'answer: {"action": "accept", "content": {"question_0": "Blue", "question_1": ["S", "L"]}}', seq),
             "the answers reach the agent", 10)
    check(True, "the answers reach the agent as the form's content")
    iso.wait(lambda: not any(s["name"] in names for s in surfaces()), "the questions leave the Inbox")
    iso.wait(lambda: has("a0", "  ⎿  · Which color? → Blue") and has("a0", "     · Which sizes? → S, L"),
             "the chat shows the answers")
    # Answered in the TUI: each question's buffer, your own words in the first's input box, M for the second.
    iso.wait(lambda: state("a0") == "idle", "a0 idle")
    seq = last_seq("a0")
    run("send", a0, "ask")
    iso.wait(lambda: len([s for s in surfaces() if s["name"].startswith("a0-ask-")]) == 2, "two more questions")

    def open_next():
        iso.lua("for _, s in ipairs(require('isovim.surfaces').scan('acme/app')) do"
                " if s.type == 'question' and not s.answer then return require('isovim.surfaces').open(s) end end")
        iso.wait(lambda: iso.lua("return vim.bo.filetype") == "isovim_question", "the question's buffer")

    open_next()
    iso.keys("i")
    iso.wait(lambda: iso.lua("return vim.bo.filetype") == "isovim_surface_input", "its input box")
    iso.type("teal please")
    iso.keys("Enter")
    iso.wait(lambda: len([s for s in surfaces() if s["name"].startswith("a0-ask-") and s["needs_you"]]) == 1, "the first answered")
    open_next()
    iso.keys("2")
    iso.keys("s")
    iso.wait(lambda: said_since("a0", 'answer: {"action": "accept", "content": {"question_0_custom": "teal please", "question_1": ["M"]}}', seq),
             "the buffers' answers reach the agent, your words as the custom answer", 10)
    check(True, "answered in the questions' buffers, your own words as the custom answer")

    print("\n# a permission request: allow or deny in the Inbox")
    iso.wait(lambda: state("a0") == "idle", "a0 idle")
    for answer, outcome, decision in (("allow", "permission: allow", "allowed"), ("deny", "permission: reject", "denied")):
        seq = last_seq("a0")
        run("send", a0, "perm")
        asked = iso.wait(lambda: next((e for e in journal("a0") if e["seq"] > seq and e["kind"] == "permission"
                                       and e["decision"] == "asked"), None), "the permission asked")
        entry = next(s for s in surfaces() if s["name"] == asked["name"])
        check(entry["options"] == ["Allow", "Deny"] and entry["question"] == "alpha (a0) asks to run: Bash: rm -rf build",
              f"a question surface with Allow and Deny ({answer})", entry)
        run("answer", asked["name"], answer)
        iso.wait(lambda: said_since("a0", outcome, seq), f"{answer} reaches the agent")
        got = [e for e in journal("a0") if e["seq"] > seq and e["kind"] == "permission" and e["decision"] != "asked"]
        check(got and got[-1]["decision"] == decision and got[-1]["by"] == "user", f"journaled as {decision}", got)
        iso.wait(lambda: state("a0") == "idle", "a0 idle")
    iso.wait(lambda: has("a0", "  ⎿  Denied by you · Bash: rm -rf build won't run") and not has("a0", " Bash command"),
             "the chat shows the denial, and neither box is left")
    # One left waiting when the turn is cancelled is taken down.
    seq = last_seq("a0")
    run("send", a0, "perm")
    asked = iso.wait(lambda: next((e for e in journal("a0") if e["seq"] > seq and e["kind"] == "permission"
                                   and e["decision"] == "asked"), None), "another permission asked")
    iso.lua("require('isovim.acp').call('acme/app', 'a0', 'cancel')")
    iso.wait(lambda: any(e["seq"] > seq and e["kind"] == "permission" and e["decision"] == "cancelled" for e in journal("a0")),
             "cancelled with its turn")
    iso.wait(lambda: not any(s["name"] == asked["name"] for s in surfaces()), "and taken out of the Inbox")
    check(True, "a cancelled turn takes its question down")
    iso.wait(lambda: not has("a0", " Bash command"), "and the chat's box")
    iso.wait(lambda: not any("asks" in row for row in iso.sidebar()), "the sidebar's Inbox is empty again")
    check(iso.lua("local n = 0 for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do"
                  " if vim.b[vim.api.nvim_win_get_buf(w)].isovim_composer then n = n + 1 end end return n") == 1,
          "one composer on screen, the chat's on screen (forks opened in its place took theirs)")
    iso.screenshot("asked")
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
