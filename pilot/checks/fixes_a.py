"""The spec review's lane A fixes (data loss and wrong target).
1. Destructive commands (rm, restart, move, archive, a promotion's target) take an exact address:
   a stale aN that prefixes a live one, a bare repo key, a trailing slash and a name's prefix are
   errors, while read-only commands still match a prefix.
2. Sync: rsync --update keeps a peer's newer repos/ file; config.json is merged key by key, the newer
   winning (stamps in config.keys.json, else the file's mtime), and "reaper" stays each host's own.
3. Reaper: the dry run imports no scripts from an orphan's own files (so writes no repo config and
   starts no sync); a repo whose records dir is empty is refused; an aN with a running tmux session
   or a supervisor up on its socket is skipped, live too.
4. Queue: a prompt queued when the supervisor exits is kept on disk and delivered after it starts
   again, and the journal's queue (the chat's count) is the rebuilt one.
5. Offline: with origin unreachable, the first edit still makes the worktree, from the base clone's
   last-known origin ref, and says so; an edit in the user's own checkout is refused before and
   after the worktree exists.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/fixes_a.py"""

import json
import os
import socket
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


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def make_repo(iso, owner, name):
    origin = iso.tmp / "origins" / owner / f"{name}.git"
    origin.mkdir(parents=True)
    git("init", "-q", "--bare", "-b", "main", str(origin))
    src = iso.tmp / "src" / name
    src.mkdir(parents=True)
    git("init", "-q", "-b", "main", cwd=src)
    (src / "README.md").write_text(f"{name}\n")
    git("add", "-A", cwd=src)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init", cwd=src)
    git("remote", "add", "origin", str(origin), cwd=src)
    git("push", "-q", "-u", "origin", "main", cwd=src)
    git("remote", "set-head", "origin", "main", cwd=src)
    return src, origin


def backdate(path, seconds=3600):
    then = time.time() - seconds
    os.utime(path, (then, then), follow_symlinks=False)


iso = Iso("fixes_a", agent_delay=0.2)
home, work, tmp = iso.tmp / "home", iso.tmp / "work", iso.tmp
home.mkdir()
ssh = tmp / "ssh"
ssh.write_text(f"""#!/usr/bin/env bash
args=("$@"); i=0
while [ "${{args[$i]}}" = -o ] || [ "${{args[$i]}}" = -t ]; do [ "${{args[$i]}}" = -o ] && i=$((i+1)); i=$((i+1)); done
host="${{args[$i]}}"
mkdir -p {tmp}/hosts/"$host" && cd {tmp}/hosts/"$host" && exec {REPO}/pilot/fake-ssh "$@"
""")
os.chmod(ssh, 0o755)
(tmp / "ssh-env").write_text("")
peer = tmp / "hosts" / "peerhost" / "isovim-home"
iso.env.update(ISOVIM_SSH=str(ssh), FAKE_SSH_ENV=str(tmp / "ssh-env"), ISOVIM_SYNC_ROOT="isovim-home", ISOVIM_SELF="pilothost")


