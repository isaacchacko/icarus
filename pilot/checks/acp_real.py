"""One smoke test of an ACP agent with the real claude-agent-acp and your own claude login: a single
tiny prompt on haiku (ANTHROPIC_MODEL=haiku) whose answer can only come from isovim's role prompt in
_meta, the TUI's chat drawing it, isovim's hooks firing from _meta's settings (the prompt hook writes the agent's transcript),
the session kept with CLAUDE_CODE_ENTRYPOINT=isovim (so claude --resume lists it), and a restart
resuming that session without a model call. It spends a little of your Claude usage, so it only runs
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
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


iso = Iso("acp_real")
iso.env.pop("ISOVIM_ACP_CMD")
iso.env["ANTHROPIC_MODEL"] = "haiku"


def run(*args, timeout=200, cwd=None):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    return r.returncode, r.stdout.strip(), r.stderr


def journal():
    path = iso.tmp / "work" / "_" / "iso" / "journal" / "a0.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def said():
    return "".join(e["update"]["content"].get("text", "") for e in journal()
                   if e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk")


try:
    iso.start()
    prompt = ("Answer with one lowercase word and nothing else: the name of the agent multiplexer "
              "your system prompt says you are running inside.")
    rc, addr, err = run("spawn", "--name", "smoke", prompt, cwd=iso.tmp)
    check(rc == 0 and addr == "_/a0", "iso spawn (ACP by default) with the real adapter", (rc, addr, err))
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
    transcript = iso.tmp / "work" / "_" / "iso" / "transcripts" / "a0.txt"
    iso.wait(lambda: transcript.exists(), "the hooks' transcript", 30)
    check(transcript.exists(), "isovim's hooks fire from _meta's settings (the prompt hook wrote the transcript)")
    hook_session = iso.tmp / "home" / "run" / "_" / "a0.session"
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
    chat = lambda: iso.lua("local c = require('isovim.acp.chat').get('_', 'a0')"  # noqa: E731
                           " return c and vim.api.nvim_buf_get_lines(c.buf, 0, -1, false) or {}")
    iso.wait(lambda: any(line.startswith("⏺ ") and "isovim" in line.lower() for line in chat()), "the chat drawn", 20)
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
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
