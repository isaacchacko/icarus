"""A deferred move of the old ~/.iso/_/ leaves it fully live.

An old world made by the isovim from before general/ and root/ (its tree unpacked from git at
$PSEUDO_OLD_REV, default 68cd736): the host root at _/a0 and a worker at _/a1, both running, and an
old ~/.isovim/root naming another host's agent. Then claude is logged out (pilot/fake-auth), so the
new code's move of _/ is deferred (a restart would leave them unable to work). While it waits, the
new code sees _/ as it is: iso ls lists both, iso status and iso worker status _/a0 work, iso send
and iso msg reach them, the root's stamped message verifies as the root's, iso root and rootmode
name _/a0 as the host root (not the old file's agent), the sidebar pins it as root, and neither the
reaper's dry run nor iso sync touches _/. Once logged in, the next iso command moves it (root/a0,
general/a1), and all of that works at the new addresses and through the old _/aN ones.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/migrate_deferred.py"""

import hashlib
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

BIN = str(REPO / "bin" / "iso")
OLD_REV = os.environ.get("PSEUDO_OLD_REV", "68cd736")
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


iso = Iso("mdefer", agent_delay=0.3)
iso.env["ISOVIM_SELF"] = "pilothost"
WORK = iso.tmp / "work"
HOME = iso.tmp / "home"
OLD = iso.tmp / "old"
OLD_BIN = str(OLD / "bin" / "iso")
plain = iso.tmp / "plain"
plain.mkdir()


def run(*args, bin=BIN, timeout=120, stdin=None, env=None):
    r = subprocess.run([bin, *args], env=env or iso.env, capture_output=True, text=True, timeout=timeout, input=stdin, cwd=plain)
    return r.returncode, r.stdout.strip(), r.stderr


def old(*args, **kw):
    return run(*args, bin=OLD_BIN, **kw)


def journal(address):
    key, agent = address.rsplit("/", 1)
    path = WORK / key / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def prompts(address):
    return [e.get("text") or "" for e in journal(address) if e["kind"] == "prompt"]


def state(address):
    key, agent = address.rsplit("/", 1)
    path = HOME / "run" / key.replace("/", "+") / f"{agent}.state"
    return path.read_text().strip() if path.exists() else None


def idle(address):
    return state(address) in ("idle", "ready")


def stamped(address, needle):
    return next((p for p in prompts(address) if needle in p), None)


def checkstamp(address, prompt):
    return run("checkstamp", address, stdin=json.dumps({"prompt": prompt}))[1]


def migrate_log():
    path = HOME / "migrate.log"
    return path.read_text() if path.exists() else ""


def tmux(*args):
    return subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], *args], capture_output=True, text=True).stdout


def sessions():
    return tmux("list-sessions", "-F", "#{session_name}").split()


def tree(path):
    """Every file and dir under path, with its content's hash: what "untouched" compares."""
    found = {}
    for dirpath, dirnames, filenames in os.walk(path):
        for name in dirnames:
            found[os.path.relpath(os.path.join(dirpath, name), path)] = "dir"
        for name in filenames:
            full = os.path.join(dirpath, name)
            regular = os.path.isfile(full) and not os.path.islink(full)
            found[os.path.relpath(full, path)] = hashlib.sha256(Path(full).read_bytes()).hexdigest() if regular else "special"
    return found


def logged_in(yes):
    Path(iso.env["FAKE_AUTH_FILE"]).write_text("true" if yes else "false")