def run(*args, cwd=None, env=None, timeout=90):
    r = subprocess.run([BIN, *args], env={**iso.env, **(env or {})}, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def lua(code, *args):
    return iso.lua(code, *args)


def journal(address):
    key, agent = address.rsplit("/", 1)
    path = work / key / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def chunks(address):
    return [e["update"]["content"].get("text", "") for e in journal(address)
            if e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk"]


def reply(address, text, prefix, timeout=30):
    before = len(chunks(address))
    rc, _, err = run("send", address, text)
    assert rc == 0, err
    return iso.wait(lambda: next((c for c in chunks(address)[before:] if c.startswith(prefix)), None),
                    f"{address}'s reply to {text!r}", timeout)


try:
    iso.start()
    src, origin = make_repo(iso, "o", "r")

    print("# 1. destructive commands take an exact address")
    made = [iso.cli("agent", str(src), "terminal", "--v2", "--name", f"t{i}") for i in range(11)]
    check(made[0] == "o/r/a0" and made[10] == "o/r/a10", "eleven new-layout agents, a0 to a10", made)
    iso.cli("rm", "o/r/a1")
    rc, _, err = run("rm", "o/r/a1")
    check(rc == 1 and (work / "o" / "r" / "a10").exists() and "matches \"" in err,
          "a retried rm of a removed a1 is an error, and a10 stays", (rc, err))
    rc, _, err = run("rm", "o/r")
    check(rc == 1 and "isn't an agent's address" in err and (work / "o" / "r" / "a0").exists(), "iso rm o/r is an error", (rc, err))
    rc, _, err = run("rm", "o/r/")
    check(rc == 1 and "isn't an agent's address" in err, "iso rm o/r/ is an error", (rc, err))
    rc, _, err = run("restart", "o/r/a1")
    check(rc == 1 and "matches \"" in err, "restart takes an exact address too", (rc, err))
    rc, out, _ = run("status", "o/r/a1")
    check(rc == 0, "a read-only command still matches a prefix", (rc, out))
    ws = iso.cli("new", "alphabet")
    rc, _, err = run("move", "alpha", "elsewhere")
    check(rc == 1 and "no workspace matches" in err, "move takes the workspace's exact id or name", (rc, err))
    rc, _, err = run("archive", "alpha")
    check(rc == 1 and "no workspace matches" in err and ws in iso.cli("ls"), "archive too", (rc, err))
    rc, _, err = run("rm", f"{ws}/ma")
    check(rc == 1 and "matches \"" in err, "an agent's name prefix is an error for rm", (rc, err))
    rc, _, err = run("rm", "o/r/t10")
    check(rc == 0 and not (work / "o" / "r" / "a10").exists(), "an exact name still removes", (rc, err))
    promote = (REPO / "lua" / "isovim" / "cli" / "roles.lua").read_text()
    check("c.resolve_agent(target or promoter, true)" in promote, "a promotion's target is resolved exactly")

    print("\n# 2. sync never sends stale over newer")
    peer.mkdir(parents=True)
    now = time.time()
    ours = home / "config.json"
    ours.write_text(json.dumps({"self": "me", "hosts": {"peer": "peerhost"}, "a": 1, "b": 1, "reaper": "live"}))
    os.utime(ours, (now - 1000, now - 1000))
    (peer / "config.json").write_text(json.dumps({"self": "peer", "hosts": {"me": "mehost"}}))
    os.utime(peer / "config.json", (now - 2000, now - 2000))
    sync_env = {"ISOVIM_PEERS": "peer=peerhost"}
    rc, out, err = run("sync", env=sync_env)
    got = json.loads((peer / "config.json").read_text())
    check(rc == 0 and got.get("a") == 1 and got.get("b") == 1 and got["self"] == "peer", "a first sync sends config.json", (rc, out, err, got))
    check("reaper" not in got, "reaper stays this host's own", got)
    # The peer edits a (later than our a); we edit b later still.
    got["a"] = 2
    (peer / "config.json").write_text(json.dumps(got))
    os.utime(peer / "config.json", (now - 500, now - 500))
    mine = json.loads(ours.read_text())
    mine["b"] = 2
    ours.write_text(json.dumps(mine))
    rc, out, err = run("sync", env=sync_env)
    got = json.loads((peer / "config.json").read_text())
    check(rc == 0 and got.get("a") == 2 and got.get("b") == 2, "per key the newer wins: the peer keeps its a, gets our b", (got, err))
    log = (home / "sync.log").read_text()
    check("peer keeps its newer a" in log, "the kept key is logged", log)
    # A peer whose config predates any stamps, and is newer: its file wins.
    (peer / "config.keys.json").unlink()
    got["c"] = "theirs"
    (peer / "config.json").write_text(json.dumps(got))
    mine["c"] = "ours"
    ours.write_text(json.dumps(mine))
    os.utime(ours, (now - 300, now - 300))
    run("sync", env=sync_env)
    got = json.loads((peer / "config.json").read_text())
    check(got.get("c") == "theirs", "without stamps, the newer file wins", got)
    # repos/: --update.
    rdir = home / "repos" / "o" / "r"
    rdir.mkdir(parents=True, exist_ok=True)
    (rdir / "config.json").write_text(json.dumps({"teardown": ["echo old"]}))
    os.utime(rdir / "config.json", (now - 900, now - 900))
    prdir = peer / "repos" / "o" / "r"
    prdir.mkdir(parents=True, exist_ok=True)
    (prdir / "config.json").write_text(json.dumps({"teardown": ["echo new"]}))
    rc, out, err = run("sync", env=sync_env)
    check(rc == 0 and json.loads((prdir / "config.json").read_text()) == {"teardown": ["echo new"]},
          "rsync --update: a peer's newer repo config isn't overwritten by an older one", (rc, err, (prdir / "config.json").read_text()))
    (rdir / "config.json").write_text(json.dumps({"teardown": ["echo newest"]}))
    run("sync", env=sync_env)
    check(json.loads((prdir / "config.json").read_text()) == {"teardown": ["echo newest"]}, "and a newer one still goes")
    (rdir / "config.json").unlink()
    ours.write_text(json.dumps({"self": "me"}))

    print("\n# 3. the reaper")
    r = work / "o" / "r"
    orphan = r / "a20"
    (orphan / "w" / ".superset").mkdir(parents=True)
    mark = tmp / "orphan-teardown.mark"
    (orphan / "w" / ".superset" / "config.json").write_text(json.dumps({"setup": ["echo x"], "teardown": [f"touch {mark}"]}))
    git("init", "-q", cwd=orphan / "w")
    git("remote", "add", "origin", "https://github.com/o/r.git", cwd=orphan / "w")
    for d in (orphan / "w", orphan):
        backdate(d)
    sync_log = home / "sync.log"
    sync_before = sync_log.read_text() if sync_log.exists() else ""
    rc, out, err = run("reap", env=sync_env)
    check(rc == 0 and "would tear down o/r/a20" in out and "run teardown" in out, "the dry run reports the orphan and its teardown", (out, err))
    check(not (rdir / "config.json").exists(), "the dry run imports nothing into the repo's config", list(rdir.iterdir()) if rdir.exists() else None)
    time.sleep(1)
    check((sync_log.read_text() if sync_log.exists() else "") == sync_before, "and starts no sync")
    empty = work / "o" / "e"
    (empty / "iso" / "agents").mkdir(parents=True)
    (empty / "a3").mkdir()
    backdate(empty / "a3")
    running, supervised = r / "a21", r / "a22"
    for d in (running, supervised):
        d.mkdir()
        backdate(d)
    tmux = ["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"]]
    subprocess.run([*tmux, "new-session", "-d", "-s", "iso2-o+r+a21", "sleep 300"], check=True)
    sock_path = lua("return require('isovim.acp').socket('o/r', 'a22')")
    Path(sock_path).parent.mkdir(parents=True, exist_ok=True)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(sock_path)
    listener.listen(4)
    rc, out, err = run("reap", "--live", env=sync_env)
    print(out)
    check("refused o/e" in out and "is empty" in out and (empty / "a3").exists(), "live refuses a repo whose records dir is empty", out)
    check("skipped o/r/a21: its tmux session is running" in out and running.exists(), "live skips an aN with a tmux session", out)
    check("skipped o/r/a22: its supervisor is up" in out and supervised.exists(), "live skips an aN whose supervisor is up", out)
    check(not orphan.exists() and mark.exists(), "and still tears a real orphan down", out)
    check(not (rdir / "config.json").exists(), "a live teardown's lookup imports nothing either")
    listener.close()
    subprocess.run([*tmux, "kill-session", "-t", "=iso2-o+r+a21"])

    print("\n# 4. the queue outlives its supervisor")
    rc, a, err = run("spawn", "--repo", str(src), "--name", "q")
    check(rc == 0, "an ACP agent", (rc, a, err))
    reply(a, "hello", "reply to:")
    rc, _, err = run("send", a, "slow 30")
    iso.wait(lambda: any(e["kind"] == "prompt" and e["text"] == "slow 30" for e in journal(a)), "the slow turn to start")
    rc, out, err = run("send", a, "after the restart")
    queued = next((e for e in journal(a) if e["kind"] == "queued" and e["text"] == "after the restart"), None)
    qfile = work / "o" / "r" / "iso" / "journal" / f"{a.rsplit('/', 1)[1]}.queue.json"
    check(queued and qfile.exists() and json.loads(qfile.read_text())[0]["id"] == queued["id"], "a queued prompt is kept on disk", qfile)
    rc, _, err = run("restart", a)
    check(rc == 0, "iso restart", err)
    delivered = iso.wait(lambda: next((e for e in journal(a) if e["kind"] == "prompt" and e["id"] == queued["id"]), None),
                         "the kept prompt delivered after the restart", 60)
    entries = journal(a)
    rebuilt = [e for e in entries if e["kind"] == "queue" and e["seq"] < delivered["seq"] and e["seq"] > queued["seq"]]
    check(delivered and rebuilt and [i["id"] for i in rebuilt[-1]["items"]] == [queued["id"]],
          "the restarted supervisor journals the rebuilt queue, then delivers it", rebuilt)
    iso.wait(lambda: not qfile.exists(), "the queue file gone once it's empty")
    check(True, "once delivered, the queue on disk is empty")
    lua("require('isovim').open(...)", "o/r", a.rsplit("/", 1)[1])
    count = iso.wait(lambda: lua("local c = require('isovim.acp.chat').get(...) return c and tostring(#c.queue) or nil",
                                 "o/r", a.rsplit("/", 1)[1]), "the chat", 10)
    check(count == "0", "the chat's queue count is the rebuilt queue (0 once delivered)", count)

    print("\n# 5. offline, and the user's checkout")
    base = Path(iso.cli("repo", "base", "o/r", "--from", str(src)))
    rc, b, err = run("spawn", "--name", "edits", cwd=src)
    check(rc == 0, "an agent spawned from the user's clone", (rc, b, err))
    reply(b, "hello", "reply to:")
    origin.rename(origin.with_suffix(".gone"))
    w = work / "o" / "r" / b.rsplit("/", 1)[1] / "w"
    first = reply(b, f"write {src / 'mine.txt'} x", "blocked:", 60)
    check("Offline" in first and "last-known" in first and (w / ".git").exists(), "offline, the first edit still makes the worktree and says so", first)
    check(git("rev-parse", "HEAD", cwd=w) == git("rev-parse", "origin/main", cwd=base), "from the base clone's last-known origin/main")
    setup_log = Path(lua("return require('isovim.store').run_dir('o/r')")) / f"{b.rsplit('/', 1)[1]}.worktree_setup.log"
    check(setup_log.exists() and "last-known" in setup_log.read_text(), "and it's logged", setup_log)
    check(not (src / "mine.txt").exists(), "the edit in the user's checkout wasn't made")
    again = reply(b, f"write {src / 'mine.txt'} x", "blocked:")
    check("your user's own checkout" in again and str(w / "mine.txt") in again and not (src / "mine.txt").exists(),
          "with w made, an edit in the user's checkout is still refused", again)
    ok = reply(b, f"write {w / 'mine.txt'} x", "write:")
    check((w / "mine.txt").exists(), "the edit under w/ goes through", ok)
finally:
    iso.stop()

print(f"\n{len(fails)} failure(s)" + (": " + ", ".join(fails) if fails else ""))
sys.exit(1 if fails else 0)
