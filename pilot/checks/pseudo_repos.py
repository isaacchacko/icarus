"""The pseudo-repos general/ and root/ as real keys, and the one-time move of the old ~/iso/_/.

A spawn in no repo is general/aN; iso rootmode on host spawns the host root as root/aN. An old world
made by the isovim from before (its tree unpacked from git at $PSEUDO_OLD_REV, default 68cd736):
the host root at _/a0 and a worker at _/a1, both running over pilot/fake-acp-agent, the root's
stamped message to the worker, rootmode.json naming _/a0, a stopped child with parent _/a0 and a
repo agent with parent pilothost:_/a1. The TUI's start, while the worker is mid-turn, defers the
move; once it's idle the TUI's retry moves it: the root to root/a0 and the worker to general/a1,
both running again on the sessions they had, their chats (journals) whole, every reference
updated. iso send reaches them by new and old (_/aN) addresses, the root's stamps verify (one from
before the move, one from after), the sidebar shows the root pinned and general; --repo _ is still
general; a second start moves nothing and restarts nobody. Then a fresh _/ whose numbers collide
with general's moves on an iso command, renumbered. A real owner named root gets root_/ as its folder.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/pseudo_repos.py"""

import json
import os
import subprocess
import sys
import time
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


iso = Iso("pseudo", agent_delay=0.3)
iso.env["ISOVIM_SELF"] = "pilothost"
WORK = iso.tmp / "work"
HOME = iso.tmp / "home"
OLD = iso.tmp / "old"
OLD_BIN = str(OLD / "bin" / "iso")
plain = iso.tmp / "plain"
plain.mkdir()


def run(*args, bin=BIN, timeout=120, stdin=None, cwd=None):
    r = subprocess.run([bin, *args], env=iso.env, capture_output=True, text=True, timeout=timeout, input=stdin, cwd=cwd or plain)
    return r.returncode, r.stdout.strip(), r.stderr


def old(*args, **kw):
    return run(*args, bin=OLD_BIN, **kw)


def record(address):
    key, agent = address.rsplit("/", 1)
    path = WORK / key / "iso" / "agents" / f"{agent}.json"
    return json.loads(path.read_text()) if path.exists() else None


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


def tmux(*args):
    return subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], *args], capture_output=True, text=True).stdout


def sessions():
    return tmux("list-sessions", "-F", "#{session_name}").split()


def pane_pid(name):
    out = tmux("list-panes", "-t", "=" + name, "-F", "#{pane_pid}").strip()
    return int(out) if out.isdigit() else None


def fake_frames():
    path = Path(iso.env["FAKE_ACP_LOG"])
    return [json.loads(line)["frame"] for line in path.read_text().splitlines() if '"frame"' in line] if path.exists() else []


def migrate_log():
    path = HOME / "migrate.log"
    return path.read_text() if path.exists() else ""


def stamped(address, needle):
    return next((p for p in prompts(address) if needle in p), None)


def checkstamp(address, prompt):
    return run("checkstamp", address, stdin=json.dumps({"prompt": prompt}))[1]


def idle(address):
    return state(address) in ("idle", "ready")


