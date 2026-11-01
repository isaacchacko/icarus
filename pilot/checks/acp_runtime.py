"""ACP agents' runtime, with pilot/fake-acp-agent as the adapter: iso spawn --acp makes a new-layout
agent (acp in its record) whose tmux pane runs the supervisor (nvim -l agent_host.lua); the
supervisor starts the adapter with CLAUDE_CODE_EXECUTABLE and CLAUDE_CODE_ENTRYPOINT, opens the
session in the agent's dir with the role prompt and isovim's hooks in _meta, sets bypassPermissions
and sends the spawn's prompt; every update lands in iso/journal/aN.jsonl; iso send and iso msg reach
it over its socket, and one sent while it works is queued and sent when the turn ends, never two at
once (the fake logs an overlap); the state file and the bus follow (ready, working, idle; msg with
queued); a permission it asks for is denied and journaled; an agent's own iso msg is stamped; a
restart resumes the recorded session; and a legacy agent beside them still runs in claude's TUI.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/acp_runtime.py"""

import json
import os
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


iso = Iso("acp_runtime", agent_delay=0.3)
iso.env["ISOVIM_SELF"] = "pilothost"


def run(*args, timeout=60):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def tmux(*args):
    return subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], *args], capture_output=True, text=True)


def journal(agent):
    path = iso.tmp / "work" / "acme" / "app" / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def fake_log():
    path = Path(iso.env["FAKE_ACP_LOG"])
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def frames(method):
    return [e["frame"] for e in fake_log() if "frame" in e and e["frame"].get("method") == method]


def events():
    path = iso.tmp / "home" / "events" / "events.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def state(agent):
    path = iso.tmp / "home" / "run" / "acme+app" / f"{agent}.state"
    return path.read_text().strip() if path.exists() else None


def texts(agent, kind="prompt"):
    return [e.get("text") for e in journal(agent) if e["kind"] == kind]


def reply_done(agent, text):
    return any(e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk"
               and e["update"]["content"].get("text") == text for e in journal(agent))


