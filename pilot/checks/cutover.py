"""L8's cutover, in a fake legacy world: workspaces with fake agents running, worktrees against a
bare fake remote (one dirty, one with an unpushed commit, one clean, one with no workspace), an
archived workspace, pins, PR registrations, tasks, the old root pointer, a new-layout agent and a
fake ~/.claude/projects. iso cutover --dry-run lists it all and touches nothing but its plan file.
iso cutover refuses without --yes, with the TUI open, when the plan file isn't a fresh dry run's,
and when a push is blocked. A push that fails mid-run stops the cutover before anything is stopped
or moved. A real run pushes to wip/<ws>/<agent> branches, stops the legacy agents, seeds repo
configs, base clones and work dirs, moves the old layout into legacy-backup-<date>/ (the worktrees
still work there), keeps the conversations and the new layout, and turns enforcement on. Before
that, enforcement changes nothing; after, the retired commands fail naming what replaced them,
and role mismatches and agents running the user's commands are refused.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/cutover.py"""

import hashlib
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


def git(*args, cwd=None, check=True):
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=check)
    return result.stdout.strip()


def commit(checkout, files, message):
    for name, text in files.items():
        path = checkout / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    git("add", "-A", cwd=checkout)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", message, cwd=checkout)


iso = Iso("cutover", agent_delay=0.2)
iso.env["ISOVIM_SELF"] = "pilothost"
iso.env["ISOVIM_BRANCH_PREFIX"] = "isaac/"
iso.env["CLAUDE_CONFIG_DIR"] = str(iso.tmp / "claude-config")
HOME = iso.tmp / "home"
TREES = HOME / "worktrees"


def run(*args, cwd=None, env=None, timeout=120):
    r = subprocess.run([BIN, *args], env={**iso.env, **(env or {})}, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def tmux_sessions():
    r = subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], "list-sessions", "-F", "#{session_name}"], capture_output=True, text=True)
    return set(r.stdout.split())


def snapshot(*roots):
    """Every file under the roots, with its mtime and a hash: what a read-only command must leave alone."""
    seen = {}
    for root in roots:
        for path in sorted(Path(root).rglob("*")):
            if path.is_file() and not path.is_symlink() and path.name != "cutover-plan.txt":
                stat = path.stat()
                seen[str(path)] = (stat.st_mtime_ns, hashlib.sha1(path.read_bytes()).hexdigest())
    return seen


def meta(ws):
    return json.loads((HOME / "workspaces" / ws / ".isovim.json").read_text())


def set_meta(ws, **fields):
    data = meta(ws)
    data.update(fields)
    (HOME / "workspaces" / ws / ".isovim.json").write_text(json.dumps(data))


counter = [0]


def inside(address, *cmds, env="", timeout=60):
    """Runs each iso command from inside the agent's pane; returns [(rc, out, err)]."""
    counter[0] += 1
    d = iso.tmp / f"in{counter[0]}"
    d.mkdir()
    lines = [f"{env} {BIN} {cmd} > {d}/{i}.out 2> {d}/{i}.err; echo $? > {d}/{i}.rc" for i, cmd in enumerate(cmds)]
    lines.append(f"touch {d}/done")
    (d / "s.sh").write_text("\n".join(lines) + "\n")
    rc, _, err = run("send", address, f"run bash {d}/s.sh")
    assert rc == 0, err
    iso.wait(lambda: (d / "done").exists(), f"commands in {address}", timeout)
    return [(int((d / f"{i}.rc").read_text()), (d / f"{i}.out").read_text(), (d / f"{i}.err").read_text()) for i in range(len(cmds))]


