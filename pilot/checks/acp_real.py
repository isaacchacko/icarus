"""One smoke test of an ACP agent with the real claude-agent-acp and your own claude login: a single
tiny prompt on haiku (ANTHROPIC_MODEL=haiku) whose answer can only come from isovim's role prompt in
_meta, isovim's hooks firing from _meta's settings (the prompt hook writes the agent's transcript),
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


def run(*args, timeout=200):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
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
    rc, addr, err = run("spawn", "--acp", "--name", "smoke", prompt)
    check(rc == 0 and addr == "_/a0", "iso spawn --acp with the real adapter", (rc, addr, err))
    iso.wait(lambda: any(e["kind"] == "turn" and e["state"] == "end" for e in journal()), "the turn to end", 180)
    ended = [e for e in journal() if e["kind"] == "turn" and e["state"] == "end"][0]
    notices = [e["text"] for e in journal() if e["kind"] == "notice"]
    check(ended.get("stopReason") == "end_turn" and not notices, "the turn ends cleanly", (ended, notices))
    check("isovim" in said().lower(), "the answer comes from the role prompt in _meta", said())
    modes = [e["modeId"] for e in journal() if e["kind"] == "mode"]
    check(modes == ["bypassPermissions"], "the supervisor set bypassPermissions", modes)
    sid = next(e["sessionId"] for e in journal() if e["kind"] == "session")
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
    rc, _, err = run("restart", addr)
    iso.wait(lambda: any(e["kind"] == "session" and e["how"] == "resume" for e in journal()), "the restart's resume", 60)
    notices = [e["text"] for e in journal() if e["kind"] == "notice"]
    check(not notices and [e["sessionId"] for e in journal() if e["kind"] == "session"][-1] == sid,
          "a restart resumes the same session", notices)
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