def live_checks(root_at, worker_at, aliases, tag):
    """What must hold of the root at root_at and the worker at worker_at: aliases are other
    addresses (the old _/aN) that must reach the same agents."""
    rc, out, err = run("ls")
    check(rc == 0 and root_at in out and worker_at in out, f"{tag}: iso ls lists {root_at} and {worker_at}", (rc, out, err))
    rows = json.loads(run("ls", "--json")[1] or "[]")
    ids = [row.get("id") for row in rows]
    check(root_at in ids and worker_at in ids, f"{tag}: iso ls --json has both", ids)
    for address in [root_at, worker_at, *aliases]:
        rc, out, err = run("worker", "status", address)
        check(rc == 0 and out in ("idle", "working", "attention", "unread"), f"{tag}: iso worker status {address}", (rc, out, err))
        rc, out, err = run("status", address)
        check(rc == 0, f"{tag}: iso status {address}", (rc, out, err))
    rc, out, err = run("root")
    check(rc == 0 and out == "pilothost:" + root_at, f"{tag}: iso root names {root_at}, not the old file's", (rc, out, err))
    if iso.nvim:
        # It's looked up at most every half second.
        try:
            holder = iso.wait(lambda: (h := iso.lua("return require('isovim.root').holder()")) == root_at and h, "the holder", 5)
        except AssertionError:
            holder = iso.lua("return require('isovim.root').holder()")
        check(holder == root_at, f"{tag}: the TUI's holder lookup is {root_at}", holder)
        active = iso.lua("return require('isovim.rootmode').active('host')")
        check(active == root_at, f"{tag}: rootmode says {root_at} is the active host root", active)
    pairs = [(worker_at, worker_at), (root_at, root_at)] + list(zip(aliases, [root_at, worker_at]))
    for n, (address, target) in enumerate(pairs):
        for verb in ("send", "msg"):
            text = f"{tag}-{verb}-{n}"
            rc, _, err = run(verb, address, text)
            check(rc == 0, f"{tag}: iso {verb} {address}", err)
            if rc == 0:
                try:
                    iso.wait(lambda: stamped(target, text), f"{text} reaching {target}", 30)
                except AssertionError as error:
                    check(False, f"{tag}: iso {verb} {address} reached {target}", str(error)[:300])
            iso.wait(lambda: idle(root_at) and idle(worker_at), "both idle", 30)
    # The root sends the worker a stamped message with the new iso: once moved, from inside its
    # pane (the fake runs it). While deferred claude is logged out, so the root can't run anything
    # itself: the command runs in a second pane of the root's tmux session (iso2-_+a0, its old
    # name), which isovim takes as the root's own.
    word = f"{tag}-from-the-root"
    target = aliases[1] if aliases else worker_at
    if root_at.startswith("_/"):
        script = iso.tmp / f"as-root-{tag}.sh"
        script.write_text("#!/bin/sh\n" + "".join(f"export {k}={shlex.quote(v)}\n" for k, v in iso.env.items())
                          + f"cd {shlex.quote(str(plain))}\n{BIN} send {target} {word} >{iso.tmp}/as-root.out 2>&1\n")
        os.chmod(script, 0o755)
        made = subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], "new-window", "-d", "-t", "=iso2-_+a0:", str(script)],
                              capture_output=True, text=True)
        check(made.returncode == 0, f"{tag}: a second pane in the root's session told to send", made.stderr)
    else:
        rc, _, err = run("send", root_at, f"run {BIN} send {target} {word}")
        check(rc == 0, f"{tag}: the root told to send", err)
    try:
        iso.wait(lambda: stamped(worker_at, word), "the root's stamped message", 30)
    except AssertionError as error:
        check(False, f"{tag}: the root's stamped message reached the worker", (str(error)[:300], journal(root_at)[-4:],
              (iso.tmp / "as-root.out").read_text() if (iso.tmp / "as-root.out").exists() else None))
        return
    stamp = stamped(worker_at, word)
    check(f"[from pilothost:{root_at} · root · m" in stamp, f"{tag}: it carries the root's stamp, naming {root_at}", stamp)
    said = checkstamp(worker_at, stamp)
    check("from your root" in said, f"{tag}: and verifies as from your root", said)
    iso.wait(lambda: idle(root_at) and idle(worker_at), "both idle", 30)
    return stamp