try:
    # The fake remote and its checkout: acme/app (with scripts to import) and acme/lib.
    remotes = iso.tmp / "remotes" / "acme"
    src = iso.tmp / "src"
    checkouts = {}
    for name, files in (("app", {".superset/config.json": json.dumps({"setup": ["echo app-setup"]}), "README": "app"}),
                        ("lib", {"README": "lib", ".isovim/config.json": json.dumps({"run": ["echo lib-run"]})})):
        remote = remotes / f"{name}.git"
        remote.mkdir(parents=True)
        git("init", "-q", "--bare", "-b", "main", str(remote))
        checkouts[name] = src / name
        git("clone", "-q", str(remote), str(checkouts[name]))
        git("checkout", "-qb", "main", cwd=checkouts[name])
        commit(checkouts[name], files, "first")
        git("push", "-q", "-u", "origin", "main", cwd=checkouts[name])
        git("remote", "set-head", "origin", "main", cwd=checkouts[name])
    app, lib = checkouts["app"], checkouts["lib"]
    app_remote = remotes / "app.git"

    # The conversations, which must be left alone.
    projects = iso.tmp / "claude-config" / "projects" / "-tmp-app"
    projects.mkdir(parents=True)
    (projects / "conv.jsonl").write_text('{"type": "user"}\n')

    # Legacy workspaces: three worktrees of app, one in lib's checkout, one in its own dir.
    def new(*args):
        rc, out, err = run("new", *args)
        assert rc == 0, err
        return out.strip()

    dirty = new("dirty", "--dir", str(app), "--worktree")
    ahead = new("ahead", "--dir", str(app), "--worktree")
    clean = new("clean", "--dir", str(app), "--worktree")
    libws = new("libws", "--dir", str(lib))
    own = new("own")
    old = new("old")
    tree = {ws: Path(os.path.expanduser(meta(ws)["dir"])) for ws in (dirty, ahead, clean)}
    (tree[dirty] / "README").write_text("changed, not committed\n")
    (tree[dirty] / "new-file").write_text("untracked\n")
    commit(tree[ahead], {"feature": "x"}, "unpushed work")
    ahead_head = git("rev-parse", "HEAD", cwd=tree[ahead])
    # A worktree with no workspace, holding an unpushed commit.
    orphan = TREES / "app" / "orphan-tree"
    git("worktree", "add", "-q", "-b", "isaac/orphan", str(orphan), "main", cwd=app)
    commit(orphan, {"orphan": "x"}, "orphan work")
    orphan_head = git("rev-parse", "HEAD", cwd=orphan)

    # Pins (isovim's and an older tool's key), PRs, tasks, a second agent, the old root pointer.
    set_meta(own, pinned=[{"path": "~/notes.md", "label": "notes"}], pins=[{"path": "~/old.md", "auto": True}],
             prs=["https://github.com/acme/app/pull/7"],
             agents=[{"id": "main", "name": "main", "kind": "claude",
                      "tasks": [{"id": "t1", "title": "one", "status": "doing"}, {"id": "t2", "title": "two", "status": "done"}]}])
    assert run("agent", own, "terminal", "--name", "term")[0] == 0
    run("pr", dirty, "https://github.com/acme/app/pull/9")
    assert run("archive", old)[0] == 0
    for ws in (dirty, ahead, libws, own):
        rc, _, err = run("open", f"{ws}/main")
        assert rc == 0, err
    assert run("root", f"{own}/main")[0] == 0
    # A tmux session left from a workspace that's gone.
    subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], "new-session", "-d", "-s", "isovim-abcdef-main", "sleep 600"], check=True)
    # A new-layout agent, which is kept.
    rc, v2, err = run("spawn", "--repo", str(lib), "--name", "keeper")
    v2 = v2.strip()
    check(rc == 0 and v2 == "acme/lib/a0", "a new-layout agent to keep", (rc, v2, err))
    v2_record = iso.tmp / "work" / "acme" / "lib" / "iso" / "agents" / "a0.json"
    running = tmux_sessions()
    check({f"isovim-{dirty}-main", f"isovim-{own}-main", f"isovim-{own}-term"} <= running, "the legacy agents are running", running)

    print("\n# before the cutover, enforcement changes nothing")
    res = inside(f"{own}/main", "ls", "router ls", env="")
    check(res[0][0] == 0 and "will be refused to agents later" in res[0][2], "an agent's bare iso ls only warns", res[0])
    check(res[1][0] == 0 and "(this will be refused later)" in res[1][2], "a worker's iso router ls only warns", res[1])
    res = inside(f"{own}/main", "ls", "router ls", f"worker fork {own}/main", "worker ls", env="ISOVIM_ENFORCE=1")
    check(res[0][0] == 1 and "iso: agents run iso worker ls; bare iso commands are the user's" in res[0][2] and "later" not in res[0][2],
          "ISOVIM_ENFORCE=1: an agent's bare iso ls is refused", res[0])
    check(res[1][0] == 1 and "you are a worker, not a router: run iso worker ls" in res[1][2], "ISOVIM_ENFORCE=1: a role mismatch is refused", res[1])
    check(res[2][0] == 1 and "a workspace's fork was retired" in res[2][2], "ISOVIM_ENFORCE=1: a workspace fork is refused", res[2])
    check(res[3][0] == 0 and res[3][2] == "", "ISOVIM_ENFORCE=1: iso worker ls from a worker runs", res[3])
    check(run("archived")[0] == 0 and run("task", "ls")[2].find("retired") < 0, "iso archived and task still run")
    rc, out, _ = run("help")
    check("iso new <name>" in out and "iso cutover --dry-run" in out, "help lists iso new and iso cutover", out[-400:])

    print("\n# iso cutover --dry-run")
    watched = (HOME, iso.tmp / "work", iso.tmp / "src", iso.tmp / "remotes", iso.tmp / "claude-config")
    # The agent that ran the commands above finishes its turn (its stop hook writes its state) first.
    for address in (f"{own}/main", f"{dirty}/main", f"{ahead}/main", f"{libws}/main"):
        run("wait", address, "--timeout", "30")
    deadline, before = time.time() + 30, snapshot(*watched)
    while time.time() < deadline:
        time.sleep(1.5)
        again = snapshot(*watched)
        if again == before:
            break
        print("     still settling:", sorted(k for k in set(before) | set(again) if before.get(k) != again.get(k)))
        before = again
    check(snapshot(*watched) == before, "the world is quiet before the dry run")
    rc, plan, err = run("cutover", "--dry-run")
    check(rc == 0, "the dry run runs", err)
    print(plan)
    after = snapshot(*watched)
    changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
    check(changed == [], "the dry run changes no file but its plan", changed)
    plan_file = HOME / "cutover-plan.txt"
    check(plan_file.read_text() == plan, "the plan is written to ~/.isovim/cutover-plan.txt", plan_file.exists())
    for ws in (dirty, ahead, clean, libws, own, old):
        check(ws in plan, f"the plan lists workspace {ws}")
    check(f"uncommitted changes -> wip/{dirty}/main on {app_remote} (a new branch)" in plan, "the dirty worktree goes to wip/<ws>/<agent>", plan)
    check(f"1 unpushed commit -> wip/{ahead}/main on {app_remote} (a new branch)" in plan, "the unpushed one too")
    check("clean, every commit on origin: nothing to push" in plan and f"wip/{clean}/" not in plan, "the clean one isn't pushed")
    check("(no workspace, branch isaac/orphan)" in plan and "-> wip/isaac/orphan on" in plan, "the orphan worktree is pushed to wip/<branch>")
    check(f"agent main (claude, running)  tasks: 1 doing, 1 done" in plan and "agent term (terminal, running)" in plan,
          "agents, their state and tasks are listed")
    check("pin ~/notes.md  \"notes\"" in plan and "pin ~/old.md" in plan and "PR https://github.com/acme/app/pull/7" in plan
          and "PR https://github.com/acme/app/pull/9" in plan, "pins (both keys) and PRs are listed")
    check("abcdef/main  (a tmux session with no workspace)" in plan, "a leftover legacy tmux session is stopped too")
    check(f"{v2}" not in plan.split("2. Stop")[1].split("3. Seed")[0], "the new-layout agent isn't stopped")
    check("acme/app, from" in plan and f"scripts imported from {lib}/.isovim/config.json" in plan, "the repos to seed, and lib's import", plan)
    check("cloned from origin, with" in plan, "base clones to make")
    today = time.strftime("%Y-%m-%d")
    check(f"legacy-backup-{today}/ (moved, not deleted)" in plan, "the backup dir")
    for rel in ("workspaces", "archive", "worktrees", "root"):
        check(f"/home/{rel}  " in plan, f"{rel} moves into the backup")
    check(f"the old root pointer: pilothost:{own}/main" in plan, "the old root pointer is named")
    check("claude-config/projects: the old conversations, untouched" in plan, "the conversations are kept")
    check("new-layout agents: 1 under" in plan, "the new-layout agent is kept")
    check(f"{libws}'s project dir, yours, untouched" in plan, "a project dir is left alone")
    check("BLOCKED" not in plan, "nothing blocks this plan")

    print("\n# iso cutover refuses")
    rc, out, err = run("cutover")
    check(rc == 1 and "--yes" in err, "without --yes", err)
    lock = HOME / "isovim.lock"
    lock.write_text(f"{os.getpid()}\n")
    rc, out, err = run("cutover", "--yes")
    check(rc == 1 and "close the isovim TUI first" in err, "with the TUI open", err)
    lock.unlink()
    plan_file.write_text(plan.replace("(a new branch)", "(a new branch!)", 1))
    rc, out, err = run("cutover", "--yes")
    check(rc == 1 and "isn't what you approved" in err and "a new branch!" in err, "when the plan file isn't a fresh dry run's", err)
    plan_file.unlink()
    rc, out, err = run("cutover", "--yes")
    check(rc == 1 and "run iso cutover --dry-run" in err, "with no plan file", err)
    git("remote", "set-url", "origin", str(iso.tmp / "nowhere.git"), cwd=app)
    rc, blocked, _ = run("cutover", "--dry-run")
    check("BLOCKED" in blocked and "can't be reached" in blocked, "an unreachable origin blocks the plan", blocked[:600])
    rc, out, err = run("cutover", "--yes")
    check(rc == 1 and "blocked" in err, "and the real run refuses it", err)
    git("remote", "set-url", "origin", str(app_remote), cwd=app)

    print("\n# a push that fails stops the cutover before anything else")
    hook = app_remote / "hooks" / "pre-receive"
    hook.write_text(f"#!/bin/sh\nwhile read old new ref; do [ \"$ref\" = refs/heads/wip/isaac/orphan ] && exit 1; done\nexit 0\n")
    hook.chmod(0o755)
    run("cutover", "--dry-run")
    rc, out, err = run("cutover", "--yes")
    check(rc == 1 and "cutover stopped" in err and "wip/isaac/orphan" in err and f"pushed {tree[ahead]}" in out, "the failed push stops it, after the ones before it", (out, err))
    check((HOME / "workspaces" / own).is_dir() and tree[dirty].is_dir() and not (HOME / "repos" / "acme" / "app" / "base-clone").exists(), "nothing was seeded or moved")
    check(f"isovim-{own}-main" in tmux_sessions(), "no agent was stopped")
    check("enforce" not in (json.loads((HOME / "config.json").read_text()) if (HOME / "config.json").exists() else {}), "enforce stays off")
    log = (HOME / "cutover.log").read_text()
    check("step 1 (push) failed" in log, "the log says where it stopped", log)
    hook.unlink()
    first_wip = git("rev-parse", f"refs/heads/wip/{dirty}/main", cwd=app_remote)
    (tree[dirty] / "later").write_text("more work since\n")
    rc, out, err = run("cutover", "--yes")
    check(rc == 1 and "isn't what you approved" in err, "the earlier push changed the plan, so it must be read again", err)

    print("\n# the real cutover")
    (HOME / "config.json").write_text('{\n  "self": "pilothost",\n  "repo_dirs": ["~/x"]\n}\n')
    projects_before = snapshot(iso.tmp / "claude-config")
    v2_before = v2_record.read_text()
    rc, plan, err = run("cutover", "--dry-run")
    check(f"already there at {first_wip[:12]}, which stays in its history" in plan, "a wip branch already pushed is noted", plan)
    rc, out, err = run("cutover", "--yes", timeout=300)
    check(rc == 0 and "cut over" in out, "iso cutover --yes runs", (rc, out[-2000:], err))
    print(out)
    remote_refs = git("for-each-ref", "--format=%(refname:short) %(objectname)", "refs/heads", cwd=app_remote)
    refs = dict(line.split() for line in remote_refs.splitlines())
    wip_dirty = refs.get(f"wip/{dirty}/main")
    check(wip_dirty and git("show", f"{wip_dirty}:README", cwd=app_remote) == "changed, not committed"
          and git("show", f"{wip_dirty}:new-file", cwd=app_remote) == "untracked", "the dirty worktree's work is on wip/<ws>/main", refs)
    check(git("show", f"{wip_dirty}:later", cwd=app_remote) == "more work since"
          and subprocess.run(["git", "merge-base", "--is-ancestor", first_wip, wip_dirty], cwd=app_remote).returncode == 0,
          "pushed again, it keeps the earlier wip tip in its history", refs)
    check(refs.get(f"wip/{ahead}/main") == ahead_head, "the unpushed commit is on its wip branch", refs)
    check(refs.get("wip/isaac/orphan") == orphan_head, "the orphan worktree's commit is on wip/isaac/orphan", refs)
    check(not any(r.startswith(f"wip/{clean}") for r in refs), "the clean worktree pushed nothing", refs)
    sessions = tmux_sessions()
    check(not any(s.startswith("isovim-") for s in sessions), "every legacy agent is stopped", sessions)
    check(any(s.startswith("iso2-") for s in sessions), "the new-layout agent still runs", sessions)
    app_config = json.loads((HOME / "repos" / "acme" / "app" / "config.json").read_text())
    check(app_config.get("setup") == ["echo app-setup"] and "color" in app_config, "acme/app's config is there, with its scripts", app_config)
    lib_config = json.loads((HOME / "repos" / "acme" / "lib" / "config.json").read_text())
    check(lib_config.get("run") == ["echo lib-run"] and "color" in lib_config, "acme/lib's config is seeded, its scripts imported", lib_config)
    check(not (HOME / "run" / "abcdef").exists(), "stopping the leftover session leaves no run dir behind")
    for name in ("app", "lib"):
        base = HOME / "repos" / "acme" / name / "base-clone"
        check((base / ".git").is_dir() and git("remote", "get-url", "origin", cwd=base) == str(remotes / f"{name}.git"), f"acme/{name}'s base clone")
        check((iso.tmp / "work" / "acme" / name / "iso").is_dir(), f"acme/{name}'s work dir")
    backup = HOME / f"legacy-backup-{today}"
    for rel in ("workspaces", "archive", "worktrees", "root", f"run/{own}"):
        check(not (HOME / rel).exists() and (backup / rel).exists(), f"{rel} moved into the backup")
    check((backup / "workspaces" / own / ".isovim.json").exists() and (backup / "archive" / old).is_dir(), "the workspaces are all there")
    moved = backup / "worktrees" / tree[dirty].relative_to(TREES)
    check(git("status", "--porcelain", cwd=moved) != "" and str(moved) in git("worktree", "list", cwd=app), "a moved worktree still works, and its repo knows it there",
          git("worktree", "list", cwd=app))
    check(snapshot(iso.tmp / "claude-config") == projects_before, "~/.claude/projects is untouched")
    check(v2_record.read_text() == v2_before, "the new-layout agent's record is kept")
    config_text = (HOME / "config.json").read_text()
    config = json.loads(config_text)
    check(config.get("enforce") is True and config.get("repo_dirs") == ["~/x"] and config.get("self") == "pilothost"
          and set(config.get("prompts", {})) >= {"worker", "router", "root"}, "config.json gets its prompts and enforce: true, the rest kept", config_text)
    log = (HOME / "cutover.log").read_text()
    check("cutover of pilothost done" in log and f"pushed" in log and f"stopped {own}/main" in log, "the log records each step", log[-1500:])
    check((backup / "cutover-plan.txt").exists() and not plan_file.exists(), "the approved plan is kept in the backup")

    print("\n# after the cutover: enforcement is on")
    for words, replacement in ((("new", "x"), "iso spawn"), (("pin", "x", "y"), "surface file|folder"), (("ask", "q"), "iso router surface question"),
                               (("task", "ls"), "tasks.md"), (("archived",), "legacy-backup"), (("prs", "x"), "iso listen"),
                               (("hide", "x/y"), "iso rm"), (("dir", "x"), "iso spawn --repo")):
        rc, out, err = run(*words)
        check(rc == 1 and f"iso {words[0]} was retired at the cutover" in err and replacement in err, f"iso {words[0]} is retired", err)
    rc, out, err = run("help")
    check("iso new <name>" not in out and "iso pin " not in out and "iso spawn" in out, "help leaves the retired commands out", out[-300:])
    rc, out, err = run("worker", "ls")
    check(rc == 1 and "is for agents, and this isn't one" in err, "iso worker ls from a shell is refused", err)
    rc, out, err = run("ls")
    check(rc == 0, "the user's own commands run", err)
    rc, out, err = run("archived", env={"ISOVIM_ENFORCE": "0"})
    check(rc == 0, "ISOVIM_ENFORCE=0 turns it off again", err)
    rc, plan, err = run("cutover", "--dry-run")
    check(rc == 0 and "Legacy workspaces: 0, and 0 archived" in plan, "a dry run afterwards finds nothing left", plan[:400])
finally:
    iso.stop()

print("\nFAILED: " + ", ".join(fails) if fails else "\nOK")
sys.exit(1 if fails else 0)
