"""One smoke test of an ACP agent with the real claude-agent-acp and your own claude login: a single
tiny prompt on haiku (ANTHROPIC_MODEL=haiku) whose answer can only come from isovim's role prompt in
_meta, the TUI's chat drawing it, isovim's hooks firing from _meta's settings (the prompt hook writes the agent's transcript),
the session kept with CLAUDE_CODE_ENTRYPOINT=isovim (so claude --resume lists it), and a restart
resuming that session without a model call. Then the sessions (L2), on a few more haiku prompts:
a fork at the first answer doesn't know what came after it and a whole fork does (each resumed in its
own dir), AskUserQuestion comes as a question surface whose answer reaches the agent, and a host root
kept the old way at _/a0 is moved to root/a0 and resumes its session from there, remembering it
(ISOVIM_ACP_REAL_SESSIONS=0 skips these). Last, a general/ agent's Write in a known repo's clone is refused, with word
to spawn into that repo. It spends a little of your Claude usage, so it only runs
with ISOVIM_ACP_REAL=1; otherwise it says it skipped.
Run from pilot/: ISOVIM_ACP_REAL=1 uv run --with pynvim --with pillow --with fonttools python checks/acp_real.py"""

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

if os.environ.get("ISOVIM_ACP_REAL") != "1":
    print("skip: the real claude-agent-acp smoke test runs only with ISOVIM_ACP_REAL=1 (it spends a little usage)")
    sys.exit(0)

BIN = str(REPO / "bin" / "iso")
DOT = "⏺" if sys.platform == "darwin" else "●"
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


iso = Iso("acp_real")
iso.env.pop("ISOVIM_ACP_CMD")
# The real claude auth status, as the real adapter's login is what's asked.
iso.env.pop("ISOVIM_AUTH_CLAUDE")
iso.env["ANTHROPIC_MODEL"] = "haiku"


def run(*args, timeout=200, cwd=None):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    return r.returncode, r.stdout.strip(), r.stderr