try:
    OLD.mkdir()
    # PSEUDO_GIT_DIR: the repo to take it from, for running this check from an unpacked tree.
    archive = subprocess.run(["git", "-C", os.environ.get("PSEUDO_GIT_DIR", str(REPO)), "archive", OLD_REV], capture_output=True, check=True)
    subprocess.run(["tar", "-x", "-C", str(OLD)], input=archive.stdout, check=True)

    print("# the old world, made by the old isovim")
    rc, out, err = old("rootmode", "on", "host")
    check(rc == 0 and "_/a0" in out, "the old rootmode on host puts the host root at _/a0", (rc, out, err))
    rc, worker, err = old("spawn", "--name", "worker1")
    check(rc == 0 and worker == "_/a1", "the old spawn in no repo makes _/a1", (rc, worker, err))
    iso.wait(lambda: idle("_/a0") and idle("_/a1"), "both old agents ready", 60)
    old("send", "_/a1", "first words to the worker")
    iso.wait(lambda: idle("_/a1") and any(e["kind"] == "update" for e in journal("_/a1")), "the worker answered", 30)
    # The old `iso root` file, naming an agent on another host (as clu's was).
    (HOME / "root").write_text("cluhost:clu/a0\n")
    mode = json.loads((HOME / "rootmode.json").read_text())
    check(mode["host"]["agent"] == "_/a0", "the old rootmode.json names _/a0", mode)

    print("\n# logged out: the move is deferred, and _/ stays live")
    logged_in(False)
    rc, out, err = run("ls")
    check((WORK / "_").is_dir() and "nothing moves until it's logged in" in migrate_log(), "the move is deferred", (migrate_log(), err))
    iso.start()
    check((WORK / "_").is_dir(), "the TUI's start defers it too")
    deferred_stamp = live_checks("_/a0", "_/a1", [], "deferred")

    print("\n# the sidebar while deferred")
    iso.lua("require('isovim.sidebar').refresh()")
    try:
        iso.wait(lambda: (r := iso.sidebar()) and any("worker1" in x for x in r) and r, "the worker listed", 20)
    except AssertionError as error:
        check(False, "the sidebar lists the worker", str(error)[:600])
    kinds = iso.lua("return require('isovim.sidebar').debug_kinds()")
    lines = iso.lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(...), 0, -1, false)", iso.sidebar_win())
    print("\n".join(lines))
    first_agent = kinds.index("agent") if "agent" in kinds else None
    check(first_agent is not None and "root" in lines[first_agent], "the root pinned first", (kinds, lines))
    general = next((i for i, (k, l) in enumerate(zip(kinds, lines)) if k == "repo" and "general" in l), None)
    check(general is not None and any("worker1" in l for l in lines[general:]), "general lists the worker", lines)
    check(not any(k == "repo" and l.strip() in ("_", "▾ _", "▸ _") for k, l in zip(kinds, lines)), "no group of its own named _", lines)

    print("\n# the reaper and sync leave a deferred _/ alone")
    before = tree(WORK / "_")
    run_before = tree(HOME / "run" / "_")
    rc, out, err = run("reap", "--dry-run")
    check(rc == 0, "iso reap --dry-run", (rc, out, err))
    check("_/" not in out.replace("general/", "").replace("root/", "") or "orphan" not in out, "the dry run names nothing in _/", out)
    # A fake peer for iso sync: ssh runs the remote side here, in a dir of the peer's own.
    peer = iso.tmp / "peer"
    peer.mkdir()
    (iso.tmp / "ssh-env").write_text("")
    ssh = iso.tmp / "ssh"
    ssh.write_text(f"#!/usr/bin/env bash\ncd {peer} && exec {REPO}/pilot/fake-ssh \"$@\"\n")
    os.chmod(ssh, 0o755)
    sync_env = {**iso.env, "ISOVIM_PEERS": "peer=peerhost", "ISOVIM_SSH": str(ssh), "FAKE_SSH_ENV": str(iso.tmp / "ssh-env"),
                "ISOVIM_SYNC_ROOT": "isovim-home"}
    rc, out, err = run("sync", env=sync_env)
    check(rc == 0, "iso sync", (rc, out, err))
    check(tree(WORK / "_") == before, "_/ is untouched by both", set(tree(WORK / "_").items()) ^ set(before.items()))
    check(tree(HOME / "run" / "_") == run_before or set(tree(HOME / "run" / "_")) == set(run_before), "and so is run/_", (run_before, tree(HOME / "run" / "_")))
    check(not any("_" == p.name for p in peer.rglob("_")), "nothing of _/ reached the peer")
    check((WORK / "_").is_dir() and not (WORK / "root" / "iso" / "agents" / "a0.json").exists(), "still deferred: nothing moved")

    print("\n# logged in: the next iso command moves it")
    logged_in(True)
    iso.close_tui()
    rc, out, err = run("ls")
    check(not (WORK / "_").exists() and "done: _/ is gone" in migrate_log(), "iso ls moved it", (rc, err, migrate_log()[-1500:]))
    iso.wait(lambda: {"iso2-root+a0", "iso2-general+a1"} <= set(sessions()), "both run under their new names", 30)
    iso.wait(lambda: idle("root/a0") and idle("general/a1"), "both ready again", 60)
    iso.start()
    live_checks("root/a0", "general/a1", ["_/a0", "_/a1"], "moved")
    said = checkstamp("general/a1", deferred_stamp or "")
    check("from your root" in said, "the root's stamp from while it was deferred still verifies", said)
    iso.lua("require('isovim.sidebar').refresh()")
    iso.wait(lambda: (r := iso.sidebar()) and any("worker1" in x for x in r) and r, "the worker listed", 20)
    kinds = iso.lua("return require('isovim.sidebar').debug_kinds()")
    lines = iso.lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(...), 0, -1, false)", iso.sidebar_win())
    check("root" in lines[kinds.index("agent")], "the sidebar pins the moved root first", (kinds, lines))
finally:
    iso.stop()

print("\nfailures:", len(fails))
sys.exit(1 if fails else 0)
