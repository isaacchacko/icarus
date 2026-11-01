"""A worker's and a router's own work through the CLI (isovim.cli.work), resolved by who calls: iso worker
wt makes a new-layout agent's worktree at aN/w on $USER/<name> off origin's default branch, from the
repo's base clone (made when missing, from the clone the agent was made in), then runs worktree_setup;
again it only says so; --from takes an existing branch. iso <role> setup and run [<action>] run the
repo's scripts in the agent's work dir (aN/w, else aN), each in a pane of its own named for it, tagged
in its record (script, of), listed under Terminals with the robot; again restarts the same pane. A
router runs them too; a user shell is warned and refused; a workspace's agent keeps the workspace's
checkout and per-workspace panes. Completion offers the caller's repo's actions.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/actions.py"""

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

BIN = str(REPO / "bin" / "iso")
ROBOT = "\U000f06a9"
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def commit(checkout, files, message):
    for name, text in files.items():
        (checkout / name).write_text(text)
    git("add", "-A", cwd=checkout)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", message, cwd=checkout)


iso = Iso("actions", agent_delay=0.3)


def run(*args, env=None):
    r = subprocess.run([BIN, *args], env=env or iso.env, capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout, r.stderr


counter = [0]


def inside(address, *cmds, timeout=60):
    """Runs each iso command from inside the agent's pane; returns [(rc, out, err)]."""
    counter[0] += 1
    d = iso.tmp / f"in{counter[0]}"
    d.mkdir()
    lines = [f"{BIN} {cmd} > {d}/{i}.out 2> {d}/{i}.err; echo $? > {d}/{i}.rc" for i, cmd in enumerate(cmds)]
    lines.append(f"touch {d}/done")
    (d / "s.sh").write_text("\n".join(lines) + "\n")
    rc, _, err = run("send", address, f"run bash {d}/s.sh")
    assert rc == 0, err
    iso.wait(lambda: (d / "done").exists(), f"commands in {address}", timeout)
    return [(int((d / f"{i}.rc").read_text()), (d / f"{i}.out").read_text(), (d / f"{i}.err").read_text()) for i in range(len(cmds))]


def record(key, agent):
    return json.loads((iso.tmp / "work" / key / "iso" / "agents" / f"{agent}.json").read_text())


def pane_of(output):
    """The pane address `iso <role> setup|run` prints: '<which> runs in <address>, in <dir>: ...'."""
    return output.split(" runs in ", 1)[1].split(",", 1)[0]


def rows():
    return {row["id"]: row for row in json.loads(run("ls", "--json")[1])}


try:
    # A bare "remote" acme/app.git with main and a pushed feature branch, and a checkout of it.
    remote = iso.tmp / "remotes" / "acme" / "app.git"
    remote.mkdir(parents=True)
    git("init", "-q", "--bare", "-b", "main", str(remote))
    checkout = iso.tmp / "src" / "app"
    git("clone", "-q", str(remote), str(checkout))
    git("checkout", "-qb", "main", cwd=checkout)
    commit(checkout, {"README": "app\n"}, "first")
    git("push", "-q", "-u", "origin", "main", cwd=checkout)
    git("checkout", "-qb", "feature/x", cwd=checkout)
    commit(checkout, {"feature": "x\n"}, "feature")
    git("push", "-q", "origin", "feature/x", cwd=checkout)
    git("checkout", "-q", "main", cwd=checkout)
    git("branch", "-qD", "feature/x", cwd=checkout)
    git("remote", "set-head", "origin", "main", cwd=checkout)
    # The repo's personal config: scripts and actions that leave marks where they ran.
    folder = iso.tmp / "home" / "repos" / "acme" / "app"
    folder.mkdir(parents=True)
    (folder / "config.json").write_text(json.dumps({
        "worktree_setup": ["pwd > wt-setup-ran", "echo wt-setup-out"],
        "setup": ['pwd > "$SUPERSET_WORKSPACE_PATH/setup-ran"', 'echo "$SUPERSET_ROOT_PATH" > root-path'],
        "teardown": ["pwd > teardown-ran"],
        "run": ["pwd > run-ran", "sleep 300"],
        "actions": {"lint": ["pwd > lint-ran"], "fmt": ["echo fmt"]},
    }))
    user = os.environ.get("USER", "isovim")
    iso.start()
    work = iso.tmp / "work" / "acme" / "app"
    base = folder / "base-clone"

    print("\n# iso worker wt: aN/w from a base clone made on demand")
    a0 = run("agent", str(checkout), "claude", "--v2", "--name", "Fix Login")[1].strip()
    check(a0 == "acme/app/a0", "a v2 fake agent", a0)
    check(record("acme/app", "a0").get("checkout") == os.path.realpath(checkout), "its record keeps the clone it was made from", record("acme/app", "a0"))
    check(not base.exists(), "no base clone yet")
    (rc, out, err), = inside(a0, "worker wt")
    w = work / "a0" / "w"
    check(rc == 0 and out.strip() == str(w), "iso worker wt prints aN/w", (rc, out, err))
    check("warning" not in err, "a worker running iso worker wt isn't warned", err)
    check((base / ".git").is_dir(), "the base clone was made")
    branch = git("branch", "--show-current", cwd=w)
    check(branch == f"{user}/fix-login", "on $USER/<slug of its name>", branch)
    check(git("rev-parse", "HEAD", cwd=w) == git("rev-parse", "origin/main", cwd=base), "off origin's default branch")
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=w)
    check(os.path.realpath(common) == os.path.realpath(base / ".git"), "a worktree of the base clone", common)
    check(record("acme/app", "a0").get("branch") == branch, "the record keeps its branch", record("acme/app", "a0"))
    check((w / "wt-setup-ran").read_text().strip() == os.path.realpath(w), "worktree_setup ran in it", (w / "wt-setup-ran").read_text() if (w / "wt-setup-ran").exists() else "missing")
    check("wt-setup-out" in err and "wt-setup-out" not in out, "worktree_setup's output is on stderr", (out, err))

    (rc, out, err), = inside(a0, "worker wt")
    check(rc == 0 and out.strip() == str(w) and f"already has its worktree, on {branch}" in err, "again: says so, exit 0", (rc, out, err))
    check(len(git("worktree", "list", "--porcelain", cwd=base).split("worktree ")) == 3, "and makes no second worktree")

    print("\n# --from an existing branch")
    a1 = run("agent", "acme/app", "claude", "--v2")[1].strip()
    (rc, out, err), = inside(a1, "worker wt --from feature/x")
    w1 = work / "a1" / "w"
    check(rc == 0 and out.strip() == str(w1), "iso worker wt --from feature/x", (rc, out, err))
    check(git("branch", "--show-current", cwd=w1) == "feature/x" and (w1 / "feature").exists(), "on the branch", git("branch", "--show-current", cwd=w1))
    (rc, out, err), = inside(a1, "worker wt --from nope")
    check(rc == 0 and "already has its worktree" in err, "--from once it has one: still just says so", (rc, out, err))

    print("\n# setup and run <action>, in a pane of their own")
    (rc, out, err), = inside(a0, "worker setup")
    check(rc == 0, "iso worker setup", (rc, out, err))
    setup_pane = pane_of(out)
    setup_id = setup_pane.split("/")[-1]
    check(setup_pane.startswith("acme/app/a") and f"in {w}" in out, "it names its pane and runs in aN/w", out)
    iso.wait(lambda: (w / "setup-ran").exists() and (w / "root-path").exists(), "setup ran")
    check(os.path.realpath((w / "setup-ran").read_text().strip()) == os.path.realpath(w), "setup ran in aN/w", (w / "setup-ran").read_text())
    check(os.path.realpath((w / "root-path").read_text().strip()) == os.path.realpath(base), "SUPERSET_ROOT_PATH is the base clone", (w / "root-path").read_text())
    rec = record("acme/app", setup_id)
    check(rec["kind"] == "command" and rec["script"] == "setup" and rec["of"] == "a0" and rec["name"] == "setup", "its record is tagged", rec)

    (rc, out, err), = inside(a0, "worker run lint")
    lint_pane = pane_of(out)
    check(rc == 0 and lint_pane != setup_pane, "iso worker run lint: a pane of its own", (rc, out, err))
    iso.wait(lambda: (w / "lint-ran").exists(), "lint ran")
    check(record("acme/app", lint_pane.split("/")[-1])["script"] == "lint", "tagged lint")
    (rc, out, err), = inside(a0, "worker run")
    run_pane = pane_of(out)
    iso.wait(lambda: (w / "run-ran").exists(), "run ran")
    (rc, out, err), = inside(a0, "worker teardown")
    iso.wait(lambda: (w / "teardown-ran").exists(), "teardown ran")
    check(rc == 0 and record("acme/app", pane_of(out).split("/")[-1])["script"] == "teardown", "iso worker teardown, tagged", (rc, out, err))
    (w / "setup-ran").unlink()
    (rc, out, err), = inside(a0, "worker setup")
    check(rc == 0 and pane_of(out) == setup_pane, "setup again restarts the same pane", out)
    iso.wait(lambda: (w / "setup-ran").exists(), "setup ran again")
    (rc, out, err), = inside(a0, "worker run nope")
    check(rc == 1 and "acme/app has no action nope in " in err, "an action it lacks is refused", (rc, out, err))

    listed = rows()
    check(listed[setup_pane]["script"] == "setup" and listed[setup_pane]["of"] == "a0", "iso ls --json carries script and of", listed[setup_pane])
    check(listed[setup_pane]["dir"] == str(w), "and the pane's dir is aN/w", listed[setup_pane]["dir"])
    check("(script for a0)" in run("ls")[1], "iso ls says whose script it is")

    # Tagged, so the command text doesn't matter; panes from before the tag still count.
    check(iso.lua("return require('isovim.scripts').of({kind = 'command', cmd = 'make dev', script = 'dev'})") == "dev", "scripts.of reads the tag")
    old = "x; [ $code -eq 0 ] || echo 'iso: the run script failed (exit '$code')'; exec sh"
    check(iso.lua("return require('isovim.scripts').of({kind = 'command', cmd = ...})", old) == "run", "and falls back to an old pane's command")
    check(iso.lua("return require('isovim.scripts').of({kind = 'claude', script = 'x'})") is None, "only command panes are scripts")

    terms = iso.wait(lambda: (r := iso.sidebar("terminals")) and any("lint · acme/app/a0" in row for row in r) and r, "Terminals rows")
    print("terminals:", terms)
    for name in ("setup", "lint", "run", "teardown"):
        row = next((row for row in terms if f"{name} · acme/app/a0" in row), "")
        check(row.endswith(ROBOT), f"Terminals lists {name} · acme/app/a0 with the robot", terms)
    iso.lua("require('isovim').expanded['acme/app'] = true; require('isovim.sidebar').refresh()")
    host_list = iso.wait(lambda: (r := iso.sidebar()) and any("Fix Login" in row for row in r) and r, "acme/app expanded")
    check(not any(row.endswith(ROBOT) or "lint" in row or "setup" in row for row in host_list), "and the host list doesn't", host_list)
    shot = iso.screenshot("terminals")

    print("\n# a router runs them too; before its worktree, in aN")
    router = run("agent", str(checkout), "claude", "--v2", "--role", "router", "--name", "lead")[1].strip()
    rid = router.split("/")[-1]
    setup_r, wt_r, lint_r = inside(router, "router setup", "router wt", "router run lint")
    check(setup_r[0] == 0 and "warning" not in setup_r[2] and f"in {work / rid}:" in setup_r[1], "iso router setup, in aN before wt", setup_r)
    iso.wait(lambda: (work / rid / "setup-ran").exists(), "router setup ran in aN")
    check(wt_r[0] == 0 and wt_r[1].strip() == str(work / rid / "w"), "iso router wt", wt_r)
    check(git("branch", "--show-current", cwd=work / rid / "w") == f"{user}/lead", "on $USER/lead")
    iso.wait(lambda: (work / rid / "w" / "lint-ran").exists(), "router lint ran in its worktree")
    check(lint_r[0] == 0 and "warning" not in lint_r[2], "iso router run lint", lint_r)
    (rc, out, err), = inside(router, "worker setup")
    check(rc == 0 and "you are a router, not a worker: run iso router setup" in err, "a router running iso worker setup is warned, and it runs", (rc, out, err))

    print("\n# a user shell")
    rc, out, err = run("worker", "wt")
    check(rc == 1 and "is for agents, and this isn't one" in err and "acts on the agent running it" in err, "iso worker wt from a shell: warned and refused", (rc, out, err))
    rc, out, err = run("router", "run", "lint")
    check(rc == 1 and "acts on the agent running it" in err, "iso router run lint from a shell: refused", (rc, out, err))

    print("\n# a workspace's agent: the workspace's checkout and panes, as before")
    legacy = run("new", "legacy", "--dir", str(checkout))[1].strip()
    run("open", f"{legacy}/main")
    wt_l, setup_l, lint_l = inside(f"{legacy}/main", "worker wt", "worker setup", "worker run lint")
    check(wt_l[0] == 1 and "a workspace gets a worktree when it's made" in wt_l[2], "iso worker wt: a workspace's agent has no lazy worktree", wt_l)
    check(setup_l[0] == 0 and setup_l[1].startswith(f"setup runs in {legacy}/setup, in "), "iso worker setup: the workspace's setup pane", setup_l)
    iso.wait(lambda: (checkout / "setup-ran").exists(), "legacy setup ran in the checkout")
    check(os.path.realpath((checkout / "setup-ran").read_text().strip()) == os.path.realpath(checkout), "in its checkout")
    check(lint_l[0] == 0 and f"{legacy}/lint" in lint_l[1], "iso worker run lint: a workspace pane named lint", lint_l)
    iso.wait(lambda: (checkout / "lint-ran").exists(), "legacy lint ran in the checkout")
    meta = json.loads((iso.tmp / "home" / "workspaces" / legacy / ".isovim.json").read_text())
    tags = {a["id"]: a.get("script") for a in meta["agents"]}
    check(tags.get("setup") == "setup" and tags.get("lint") == "lint", "tagged in the workspace's agents", tags)
    terms = iso.wait(lambda: (r := iso.sidebar("terminals")) and any("lint · legacy" in row for row in r) and r, "legacy Terminals rows")
    check(next(row for row in terms if "setup · legacy" in row).endswith(ROBOT), "listed as setup · legacy with the robot", terms)
    tree_ws = run("new", "wtws", "--dir", str(checkout), "--worktree")[1].strip()
    tree_dir = iso.lua("return require('isovim.store').dir(...)", tree_ws)
    iso.wait(lambda: Path(tree_dir, "setup-ran").exists(), "a worktree workspace's setup ran on creation, as before", timeout=20)
    run("open", f"{tree_ws}/main")
    (rc, out, err), = inside(f"{tree_ws}/main", "worker wt")
    check(rc == 0 and out.strip() == tree_dir and "works in its workspace's worktree" in err, "iso worker wt in a worktree workspace prints its checkout", (rc, out, err))

    print("\n# completion: the caller's repo's actions")
    env = {**iso.env, "ISOVIM_WS": "acme/app"}
    rc, out, _ = run("__complete", "worker", "run", "", env=env)
    values = [line.split("\t")[0] for line in out.splitlines()[:-1]]
    check(values == ["fmt", "lint"], "iso worker run <Tab> in acme/app: its actions", out)
    rc, out, _ = run("__complete", "router", "run", "", env={**iso.env, "ISOVIM_WS": legacy})
    check([line.split("\t")[0] for line in out.splitlines()[:-1]] == ["fmt", "lint"], "a workspace's agent: its checkout's repo's", out)
    r = subprocess.run([BIN, "__complete", "worker", "run", ""], env=iso.env, cwd=checkout, capture_output=True, text=True)
    check([line.split("\t")[0] for line in r.stdout.splitlines()[:-1]] == ["fmt", "lint"], "no agent: the cwd's repo's", r.stdout)
    rc, out, _ = run("__complete", "worker", "")
    names = [line.split("\t")[0] for line in out.splitlines()]
    check(all(name in names for name in ("wt", "setup", "teardown", "run")), "iso worker <Tab> offers wt, setup, teardown, run", names)
    rc, out, _ = run("__complete", "worker", "wt", "-")
    check(out.splitlines()[0].startswith("--from"), "iso worker wt -<Tab> offers --from", out)
    rc, out, _ = run("worker", "help")
    check(all(f"iso worker {name}" in out for name in ("wt [--from", "setup|teardown", "run [<action>]")), "iso worker help lists them", out)
    rc, out, _ = run("router", "help")
    check("iso router wt" in out and "iso router pr" in out, "iso router help too", out[-600:])
    rc, out, _ = run("repo-root", "help")
    check("iso repo-root wt" not in out, "a repo-root has no wt")

    print("\n" + (f"ALL OK {shot}" if not fails else f"{len(fails)} FAILED: {fails}"))
finally:
    iso.stop()
sys.exit(1 if fails else 0)
