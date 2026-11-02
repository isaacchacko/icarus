"""Items 7-9 of the final review (handoff/mac-final-review.md), with pilot/fake-acp-agent as the adapter.
7. A journal with no role hash (one from before isovim recorded it, like a migrated _/a0's) counts
   as changed: the resumed session gets its role's prompt as a message, once; the next restart
   sends nothing.
8. Claude's transcript of a session that's in two project dirs (the migration copies it and leaves
   the old one): the one under the agent's own dir wins, so iso transcript reads the current
   conversation, and what's done on Claude's screen in iso handover reaches the journal.
9. (a) A prompt that keeps failing on a usage limit is tried again after a delay that doubles.
   (b) A spawn prompt held while claude is logged out is kept on disk, so it still goes once logged
   in after the supervisor ended meanwhile. (c) The first sync keeps a key only the peer has,
   while a key deleted here (recorded so) is still deleted there. (d) The built-in text says a
   promotion gives the new role's instructions as a message, and an agent whose journal was
   written by the isovim from before that wording gets no role message on restart; an edited role
   prompt file still sends one.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/fixes_e.py"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

BIN = str(REPO / "bin" / "iso")
# The isovim from before these fixes, whose journals an upgraded supervisor must read.
OLD_REV = os.environ.get("FIXES_E_OLD_REV", "16a018d")
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


iso = Iso("fixes_e", agent_delay=0.2)
tmp = iso.tmp
WORK, HOME = tmp / "work", tmp / "home"
HOME.mkdir()
AUTH = Path(iso.env["FAKE_AUTH_FILE"])
plain = tmp / "plain"
plain.mkdir()
iso.env.update(ISOVIM_SELF="pilothost", ISOVIM_RETRY_SECS="1")

# A peer reached through a stand-in ssh (as fixes_a.py), for the sync.
ssh = tmp / "ssh"
ssh.write_text(f"""#!/usr/bin/env bash
args=("$@"); i=0
while [ "${{args[$i]}}" = -o ] || [ "${{args[$i]}}" = -t ]; do [ "${{args[$i]}}" = -o ] && i=$((i+1)); i=$((i+1)); done
host="${{args[$i]}}"
mkdir -p {tmp}/hosts/"$host" && cd {tmp}/hosts/"$host" && exec {REPO}/pilot/fake-ssh "$@"
""")
ssh.chmod(0o755)
(tmp / "ssh-env").write_text("")
peer = tmp / "hosts" / "peerhost" / "isovim-home"
iso.env.update(ISOVIM_SSH=str(ssh), FAKE_SSH_ENV=str(tmp / "ssh-env"), ISOVIM_SYNC_ROOT="isovim-home")

# Claude's config dir (its transcripts) and a fake claude for the handover, first on PATH: it
# appends to the session's transcript under its cwd's project key, as Claude does.
CONFIG = tmp / "claude-config"
(CONFIG / "projects").mkdir(parents=True)
iso.env["CLAUDE_CONFIG_DIR"] = str(CONFIG)
fakebin = tmp / "bin"
fakebin.mkdir()
(fakebin / "claude").write_text(f"""#!/usr/bin/env python3
import json, os, re, sys
argv = sys.argv[1:]
sid = argv[argv.index("--resume") + 1]
project = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects", re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(os.getcwd())))
os.makedirs(project, exist_ok=True)
rows = [
    {{"type": "user", "message": {{"role": "user", "content": "hello from claude's screen"}}}},
    {{"type": "assistant", "message": {{"content": [{{"type": "text", "text": "hi on claude's screen"}}]}}}},
]
with open(os.path.join(project, sid + ".jsonl"), "a") as f:
    for row in rows:
        f.write(json.dumps(row) + "\\n")