try:
    iso.start()
    app = iso.tmp / "src" / "app"
    app.mkdir(parents=True)
    git("init", "-q", str(app))
    git("-C", str(app), "remote", "add", "origin", "git@github.com:Acme/app.git")
    records = iso.tmp / "work" / "acme" / "app" / "iso" / "agents"

    print("# spawn --acp")
    rc, a0, err = run("spawn", "--acp", "--repo", str(app), "--name", "alpha", "hello alpha")
    check(rc == 0 and a0 == "acme/app/a0", "iso spawn --acp prints the new-layout address", (rc, a0, err))
    record = json.loads((records / "a0.json").read_text())
    check(record.get("acp") is True and record["kind"] == "claude" and record["name"] == "alpha", "its record says acp", record)
    check(state("a0") is not None, "spawn returns once the supervisor's session is up", state("a0"))
    command = tmux("list-panes", "-t", "=iso2-acme+app+a0", "-F", "#{pane_start_command}").stdout
    check("agent_host.lua" in command and "acme/app/a0" in command, "its pane runs the supervisor", command)
    env = tmux("show-environment", "-t", "=iso2-acme+app+a0").stdout.splitlines()
    check("ISOVIM_ACP=1" in env and "ISOVIM_ADDR=acme/app/a0" in env, "its pane has ISOVIM_ACP and its address", env)
    iso.wait(lambda: reply_done("a0", "hello alpha"), "the spawn's prompt answered")
    started = [e for e in fake_log() if e.get("started")]
    check(len(started) == 1, "one adapter process", started)
    adapter_env = started[0]["env"]
    check(adapter_env["CLAUDE_CODE_EXECUTABLE"] and adapter_env["CLAUDE_CODE_EXECUTABLE"].endswith("claude"),
          "the adapter gets CLAUDE_CODE_EXECUTABLE (the user's claude)", adapter_env)
    check(adapter_env["CLAUDE_CODE_ENTRYPOINT"] == "isovim", "and CLAUDE_CODE_ENTRYPOINT=isovim", adapter_env)
    check(Path(started[0]["cwd"]).resolve() == (iso.tmp / "work" / "acme" / "app" / "a0").resolve(), "it runs in the agent's dir", started[0])
    new = frames("session/new")
    check(len(new) == 1, "one session/new", new)
    meta = new[0]["params"]["_meta"] if new else {}
    append = meta.get("systemPrompt", {}).get("append", "")
    check("You are running inside isovim, as a worker agent" in append and "iso worker" in append,
          "the role prompt goes in _meta.systemPrompt.append", append[:200])
    hooks = meta.get("claudeCode", {}).get("options", {}).get("settings", {}).get("hooks", {})
    check(set(hooks) >= {"SessionStart", "UserPromptSubmit", "Stop"} and "iso-hook" in json.dumps(hooks),
          "isovim's hooks go in _meta.claudeCode.options.settings", list(hooks))
    check(Path(new[0]["params"]["cwd"]).resolve() == (iso.tmp / "work" / "acme" / "app" / "a0").resolve() if new else False,
          "the session's cwd is the agent's dir", new)
    modes = frames("session/set_mode")
    check(len(modes) == 1 and modes[0]["params"]["modeId"] == "bypassPermissions", "the session is set to bypassPermissions", modes)
    sid = journal("a0")[0].get("sessionId")
    check(journal("a0")[0]["kind"] == "session" and sid and record.get("session") in (None, sid), "the journal starts with the session", journal("a0")[:1])
    check(json.loads((records / "a0.json").read_text()).get("session") == sid, "the record keeps the session id", sid)
    seqs = [e["seq"] for e in journal("a0")]
    check(seqs == list(range(1, len(seqs) + 1)), "journal seqs count up from 1", seqs)

    rc, a1, err = run("spawn", "--acp", "--repo", str(app), "--name", "beta")
    check(rc == 0 and a1 == "acme/app/a1", "a second ACP agent beside it is acme/app/a1", (rc, a1, err))
    iso.wait(lambda: state("a1") == "ready", "a1 ready")
    check(not texts("a1"), "a spawn without a prompt sends none", texts("a1"))

    print("\n# prompts over the socket, queued while busy")
    t = time.time()
    rc, out, err = run("send", a0, "slow 2")
    check(rc == 0 and time.time() - t < 5, "iso send returns without waiting for the turn", (rc, err, time.time() - t))
    iso.wait(lambda: state("a0") == "working", "a0 working")
    rc, out, err = run("send", a0, "second")
    check(rc == 0 and "queued (1)" in err, "a message sent while it works is queued", (rc, err))
    rc, out, err = run("send", a0, "third")
    check(rc == 0 and "queued (2)" in err, "and the next behind it", (rc, err))
    queued = [e for e in journal("a0") if e["kind"] == "queued"]
    check([q["text"] for q in queued] == ["second", "third"], "the journal shows them queued", queued)
    check(not any(e["kind"] == "prompt" and e["text"] == "second" for e in journal("a0")), "neither is sent while the turn runs")
    iso.wait(lambda: reply_done("a0", "third"), "the queued ones answered", 20)
    kinds = [(e["kind"], e.get("text") or e.get("state")) for e in journal("a0") if e["kind"] in ("prompt", "turn")]
    order = [k for k in kinds if k[0] == "prompt"]
    check([p[1] for p in order][-3:] == ["slow 2", "second", "third"], "they're sent in order", order)
    # Each prompt's turn ends before the next one starts.
    starts_ends = [k[1] for k in kinds if k[0] == "turn"]
    check(all(a != b for a, b in zip(starts_ends, starts_ends[1:])), "turns never overlap in the journal", starts_ends)
    check(not [e for e in fake_log() if e.get("overlap")], "the adapter never gets a prompt while one runs", [e for e in fake_log() if e.get("overlap")])
    iso.wait(lambda: state("a0") == "idle", "a0 idle after the queue")
    at = "agent.acme/app.a0"
    states = [e["state"] for e in events() if e["topic"] == at + ".status"]
    check(states[:3] == ["ready", "working", "idle"] and states[-1] == "idle", "the bus has its states: ready, working, idle", states)
    msgs = [e for e in events() if e["topic"] == "msg.acme/app.a0"]
    check([(m["text"], m["queued"]) for m in msgs] == [("slow 2", False), ("second", True), ("third", True)],
          "msg.<scope>.<id> for each message, saying whether it queued", msgs)
    rc, out, _ = run("status", a0)
    check(rc == 0 and out in ("idle", "unread"), "iso status reads its state", out)

    print("\n# a permission it asks for is denied")
    run("send", a1, "perm")
    iso.wait(lambda: reply_done(a1.split("/")[-1], "permission: reject"), "the permission answered")
    denied = [e for e in journal("a1") if e["kind"] == "permission"]
    check(denied and denied[0]["decision"] == "denied" and denied[0]["tool"] == "Bash: rm -rf build", "the denial is journaled", denied)
    peek = run("peek", a1)[1]
    check("denied: Bash: rm -rf build (approvals not built yet)" in peek, "and shown in its pane", peek[-400:])

    print("\n# one agent messages another")
    run("send", a1, f"run {BIN} worker msg {a0} hi-from-beta")
    iso.wait(lambda: any("hi-from-beta" in (t or "") for t in texts("a0")), "the message reaches a0", 20)
    got = next(e for e in journal("a0") if e["kind"] == "prompt" and "hi-from-beta" in e["text"])
    check(got["text"].startswith("[from pilothost:acme/app/a1 · m") and got.get("from") == "pilothost:acme/app/a1",
          "it's stamped as from a1", got)
    stamp = got.get("stamp")
    check(stamp and run("verify", stamp)[0] == 0, "and the stamp verifies", stamp)

    print("\n# restart resumes the session")
    rc, out, err = run("restart", a0)
    check(rc == 0, "iso restart", (rc, out, err))
    iso.wait(lambda: len(frames("session/resume")) == 1, "session/resume", 20)
    resumed = frames("session/resume")[0]["params"]
    check(resumed["sessionId"] == sid and "append" in resumed.get("_meta", {}).get("systemPrompt", {}),
          "it resumes the recorded session with the same _meta", resumed.get("sessionId"))
    check(len(frames("session/new")) == 2, "no new session for it", len(frames("session/new")))

    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    first = started[0]["pid"]
    iso.wait(lambda: not alive(first), "the old adapter process to go")
    check(not alive(first), "stopping the pane stops its adapter (its own process group)")
    iso.wait(lambda: any(e["kind"] == "session" and e["how"] == "resume" for e in journal("a0")), "resume journaled")
    run("send", a0, "after restart")
    iso.wait(lambda: reply_done("a0", "after restart"), "a prompt after the restart answered")

    print("\n# a legacy agent is untouched")
    legacy = run("new", "legacy", "--dir", str(app))[1]
    run("open", f"{legacy}/main")
    iso.wait(lambda: run("status", f"{legacy}/main")[1] != "stopped", "legacy agent running")
    lcmd = tmux("list-panes", "-t", f"=isovim-{legacy}-main", "-F", "#{pane_start_command}").stdout
    check("fake-agent" in lcmd and "agent_host" not in lcmd, "it still runs its agent in the pane", lcmd)
    lenv = tmux("show-environment", "-t", f"=isovim-{legacy}-main").stdout
    check("ISOVIM_ACP" not in lenv, "with no ISOVIM_ACP", lenv)
    run("send", f"{legacy}/main", "typed in")
    iso.wait(lambda: "reply to: typed in" in run("peek", f"{legacy}/main")[1], "legacy reply")
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