try:
    # The isovim from before general/ and root/, unpacked from git.
    OLD.mkdir()
    archive = subprocess.run(["git", "-C", str(REPO), "archive", OLD_REV], capture_output=True, check=True)
    subprocess.run(["tar", "-x", "-C", str(OLD)], input=archive.stdout, check=True)

    print("# the old world, made by the old isovim")
    rc, out, err = old("rootmode", "on", "host")
    check(rc == 0 and "_/a0" in out, "the old rootmode on host puts the host root at _/a0", (rc, out, err))
    rc, worker, err = old("spawn", "--name", "worker1")
    check(rc == 0 and worker == "_/a1", "the old spawn in no repo makes _/a1", (rc, worker, err))
    iso.wait(lambda: idle("_/a0") and idle("_/a1"), "both old agents ready", 60)
    old("send", "_/a1", "first words to the worker")
    iso.wait(lambda: idle("_/a1") and len([e for e in journal("_/a1") if e["kind"] == "update"]) > 0, "the worker answered", 30)
    # The root sends the worker a stamped message, from inside its own pane (the fake runs it).
    old("send", "_/a0", f"run {OLD_BIN} send _/a1 hello-before-the-move")
    iso.wait(lambda: stamped("_/a1", "hello-before-the-move"), "the root's stamped message reached the worker", 30)
    before_stamp = stamped("_/a1", "hello-before-the-move")
    check("[from pilothost:_/a0 · root · m" in before_stamp, "it carries the root's stamp", before_stamp)
    iso.wait(lambda: idle("_/a0") and idle("_/a1"), "both idle", 30)
    root_session, worker_session = record("_/a0")["session"], record("_/a1")["session"]
    root_prompts, worker_prompts = prompts("_/a0"), prompts("_/a1")
    check(root_session and worker_session and len(worker_prompts) >= 2, "sessions and journals", (root_session, worker_session, worker_prompts))
    # A stopped child of the root, and a repo agent whose parent is the worker on this host.
    (WORK / "_" / "a2").mkdir()
    (WORK / "_" / "iso" / "agents" / "a2.json").write_text(json.dumps(
        {"id": "a2", "name": "child", "kind": "claude", "acp": True, "role": "worker", "parent": "_/a0"}))
    (WORK / "acme" / "app" / "iso" / "agents").mkdir(parents=True)
    (WORK / "acme" / "app" / "a0").mkdir()
    (WORK / "acme" / "app" / "iso" / "agents" / "a0.json").write_text(json.dumps(
        {"id": "a0", "name": "a0", "kind": "claude", "acp": True, "role": "worker", "repo": "acme/app", "parent": "pilothost:_/a1"}))
    mode = json.loads((HOME / "rootmode.json").read_text())
    check(mode["host"]["agent"] == "_/a0", "the old rootmode.json names _/a0", mode)
    check(sorted(s for s in sessions() if s.startswith("iso2-_")) == ["iso2-_+a0", "iso2-_+a1"], "both run under the old names", sessions())

    print("\n# the TUI starts while the worker is mid-turn: the move waits")
    old("send", "_/a1", "slow 6")
    iso.wait(lambda: state("_/a1") == "working", "the worker working")
    iso.start()
    check((WORK / "_").is_dir() and "deferred: _/a1 is working" in migrate_log(), "the move is deferred", migrate_log())
    iso.wait(lambda: not (WORK / "_").exists(), "the TUI's retry moves _/ once the worker is idle", 90)
    log = iso.wait(lambda: "done: _/ is gone" in migrate_log() and migrate_log(), "the move done", 30)
    print(log)
    check("done: _/ is gone" in log, "migrate.log says what it did", log)

    print("\n# where everything went")
    root, wk = record("root/a0"), record("general/a1")
    check(root and root["role"] == "root" and root["id"] == "a0" and root.get("session") == root_session,
          "the host root is root/a0, its session id kept", root)
    check(wk and wk["id"] == "a1" and wk["name"] == "worker1" and wk.get("session") == worker_session,
          "the worker is general/a1, its session id kept", wk)
    check(record("general/a2").get("parent") == "root/a0", "the child's parent is root/a0", record("general/a2"))
    check(record("acme/app/a0").get("parent") == "pilothost:general/a1", "a repo agent's host-qualified parent too", record("acme/app/a0"))
    mode = json.loads((HOME / "rootmode.json").read_text())
    check(mode["host"]["agent"] == "root/a0", "rootmode.json names root/a0", mode)
    check(run("root")[1] == "pilothost:root/a0", "and it holds your authority", run("root"))
    check(prompts("root/a0")[: len(root_prompts)] == root_prompts and prompts("general/a1")[: len(worker_prompts)] == worker_prompts,
          "both journals are whole at their new place", (prompts("root/a0"), prompts("general/a1")))
    check(not (WORK / "_").exists() and not (HOME / "run" / "_").exists(), "no _/ left, nor run/_", list(WORK.iterdir()))
    check(json.loads((HOME / "migrated.json").read_text()) == {"_/a0": "root/a0", "_/a1": "general/a1", "_/a2": "general/a2"},
          "migrated.json maps the old addresses", (HOME / "migrated.json").read_text())

    print("\n# both running again, on their sessions")
    iso.wait(lambda: {"iso2-root+a0", "iso2-general+a1"} <= set(sessions()), "both run under their new names", 30)
    check(not any(s.startswith("iso2-_") for s in sessions()), "the old names are gone", sessions())
    iso.wait(lambda: idle("root/a0") and idle("general/a1"), "both ready again", 60)
    frames = fake_frames()
    resumed = {f["params"]["sessionId"]: str(Path(f["params"]["cwd"]).resolve()) for f in frames
               if f.get("method") in ("session/resume", "session/load")}
    check(resumed.get(root_session) == str((WORK / "root" / "a0").resolve()), "the root resumed its session from root/a0", resumed)
    check(resumed.get(worker_session) == str((WORK / "general" / "a1").resolve()), "the worker resumed its own from general/a1", resumed)
    pids = {name: pane_pid(name) for name in ("iso2-root+a0", "iso2-general+a1")}

    print("\n# new and old addresses")
    for address, text in (("root/a0", "to-root-new"), ("_/a0", "to-root-old"), ("general/a1", "to-worker-new"), ("_/a1", "to-worker-old")):
        rc, _, err = run("send", address, text)
        check(rc == 0, f"iso send {address}", err)
    iso.wait(lambda: stamped("root/a0", "to-root-new") and stamped("root/a0", "to-root-old"), "both reach root/a0", 30)
    iso.wait(lambda: stamped("general/a1", "to-worker-new") and stamped("general/a1", "to-worker-old"), "both reach general/a1", 30)
    check(True, "iso send reaches each by its new and its old address")
    iso.wait(lambda: idle("root/a0") and idle("general/a1"), "idle", 30)

    print("\n# stamps from the root")
    said = checkstamp("general/a1", before_stamp)
    check("from your root" in said, "a stamp from before the move still verifies, from the root", said)
    run("send", "root/a0", f"run {BIN} send general/a1 hello-after-the-move")
    iso.wait(lambda: stamped("general/a1", "hello-after-the-move"), "the root's new stamped message", 30)
    after = stamped("general/a1", "hello-after-the-move")
    check("[from pilothost:root/a0 · root · m" in after, "a new one names root/a0 and the root", after)
    said = checkstamp("general/a1", after)
    check("from your root" in said, "and verifies", said)

    print("\n# the sidebar")
    iso.lua("require('isovim.sidebar').refresh()")
    rows = iso.wait(lambda: (r := iso.sidebar()) and any("worker1" in x for x in r) and r, "the worker listed", 20)
    kinds = iso.lua("return require('isovim.sidebar').debug_kinds()")
    print("\n".join(rows))
    first_agent = kinds.index("agent")
    lines = iso.lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(...), 0, -1, false)", iso.sidebar_win())
    check("root" in lines[first_agent], "the root pinned first", (kinds, lines))
    general = next((i for i, (k, l) in enumerate(zip(kinds, lines)) if k == "repo" and "general" in l), None)
    check(general is not None and any("worker1" in l for l in lines[general:]), "general lists the worker", lines)
    check(iso.lua("return require('isovim.sidebar').group_key('general')") == "general"
          and iso.lua("return require('isovim.sidebar').group_key('root')") == "root", "group keys are general and root")
    # The root's chat opens at its new address with what it said before.
    chat = iso.lua("local c = require('isovim.acp.chat').open('root', 'a0', require('isovim').main_win()) return c.buf")
    text = iso.wait(lambda: (t := "\n".join(iso.lua("return vim.api.nvim_buf_get_lines(..., 0, -1, false)", chat))) and "to-root-old" in t and t,
                    "the root's chat", 20)
    check(root_prompts[0][:30] in text, "the root's chat shows its conversation from before the move", text[-400:])

    print("\n# _ as an input alias")
    rc, alias, err = run("spawn", "--repo", "_", "--name", "viaalias")
    check(rc == 0 and alias == "general/a3", "iso spawn --repo _ is general", (rc, alias, err))
    rc, loose, err = run("spawn", "--name", "loose")
    check(rc == 0 and loose == "general/a4", "a spawn in no repo is general/aN", (rc, loose, err))
    check(not (WORK / "_").exists(), "nothing writes _/ again")
    rc, out, err = run("ls")
    check(rc == 0 and "root/a0" in out and "general/a1" in out and "_/" not in out, "iso ls lists the new addresses", out)

    print("\n# a second start moves nothing")
    lines_before = len(migrate_log().splitlines())
    iso.close_tui()
    iso.start()
    run("ls")
    check(len(migrate_log().splitlines()) == lines_before, "no new migrate.log lines", migrate_log().splitlines()[lines_before:])
    check({name: pane_pid(name) for name in pids} == pids, "and nobody restarted", ({n: pane_pid(n) for n in pids}, pids))

    print("\n# a fresh _/ whose numbers collide, moved by an iso command")
    counter = int((WORK / "general" / "iso" / "next").read_text())
    for n, parent in ((1, None), (9, "_/a1")):
        (WORK / "_" / f"a{n}").mkdir(parents=True)
        (WORK / "_" / "iso" / "agents").mkdir(parents=True, exist_ok=True)
        (WORK / "_" / "iso" / "journal").mkdir(parents=True, exist_ok=True)
        spec = {"id": f"a{n}", "name": f"a{n}", "kind": "claude", "acp": True, "role": "worker"}
        if parent:
            spec["parent"] = parent
        (WORK / "_" / "iso" / "agents" / f"a{n}.json").write_text(json.dumps(spec))
        (WORK / "_" / "iso" / "journal" / f"a{n}.jsonl").write_text(json.dumps({"seq": 1, "kind": "prompt", "text": f"old a{n}"}) + "\n")
    rc, out, err = run("ls")
    check(rc == 0 and not (WORK / "_").exists(), "iso ls moved it", (rc, err, migrate_log()[-800:]))
    moved = record(f"general/a{counter}")
    check(moved and moved["id"] == f"a{counter}" and moved["name"] == f"a{counter}" and prompts(f"general/a{counter}") == ["old a1"],
          f"_/a1 collides with general/a1: it becomes general/a{counter}, journal and all", moved)
    check(record("general/a1")["name"] == "worker1", "the worker in general/a1 is untouched", record("general/a1"))
    nine = record("general/a9")
    check(nine and nine["parent"] == f"general/a{counter}" and prompts("general/a9") == ["old a9"],
          "_/a9 keeps its number, and its parent follows the renumbered one", nine)
    check(int((WORK / "general" / "iso" / "next").read_text()) == 10, "general's counter is past them", (WORK / "general" / "iso" / "next").read_text())
    check(f"_/a1's number is taken in general/: it becomes general/a{counter}" in migrate_log(), "migrate.log says why", migrate_log()[-1200:])

    print("\n# a real owner named root")
    rc, out, err = run("agent", "root/tools", "terminal", "--v2")
    check(rc == 0 and out == "root/tools/a0", "root/tools is a repo key", (rc, out, err))
    check((WORK / "root_" / "tools" / "a0").is_dir() and not (WORK / "root" / "tools").exists(), "in the folder root_/tools", list(WORK.iterdir()))
    rc, out, err = run("ls")
    check("root/tools/a0" in out and "root/a0" in out, "both listed", out)
finally:
    iso.stop()

print("\nfailures:", len(fails))
sys.exit(1 if fails else 0)