open({str(tmp / "claude-ran")!r}, "w").write(project)
print("FAKE CLAUDE ON SCREEN", flush=True)
sys.stdin.readline()
""")
(fakebin / "claude").chmod(0o755)
iso.env["PATH"] = f"{fakebin}:{iso.env['PATH']}"


def run(*args, bin=BIN, env=None, timeout=120):
    r = subprocess.run([bin, *args], env={**iso.env, **(env or {})}, capture_output=True, text=True, timeout=timeout, cwd=plain)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def soon(fn, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if fn():
                return True
        except Exception:
            pass
        time.sleep(0.1)
    return False


def make_repo(name):
    path = tmp / "src" / name
    path.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "remote", "add", "origin", f"git@github.com:Acme/{name}.git"], check=True)
    return path


def logged_in(yes):
    AUTH.write_text("true" if yes else "false")


def record(address):
    key, agent = address.rsplit("/", 1)
    path = WORK / key / "iso" / "agents" / f"{agent}.json"
    return json.loads(path.read_text()) if path.exists() else None


def journal_path(address):
    key, agent = address.rsplit("/", 1)
    return WORK / key / "iso" / "journal" / f"{agent}.jsonl"


def journal(address):
    path = journal_path(address)
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def queue_file(address):
    key, agent = address.rsplit("/", 1)
    path = WORK / key / "iso" / "journal" / f"{agent}.queue.json"
    return [p["text"] for p in json.loads(path.read_text())] if path.exists() else []


def prompts(address, via=None):
    return [e for e in journal(address) if e["kind"] == "prompt" and (via is None or e.get("via") == via)]


def sessions(address):
    return [e for e in journal(address) if e["kind"] == "session"]


def notices(address):
    return [e["text"] for e in journal(address) if e["kind"] == "notice"]


def chunks(address):
    return [e["update"]["content"].get("text", "") for e in journal(address)
            if e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk"]


def state(address):
    key, agent = address.rsplit("/", 1)
    path = HOME / "run" / key.replace("/", "+") / f"{agent}.state"
    return path.read_text().splitlines()[0] if path.exists() and path.read_text() else None


def wait_idle(address, timeout=30):
    iso.wait(lambda: state(address) in ("idle", "ready"), f"{address} idle", timeout)


def reply(address, text, prefix, timeout=30):
    before = len(chunks(address))
    rc, _, err = run("send", address, text)
    assert rc == 0, err
    iso.wait(lambda: prefix in "".join(chunks(address)[before:]), f"{address}'s reply to {text!r}", timeout)
    wait_idle(address)


def snapshot(address):
    sid = record(address)["session"]
    path = Path(iso.env["FAKE_ACP_LOG"] + ".sessions") / f"{sid}.json"
    return json.loads(path.read_text()).get("system", "")


def tmux(*args):
    return subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], *args], capture_output=True, text=True).stdout


def tmux_session(address):
    key, agent = address.rsplit("/", 1)
    return "=iso2-" + key.replace("/", "+") + "+" + agent


def restarted(address, sessions_before, timeout=30):
    """iso restart, then waits for the next session entry and the agent idle."""
    rc, out, err = run("restart", address)
    assert rc == 0, (rc, out, err)
    iso.wait(lambda: len(sessions(address)) > sessions_before, f"{address}'s next session", timeout)
    wait_idle(address)
    time.sleep(1)


def project_key(path):
    return re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(path))


ROLE_STAMP = "[isovim: your role is now "

try:
    logged_in(True)

    print("# 9c. the first sync keeps a key only the peer has")
    peer.mkdir(parents=True)
    now = time.time()
    ours = HOME / "config.json"
    ours.write_text(json.dumps({"self": "me", "hosts": {"peer": "peerhost"}, "a": 1, "gone": 1}))
    os.utime(ours, (now - 100, now - 100))
    (peer / "config.json").write_text(json.dumps({"self": "peer", "idle_after": 300, "repo_defaults": {"o/r": {"x": 1}}}))
    os.utime(peer / "config.json", (now - 1000, now - 1000))
    sync_env = {"ISOVIM_PEERS": "peer=peerhost"}
    rc, out, err = run("sync", env=sync_env)
    got = json.loads((peer / "config.json").read_text())
    check(rc == 0 and got.get("a") == 1 and got.get("gone") == 1, "the first sync sends our keys", (rc, err, got))
    check(got.get("idle_after") == 300 and got.get("repo_defaults") == {"o/r": {"x": 1}},
          "and keeps the keys only the peer has, though our file is newer", got)
    stamps = json.loads((peer / "config.keys.json").read_text())
    check(stamps.get("idle_after", {}).get("h") not in (None, ""), "they're recorded with their value's hash, not as gone", stamps)
    mine = json.loads(ours.read_text())
    del mine["gone"]
    ours.write_text(json.dumps(mine))
    os.utime(ours, (now - 10, now - 10))
    run("sync", env=sync_env)
    got = json.loads((peer / "config.json").read_text())
    check("gone" not in got and got.get("idle_after") == 300, "a key deleted here is still deleted there", got)
    ours.write_text(json.dumps({"self": "me"}))

    print("\n# 9d. the built-in text on promotion")
    lab = make_repo("lab")
    rc, W, err = run("spawn", "--repo", str(lab), "--name", "w")
    check(rc == 0 and W == "acme/lab/a0", "a worker in acme/lab", (rc, W, err))
    wait_idle(W)
    reply(W, "first words", "reply to: first words")
    text = snapshot(W)
    check("a promotion gives you the new role's instructions in a message from isovim" in text,
          "it says a promotion gives the new role's instructions in a message from isovim", text[:200])
    check("reloads with the new role's prompt" not in text, "not that the session reloads with the new role's prompt")

    print("\n# 7. a journal with no role hash counts as changed")
    n = len(sessions(W))
    path = journal_path(W)
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    for row in rows:
        if row["kind"] == "session":
            for field in ("prompt_hash", "role_hash"):
                row.pop(field, None)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))
    restarted(W, n)
    given = prompts(W, "role")
    check(len(given) == 1 and given[0]["text"].startswith(ROLE_STAMP + "worker]"),
          "the resumed session gets its role's prompt as a message", [p.get("text", "")[:60] for p in given])
    check(any("gave it the worker's prompt as a message" in t for t in notices(W)), "the chat says so", notices(W)[-3:])
    restarted(W, len(sessions(W)))
    check(len(prompts(W, "role")) == 1, "once: the next restart sends nothing", len(prompts(W, "role")))

    print("\n# 9d. an agent from the isovim before the wording gets no role message")
    OLD = tmp / "old"
    OLD.mkdir()
    archive = subprocess.run(["git", "-C", str(REPO), "archive", OLD_REV], capture_output=True, check=True)
    subprocess.run(["tar", "-x", "-C", str(OLD)], input=archive.stdout, check=True)
    lab2 = make_repo("lab2")
    rc, U, err = run("spawn", "--repo", str(lab2), "--name", "u", bin=str(OLD / "bin" / "iso"))
    check(rc == 0 and U == "acme/lab2/a0", "the old isovim spawns a worker", (rc, U, err))
    wait_idle(U, 60)
    reply(U, "old words", "reply to: old words")
    check("reloads with the new role's prompt" in snapshot(U), "its session has the old wording", snapshot(U)[:80])
    restarted(U, len(sessions(U)))
    check(not prompts(U, "role"), "restarted on this isovim, it gets no role message", [p["text"][:60] for p in prompts(U, "role")])
    reply(U, "still here", "reply to: still here")
    prompt_file = HOME / "prompts" / "worker.md"
    check(prompt_file.exists(), "the worker's prompt file is seeded", prompt_file)
    prompt_file.write_text(prompt_file.read_text() + "\nAlso: say EDITED.\n")
    restarted(U, len(sessions(U)))
    given = prompts(U, "role")
    check(len(given) == 1 and "Also: say EDITED." in given[0]["text"], "an edited role prompt file still sends one", [p["text"][-40:] for p in given])
    restarted(W, len(sessions(W)))
    check(len(prompts(W, "role")) == 2, "to every agent it reaches, as its file changed", len(prompts(W, "role")))
    run("rm", U)

    print("\n# 8. the current transcript wins after a migration's copy")
    sid = record(W)["session"]
    own = CONFIG / "projects" / project_key(WORK / "acme" / "lab" / "a0")
    stale = CONFIG / "projects" / "-aaa-before-the-move"
    own.mkdir(parents=True, exist_ok=True)
    stale.mkdir(parents=True)
    old_rows = [{"type": "user", "message": {"role": "user", "content": "OLD WORDS"}},
                {"type": "assistant", "message": {"content": [{"type": "text", "text": "old answer"}]}}]
    new_rows = old_rows + [{"type": "user", "message": {"role": "user", "content": "NEW WORDS"}},
                           {"type": "assistant", "message": {"content": [{"type": "text", "text": "new answer"}]}}]
    (stale / f"{sid}.jsonl").write_text("".join(json.dumps(r) + "\n" for r in old_rows))
    (own / f"{sid}.jsonl").write_text("".join(json.dumps(r) + "\n" for r in new_rows))
    later = time.time() - 50
    os.utime(own / f"{sid}.jsonl", (later, later))
    rc, out, err = run("transcript", W)
    text = Path(out).read_text() if rc == 0 and out and Path(out).exists() else ""
    check("NEW WORDS" in text, "iso transcript reads the one under the agent's dir, not the stale copy", (rc, out, err, text[-200:]))

    print("\n# 8. iso handover's work reaches the journal")
    (own / f"{sid}.jsonl").write_text((stale / f"{sid}.jsonl").read_text())
    wait_idle(W)
    rc, out, err = run("handover", "--no-attach", W)
    check(rc == 0, "iso handover hands it over", (rc, out, err))
    iso.wait(lambda: (tmp / "claude-ran").exists(), "claude on the pane")
    tmux("send-keys", "-t", tmux_session(W) + ":", "bye", "Enter")
    iso.wait(lambda: any(e["kind"] == "handover" and e.get("state") == "end" for e in journal(W)), "back from claude", 20)
    came = [e for e in journal(W) if e.get("handover")]
    check(any(e["kind"] == "prompt" and e.get("text") == "hello from claude's screen" for e in came),
          "what was said on Claude's screen is in the journal", came)
    check(not any(e.get("text") == "OLD WORDS" for e in came), "and nothing from before the handover again", came)
    wait_idle(W)
    run("rm", W)

    print("\n# 9a. the retry delay doubles")
    A = run("spawn", "--name", "a")[1]
    wait_idle(A)
    run("send", A, "limit")
    tries = lambda: [e["ts"] for e in journal(A) if e["kind"] == "turn" and e.get("state") == "start"]
    soon(lambda: len(tries()) >= 4, 25)
    times = tries()
    check(len([p for p in prompts(A) if p["text"] == "limit"]) == 1, "journaled once, not per try", prompts(A))
    gaps = [round(b - a, 1) for a, b in zip(times, times[1:])]
    check(len(gaps) >= 3 and gaps[1] >= 1.7 * gaps[0] and gaps[2] >= 1.7 * gaps[1],
          "tried again after 1s, 2s, 4s, ...", gaps)
    held = [t for t in notices(A) if t.startswith("its prompts are held")]
    check(len(held) == 1, "the held notice is said once, not at every try", held)
    run("rm", A)

    print("\n# 9b. a spawn prompt held while logged out survives the supervisor")
    logged_in(False)
    rc, C, err = run("spawn", "--name", "c", "first task")
    check(rc == 0, "spawned while logged out", (rc, C, err))
    iso.wait(lambda: state(C) == "held" and sessions(C), "C held, its session open", 30)
    check(soon(lambda: queue_file(C) == ["first task"], 5), "the spawn prompt is kept on disk", queue_file(C))
    tmux("kill-session", "-t", tmux_session(C))
    iso.wait(lambda: run("status", C)[1] == "stopped", "C's supervisor gone", 20)
    logged_in(True)
    run("send", C, "second")
    check(soon(lambda: [p["text"] for p in prompts(C)] == ["first task", "second"], 30),
          "logged in, the spawn prompt goes once, then what was sent after", [p["text"] for p in prompts(C)])
    wait_idle(C)
    run("rm", C)
finally:
    iso.stop()

print(f"\nfailures: {len(fails)}")
sys.exit(1 if fails else 0)