def journal():
    path = iso.tmp / "work" / "general" / "iso" / "journal" / "a0.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def said():
    return "".join(e["update"]["content"].get("text", "") for e in journal()
                   if e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk")


try:
    iso.start()
    prompt = ("Answer with one lowercase word and nothing else: the name of the agent multiplexer "
              "your system prompt says you are running inside.")
    rc, addr, err = run("spawn", "--name", "smoke", prompt, cwd=iso.tmp)
    check(rc == 0 and addr == "general/a0", "iso spawn (ACP by default) with the real adapter", (rc, addr, err))
    iso.wait(lambda: any(e["kind"] == "turn" and e["state"] == "end" for e in journal()), "the turn to end", 180)
    ended = [e for e in journal() if e["kind"] == "turn" and e["state"] == "end"][0]
    notices = [e["text"] for e in journal() if e["kind"] == "notice"]
    check(ended.get("stopReason") == "end_turn" and not notices, "the turn ends cleanly", (ended, notices))
    check("isovim" in said().lower(), "the answer comes from the role prompt in _meta", said())
    modes = [e["modeId"] for e in journal() if e["kind"] == "mode"]
    check(modes == ["bypassPermissions"], "the supervisor set bypassPermissions", modes)
    sid = next(e["sessionId"] for e in journal() if e["kind"] == "session")
    # What your own CLAUDE.md files @import, appended to the session prompt by the supervisor.
    print("     imports:", next(e for e in journal() if e["kind"] == "session").get("imports"))
    transcript = iso.tmp / "work" / "general" / "iso" / "transcripts" / "a0.txt"
    iso.wait(lambda: transcript.exists(), "the hooks' transcript", 30)
    check(transcript.exists(), "isovim's hooks fire from _meta's settings (the prompt hook wrote the transcript)")
    hook_session = iso.tmp / "home" / "run" / "general" / "a0.session"
    check(hook_session.read_text().strip() == sid, "the session id is recorded", hook_session.read_text())
    config = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude"))
    found = list((config / "projects").glob(f"*/{sid}.jsonl"))
    check(len(found) == 1, "Claude Code keeps the session where claude --resume finds it", found)
    if found:
        entrypoints = {json.loads(line).get("entrypoint") for line in found[0].read_text().splitlines()} - {None}
        check(entrypoints == {"isovim"}, "its entrypoint is isovim, not the SDK's sdk-ts", entrypoints)
        modes = {json.loads(line).get("permissionMode") for line in found[0].read_text().splitlines()} - {None}
        check(modes == {"bypassPermissions"}, "Claude Code ran the prompt in bypassPermissions", modes)
    iso.cli("open", addr)
    chat = lambda: iso.lua("local c = require('isovim.acp.chat').get('general', 'a0')"  # noqa: E731
                           " return c and vim.api.nvim_buf_get_lines(c.buf, 0, -1, false) or {}")
    iso.wait(lambda: any(line.startswith(f"{DOT} ") and "isovim" in line.lower() for line in chat()), "the chat drawn", 20)
    check(any(line.startswith("❯ Answer with one lowercase word") for line in chat()), "the chat shows the prompt and the answer",
          chat())
    rc, _, err = run("restart", addr)
    iso.wait(lambda: any(e["kind"] == "session" and e["how"] == "resume" for e in journal()), "the restart's resume", 60)
    notices = [e["text"] for e in journal() if e["kind"] == "notice"]
    check(not notices and [e["sessionId"] for e in journal() if e["kind"] == "session"][-1] == sid,
          "a restart resumes the same session", notices)

    # The PreToolUse hook from _meta on the real adapter: an agent's first edit in its repo makes its
    # worktree and is refused, and the model makes it again under w/; a read-only agent's is refused.
    def git(*args, cwd=None):
        subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)

    remote = iso.tmp / "remotes" / "acme" / "app.git"
    remote.mkdir(parents=True)
    git("init", "-q", "--bare", "-b", "main", str(remote))
    app = iso.tmp / "src" / "app"
    git("clone", "-q", str(remote), str(app))
    (app / "README").write_text("app\n")
    git("add", "-A", cwd=app)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "first", cwd=app)
    git("push", "-q", "-u", "origin", "main", cwd=app)
    unit = iso.tmp / "work" / "acme" / "app"

    def turns(agent):
        path = unit / "iso" / "journal" / f"{agent}.jsonl"
        entries = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [e for e in entries if e["kind"] == "turn" and e["state"] == "end"]

    target = unit / "a0" / "notes" / "hello.txt"
    rc, edit_addr, err = run("spawn", "--repo", str(app), "--name", "edit",
                             f"Use the Write tool to create the file {target} containing the word hi. If the tool call "
                             "is refused, do what the refusal says, then reply with the word done.", cwd=iso.tmp)
    iso.wait(lambda: turns("a0"), "the editing agent's turn", 240)
    w = unit / "a0" / "w"
    check((w / ".git").exists() and not target.exists(), "real adapter: the first edit made aN/w and was refused", list((unit / "a0").iterdir()))
    check((w / "notes" / "hello.txt").exists(), "real adapter: the model made the edit again under w/",
          list(w.rglob("hello.txt")))
    base = iso.tmp / "home" / "repos" / "acme" / "app" / "base-clone"
    rc, ro_addr, err = run("spawn", "--repo", str(app), "--read-only", "--name", "ro",
                           f"Use the Write tool to create the file {base / 'ro.txt'} containing hi. If it is refused, "
                           "don't try again in any way; reply with the word refused.", cwd=iso.tmp)
    iso.wait(lambda: turns("a1"), "the read-only agent's turn", 240)
    check(not (base / "ro.txt").exists(), "real adapter: a read-only agent's Write is refused", list(base.iterdir()))

    print("\n# a promotion of an agent with a conversation: the role prompt comes as a message")

    def entries(agent):
        path = unit / "iso" / "journal" / f"{agent}.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def said_after(agent, seq):
        return "".join(e["update"]["content"].get("text", "") for e in entries(agent)
                       if e["seq"] > seq and e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk")

    rc, target_addr, err = run("spawn", "--repo", str(app), "--name", "target", "Remember the word plum. Reply with just: ok", cwd=iso.tmp)
    check(rc == 0 and target_addr == "acme/app/a2", "a worker with a conversation", (rc, target_addr, err))
    iso.wait(lambda: turns("a2"), "its first turn", 240)
    ends = len(turns("a0"))
    seq0 = entries("a0")[-1]["seq"]
    run("send", edit_addr, f"Run exactly this command with the Bash tool, once: {BIN} worker promote {target_addr} router "
        "the app needs a lead. Then reply with the command's output.")
    iso.wait(lambda: any(e["kind"] == "prompt" and "You were promoted to router" in (e.get("text") or "") for e in entries("a2")),
             "the promoter's message reached the target", 300)
    iso.wait(lambda: len(turns("a0")) > ends, "the promoter's turn", 240)
    print("     promoter said:", said_after("a0", seq0)[-400:])
    vias = [e.get("via") for e in entries("a2") if e["kind"] == "prompt"]
    given = [e for e in entries("a2") if e["kind"] == "prompt" and e.get("via") == "role"]
    check(given and given[0]["text"].startswith("[isovim: your role is now router]") and vias[-2:] == ["role", "iso"],
          "real adapter: the router's prompt goes as a message, before the promoter's", vias)
    check(any("gave it the router's prompt as a message (journal seq" in e["text"] for e in entries("a2") if e["kind"] == "notice"),
          "and the journal says it was given")
    iso.wait(lambda: len(turns("a2")) >= 3 and run("status", target_addr)[1] in ("idle", "unread", "ready"), "the target idle", 240)
    seq = entries("a2")[-1]["seq"]
    run("send", target_addr, "Two words, lowercase, separated by a space: the isovim role you have now, per the latest "
        "instructions you were given, then the word I asked you to remember.")
    iso.wait(lambda: any(e["seq"] > seq and e["kind"] == "turn" and e["state"] == "end" for e in entries("a2")), "its answer", 240)
    answer = said_after("a2", seq).lower()
    check("router" in answer and "plum" in answer, "real adapter: the promoted agent says it's a router, and keeps its context", answer)

    print("\n# a worker the router spawns can't edit the user's clone")
    kid_out = iso.tmp / "kid.txt"
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=app, capture_output=True, text=True).stdout.strip()
    kid_task = (f"Use the Write tool to create the file {app / 'from-kid.txt'} containing the word hi. If the tool call is "
                f"refused, do what the refusal says. Then run this with the Bash tool, once: git -C {app} commit --allow-empty -m kid "
                "and if that is refused, don't try it again in any way. Reply with the word done.")
    (iso.tmp / "kid-task.txt").write_text(kid_task)
    spawn_kid = iso.tmp / "spawn-kid.sh"
    spawn_kid.write_text(f'#!/bin/sh\nexec {BIN} router spawn --name kid "$(cat {iso.tmp / "kid-task.txt"})" > {kid_out} 2>&1\n')
    spawn_kid.chmod(0o755)
    ends, seq = len(turns("a2")), entries("a2")[-1]["seq"]
    run("send", target_addr, f"Run exactly this command with the Bash tool, once: {spawn_kid}  Then reply with the word spawned.")
    try:
        iso.wait(lambda: len(turns("a2")) > ends and kid_out.exists() and kid_out.read_text().strip(), "the router's spawn", 240)
    except AssertionError:
        print("     router said:", said_after("a2", seq)[-600:])
        raise
    kid = kid_out.read_text().strip()
    kid_id = kid.rsplit("/", 1)[-1]
    kid_rec = json.loads((unit / "iso" / "agents" / f"{kid_id}.json").read_text()) if kid.startswith("acme/app/a") else {}
    check(kid_rec.get("parent") == target_addr and kid_rec.get("checkout") == str(app.resolve()),
          "real adapter: the router's worker records the router's clone as its checkout", (kid, kid_rec))
    iso.wait(lambda: turns(kid_id), "the router's worker's turn", 300)
    kid_w = unit / kid_id / "w"
    check(not (app / "from-kid.txt").exists(), "real adapter: its Write in the user's clone is refused",
          subprocess.run(["git", "status", "--short"], cwd=app, capture_output=True, text=True).stdout)
    check((kid_w / "from-kid.txt").exists(), "real adapter: the worktree was made and the edit landed in its w/",
          list(kid_w.rglob("from-kid.txt")) if kid_w.exists() else "no w")
    check(subprocess.run(["git", "rev-parse", "HEAD"], cwd=app, capture_output=True, text=True).stdout.strip() == head,
          "real adapter: its git commit in the user's clone is refused")
    kid_journal = (unit / "iso" / "journal" / f"{kid_id}.jsonl").read_text()
    check("isovim refused this command: `git commit` would change" in kid_journal,
          "real adapter: the refusal reached it from the Bash hook", kid_journal[-800:])
    if os.environ.get("ISOVIM_ACP_REAL_SESSIONS", "1") == "1":
        print("\n# sessions (L2): a fork at a message and a whole one, AskUserQuestion through the Inbox")

        def journal_of(agent):
            path = iso.tmp / "work" / "general" / "iso" / "journal" / f"{agent}.jsonl"
            return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

        def turn(agent, text, timeout=180):
            ends = len([e for e in journal_of(agent) if e["kind"] == "turn" and e["state"] == "end"])
            seq = journal_of(agent)[-1]["seq"] if journal_of(agent) else 0
            rc, _, err = run("send", f"general/{agent}", text)
            assert rc == 0, err
            iso.wait(lambda: len([e for e in journal_of(agent) if e["kind"] == "turn" and e["state"] == "end"]) > ends,
                     f"{agent}'s turn", timeout)
            return "".join(e["update"]["content"].get("text", "") for e in journal_of(agent)
                           if e["seq"] > seq and e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk")

        first = next(e for e in journal() if e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk")
        check(bool(first["update"].get("messageId")), "the adapter stamps its chunks with a messageId", first["update"])
        turn("a0", "Remember the word kiwi. Reply with just: ok")
        recall = "Did I ask you to remember a word? Reply with only that word, or with none."
        rc, at, err = run("fork", "general/a0", "--at", str(first["seq"]))
        check(rc == 0 and at == "general/a1", "iso fork --at the first answer", (rc, at, err))
        iso.wait(lambda: any(e["kind"] == "session" and e["how"] == "fork" for e in journal_of("a1")), "a1's forked session", 120)
        notices = [e["text"] for e in journal_of("a1") if e["kind"] == "notice"]
        check(not notices, "it forked at that message", notices)
        answer = turn("a1", recall)
        check("kiwi" not in answer.lower(), "the fork at the first answer doesn't know kiwi (its own cwd, resumed there)", answer)
        rc, whole, err = run("fork", "general/a0")
        iso.wait(lambda: any(e["kind"] == "session" and e["how"] == "fork" for e in journal_of("a2")), "a2's forked session", 120)
        answer = turn("a2", recall)
        check("kiwi" in answer.lower(), "the whole fork does", answer)

        seq = journal_of("a0")[-1]["seq"]
        run("send", "general/a0", "Use the AskUserQuestion tool to ask me which color I prefer, with the options Red and Blue."
                             " After I answer, reply with only the color I chose.")
        asked = iso.wait(lambda: next((e for e in journal_of("a0") if e["seq"] > seq and e["kind"] == "question"
                                       and e["state"] == "asked"), None), "AskUserQuestion as a question surface", 180)
        print("     asked:", asked["questions"])
        rc, _, err = run("answer", asked["questions"][0]["name"], "Blue")
        check(rc == 0, "iso answer answers it", err)
        iso.wait(lambda: any(e["seq"] > seq and e["kind"] == "turn" and e["state"] == "end" for e in journal_of("a0")),
                 "the turn after the answer", 180)
        replies = "".join(e["update"]["content"].get("text", "") for e in journal_of("a0")
                          if e["seq"] > asked["seq"] and e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk")
        check("blue" in replies.lower(), "the answer reached the agent", replies)

        print("\n# the old _/ moved: a host root that lived at _/a0 resumes its session from root/a0")
        # a0 (it knows kiwi) as the old isovim kept a host root: stopped, its files under _/.
        work, run_root = iso.tmp / "work", iso.tmp / "home" / "run"
        subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], "kill-session", "-t", "=iso2-general+a0"], capture_output=True)
        iso.wait(lambda: "iso2-general+a0" not in subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], "list-sessions"],
                                                                capture_output=True, text=True).stdout, "a0 stopped", 10)
        old_sid = json.loads((work / "general" / "iso" / "agents" / "a0.json").read_text())["session"]
        (work / "_" / "iso" / "agents").mkdir(parents=True)
        (work / "_" / "iso" / "journal").mkdir(parents=True)
        (run_root / "_").mkdir(parents=True)
        rec = json.loads((work / "general" / "iso" / "agents" / "a0.json").read_text())
        rec["role"] = "root"
        (work / "_" / "iso" / "agents" / "a0.json").write_text(json.dumps(rec))
        (work / "general" / "iso" / "agents" / "a0.json").unlink()
        (work / "general" / "a0").rename(work / "_" / "a0")
        (work / "general" / "iso" / "journal" / "a0.jsonl").rename(work / "_" / "iso" / "journal" / "a0.jsonl")
        for f in (run_root / "general").glob("a0.*"):
            f.rename(run_root / "_" / f.name)
        rc, out, err = run("ls")
        check(rc == 0 and not (work / "_").exists() and (work / "root" / "iso" / "agents" / "a0.json").exists(),
              "iso ls moved _/a0 to root/a0", (rc, err))
        moved_journal = lambda: [json.loads(line) for line in (work / "root" / "iso" / "journal" / "a0.jsonl").read_text().splitlines()]  # noqa: E731
        ends = len([e for e in moved_journal() if e["kind"] == "turn" and e["state"] == "end"])
        seq = moved_journal()[-1]["seq"]
        rc, _, err = run("send", "_/a0", recall)
        check(rc == 0, "iso send _/a0 starts it at root/a0", err)
        # Its role is root now (it was a worker in this session), so the root's prompt goes first, as a message.
        recall_ids = lambda: {e["id"] for e in moved_journal() if e["seq"] > seq and e["kind"] == "prompt" and e.get("text") == recall}  # noqa: E731
        iso.wait(lambda: any(e["kind"] == "turn" and e["state"] == "end" and e.get("id") in recall_ids() for e in moved_journal()),
                 "root/a0's turn", 240)
        sessions = [e for e in moved_journal() if e["seq"] > seq and e["kind"] == "session"]
        notices = [e["text"] for e in moved_journal() if e["seq"] > seq and e["kind"] == "notice" and "prompt as a message" not in e["text"]]
        check(any(e.get("via") == "role" for e in moved_journal() if e["seq"] > seq and e["kind"] == "prompt"),
              "its new role's prompt went to it as a message first")
        check(sessions and sessions[-1]["sessionId"] == old_sid and sessions[-1]["how"] in ("resume", "load") and not notices,
              "it resumed the same session from its new dir", (sessions, notices))
        answer = "".join(e["update"]["content"].get("text", "") for e in moved_journal()
                         if e["seq"] > seq and e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk")
        check("kiwi" in answer.lower(), "and remembers what it was told before the move", answer)

    print("\n# a general/ agent can't edit a known repo's clone")
    # acme/app is known here (its ~/.isovim/repos/acme/app came with the spawns above).
    rc, gen, err = run("spawn", "--repo", "general", "--name", "gen",
                       f"Use the Write tool to create the file {app / 'from-general.txt'} containing the word hi. If the tool "
                       "call is refused, don't try again in any way; reply with the word refused.", cwd=iso.tmp)
    check(rc == 0 and gen.startswith("general/a"), "a general/ agent", (rc, gen, err))
    gen_journal = iso.tmp / "work" / "general" / "iso" / "journal" / f"{gen.rsplit('/', 1)[-1]}.jsonl"

    def gen_ended():
        lines = gen_journal.read_text().splitlines() if gen_journal.exists() else []
        return any(e["kind"] == "turn" and e["state"] == "end" for e in map(json.loads, lines))

    iso.wait(gen_ended, "the general/ agent's turn", 240)
    text = gen_journal.read_text()
    check(not (app / "from-general.txt").exists(), "real adapter: its Write in acme/app's clone is refused",
          subprocess.run(["git", "status", "--short"], cwd=app, capture_output=True, text=True).stdout)
    check("isovim refused" in text and "spawn --repo acme/app" in text, "real adapter: the refusal says to spawn into acme/app",
          text[-800:])
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
