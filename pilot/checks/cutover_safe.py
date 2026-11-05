"""The cutover's safety on a failed or repeated run, and enforcement on the legacy paths (the final
review's items 4-6).

- Enforcement on (ISOVIM_ENFORCE=1): iso spawn --legacy, iso agent into a legacy workspace and
  iso agent --hidden are refused; in the TUI so are a new workspace (a, <leader>an), a workspace's
  new agent (A, <leader>aa) and unarchive.
- The dry run preflights seeding: with every worktree clean and origin unreachable, the plan is
  BLOCKED on the seed, and --yes stops no agent.
- A step 4 that fails partway still repairs and locks the worktrees it moved, so git worktree prune
  can't break the backup; the rerun goes on into the same backup, and repairs worktrees an earlier
  run moved without repairing.
- The backup holds a README with the exact undo steps, whose path the run prints; following it
  puts the legacy layout back, worktrees and all.
- The plan says only the legacy agents stop: new-layout agents, the host's root/aN among them, keep
  running, and they do.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/cutover_safe.py"""

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


iso = Iso("cutover_safe", agent_delay=0.2)
iso.env["ISOVIM_SELF"] = "pilothost"
iso.env["ISOVIM_BRANCH_PREFIX"] = "isaac/"
iso.env["CLAUDE_CONFIG_DIR"] = str(iso.tmp / "claude-config")
HOME = iso.tmp / "home"
TODAY = time.strftime("%Y-%m-%d")
BACKUP = HOME / f"legacy-backup-{TODAY}"


def run(*args, env=None, timeout=120):
    r = subprocess.run([BIN, *args], env={**iso.env, **(env or {})}, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


ENFORCE = {"ISOVIM_ENFORCE": "1"}


def tmux_sessions():
    r = subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], "list-sessions", "-F", "#{session_name}"], capture_output=True, text=True)
    return set(r.stdout.split())


def meta(ws):
    return json.loads((HOME / "workspaces" / ws / ".isovim.json").read_text())


def real(path):
    """path with symlinks resolved, as git prints it (on macOS the temp dir's /var is /private/var)."""
    return os.path.realpath(path)


def worktrees(main):
    """git worktree list --porcelain of main: {resolved path: {"locked": bool, "prunable": bool}}."""
    found, path = {}, None
    for line in git("worktree", "list", "--porcelain", cwd=main).splitlines():
        if line.startswith("worktree "):
            path = real(line[9:])
            found[path] = {"locked": False, "prunable": False}
        elif line.startswith("locked") and path:
            found[path]["locked"] = True
        elif line.startswith("prunable") and path:
            found[path]["prunable"] = True
    return found


def is_repo(path):
    return subprocess.run(["git", "-C", str(path), "rev-parse", "--git-dir"], capture_output=True).returncode == 0


def section(plan, start, end=None):
    text = plan.split(start, 1)[1] if start in plan else ""
    return text.split(end, 1)[0] if end and end in text else text


try:
    remotes = iso.tmp / "remotes" / "acme"
    remote = remotes / "app.git"
    remote.mkdir(parents=True)
    git("init", "-q", "--bare", "-b", "main", str(remote))
    app = iso.tmp / "src" / "app"
    git("clone", "-q", str(remote), str(app))
    git("checkout", "-qb", "main", cwd=app)
    commit(app, {"README": "app"}, "first")
    git("push", "-q", "-u", "origin", "main", cwd=app)
    git("remote", "set-head", "origin", "main", cwd=app)

    def new(*args):
        rc, out, err = run("new", *args)
        assert rc == 0, err
        return out.strip()

    tws = new("treews", "--dir", str(app), "--worktree")
    own = new("own")
    old = new("old")
    assert run("archive", old)[0] == 0
    tree = Path(os.path.expanduser(meta(tws)["dir"]))
    for ws in (tws, own):
        rc, _, err = run("open", f"{ws}/main")
        assert rc == 0, err
    rc, out, err = run("rootmode", "on", "host")
    check(rc == 0 and "root/a0" in out, "the host's root is root/a0, a new-layout agent", (rc, out, err))
    root_session = "iso2-root+a0"
    iso.wait(lambda: root_session in tmux_sessions(), "root/a0's session")

    print("\n# with enforcement on, the legacy paths refuse")
    rc, out, err = run("spawn", "--legacy", "a legacy one", env=ENFORCE)
    check(rc == 1 and "--legacy was retired at the cutover" in err, "iso spawn --legacy is refused", (rc, out, err))
    rc, out, err = run("agent", own, "claude", "--name", "h", "--hidden", env=ENFORCE)
    check(rc == 1 and "retired at the cutover" in err, "iso agent --hidden is refused", (rc, out, err))
    rc, out, err = run("agent", own, "terminal", "--name", "t", env=ENFORCE)
    check(rc == 1 and "a workspace's agents were retired at the cutover" in err, "iso agent into a legacy workspace is refused", (rc, out, err))
    check([a["id"] for a in meta(own).get("agents", [{"id": "main"}])] == ["main"], "and no agent was added", meta(own))
    rc, out, err = run("ls", "--json")
    workspaces_before = sorted({row["id"].split("/")[0] for row in json.loads(out)})

    iso.env.update(ENFORCE)
    iso.start()

    def refused_toasts():
        return [t for t in iso.toasts() if "retired at the cutover" in t or "archived any more" in t]

    iso.lua("require('isovim.sidebar').actions.isovim_add()")
    time.sleep(0.5)
    check(any("New workspaces were retired at the cutover" in t for t in iso.toasts()) and iso.mode() == "n",
          "the TUI's new workspace is refused, with no prompt for a name", (iso.toasts(), iso.mode()))
    iso.lua("require('isovim.sidebar').actions.isovim_add_agent({ ws = ..., ws_name = 'own', kind = 'workspace' })", own)
    time.sleep(0.5)
    check(any("A workspace's agents were retired at the cutover" in t for t in iso.toasts()) and iso.mode() == "n",
          "the TUI's new agent in a workspace is refused", (iso.toasts(), iso.mode()))
    iso.lua("require('isovim').unarchive()")
    time.sleep(0.5)
    check(any("archived any more" in t for t in iso.toasts()) and iso.mode() == "n", "the TUI's unarchive is refused",
          (iso.toasts(), iso.mode()))
    before = len(refused_toasts())
    iso.focus_sidebar()
    iso.keys("a")
    time.sleep(0.5)
    iso.keys("A")
    time.sleep(0.5)
    check(len(refused_toasts()) >= before + 2 and not any("is retiring" in t for t in iso.toasts())
          and iso.mode() == "n", "a and A in the sidebar say they're retired, not retiring", iso.toasts())
    rc, out, err = run("ls", "--json")
    check(sorted({row["id"].split("/")[0] for row in json.loads(out)}) == workspaces_before, "no workspace was made",
          (workspaces_before, out))
    iso.close_tui()
    iso.env.pop("ISOVIM_ENFORCE")

    print("\n# the dry run preflights the seeding")
    away = remotes / "app.git.away"
    remote.rename(away)
    rc, plan, err = run("cutover", "--dry-run")
    blocked = section(plan, "BLOCKED", "\n\n")
    check(rc == 0 and "acme/app" in blocked and "origin" in blocked and "can't be reached" in blocked,
          "with every worktree clean and origin down, the seed blocks the plan", plan[:1200])
    rc, out, err = run("cutover", "--yes")
    check(rc == 1 and "blocked" in err, "and --yes refuses it", (rc, out, err))
    check(f"isovim-{own}-main" in tmux_sessions(), "no agent was stopped", tmux_sessions())
    away.rename(remote)

    print("\n# with origin back")
    rc, plan, err = run("cutover", "--dry-run")
    check(rc == 0 and "BLOCKED" not in plan, "the plan is clear", plan[:1500])

    print("\n# a step 4 that fails partway")
    # The legacy runs move after the worktrees; a run dir that can't be renamed stops the step there.
    run_dir = HOME / "run"
    run_dir.chmod(0o555)
    try:
        rc, out, err = run("cutover", "--yes", timeout=300)
    finally:
        run_dir.chmod(0o755)
    moved = BACKUP / "worktrees" / tree.relative_to(HOME / "worktrees")
    check(rc == 1 and "step 4 (wipe) failed" in (HOME / "cutover.log").read_text() and moved.is_dir() and not tree.exists(),
          "step 4 fails after moving the worktrees", (rc, out, err))
    check(real(moved) in worktrees(app) and not worktrees(app)[real(moved)]["prunable"], "the worktrees it moved are repaired anyway",
          worktrees(app))
    check(worktrees(app).get(real(moved), {}).get("locked"), "and locked", worktrees(app))
    readme = BACKUP / "README.md"
    check(readme.exists() and str(readme) in out + err, "the backup's README is written, and its path printed", (out, err))
    git("-c", "gc.worktreePruneExpire=now", "worktree", "prune", "--expire", "now", cwd=app)
    check(is_repo(moved) and real(moved) in worktrees(app), "git worktree prune leaves the backup's worktree working", worktrees(app))
    check(f"isovim-{own}-main" not in tmux_sessions() and root_session in tmux_sessions(),
          "the legacy agents were stopped, root/a0 wasn't", tmux_sessions())

    print("\n# the rerun")
    # As a run before this fix left it: moved, but its repo still points at the old path.
    admin = Path(git("rev-parse", "--path-format=absolute", "--git-dir", cwd=moved))
    git("worktree", "unlock", str(moved), cwd=app)
    (admin / "gitdir").write_text(str(tree / ".git") + "\n")
    check(real(moved) not in worktrees(app), "(an unrepaired worktree from an earlier run)", worktrees(app))
    rc, plan, err = run("cutover", "--dry-run")
    step4 = section(plan, "4. Move", "\n\n")
    check(f"legacy-backup-{TODAY}/" in step4 and f"legacy-backup-{TODAY}-2" not in plan, "the rerun goes on into the same backup", step4)
    check("repair" in step4 and str(moved.relative_to(HOME)) in step4, "and plans to repair the worktree the earlier run moved", step4)
    rc, out, err = run("cutover", "--yes", timeout=300)
    check(rc == 0 and "cut over" in out, "the rerun runs", (rc, out, err))
    check(real(moved) in worktrees(app) and worktrees(app)[real(moved)]["locked"] and is_repo(moved),
          "it repairs and locks the earlier run's worktree", worktrees(app))
    check(str(readme) in out, "the README's path is printed", out)
    git("-c", "gc.worktreePruneExpire=now", "worktree", "prune", "--expire", "now", cwd=app)
    check(is_repo(moved) and real(moved) in worktrees(app), "prune leaves it alone", worktrees(app))
    for rel in ("workspaces", "archive", "worktrees", f"run/{own}", f"run/{tws}"):
        check((BACKUP / rel).exists() and not (HOME / rel).exists(), f"{rel} is in the one backup")
    check(not Path(f"{BACKUP}-2").exists(), "there's no second backup")

    print("\n# who keeps running, and what the plan said")
    last = plan.rstrip().split("\n\n")[-1]
    check("Only the legacy agents" in last and "root/a0" in last and "keep running" in last and "every agent" not in last,
          "the plan says only legacy agents stop, and root/a0 keeps running", last)
    check(root_session in tmux_sessions(), "root/a0 is still running", tmux_sessions())
    design = (REPO / "docs" / "design.md").read_text()
    words = " ".join(design.split()).lower()
    check("every legacy agent starts cold" in words,
          "docs/design.md says so",
          design[design.find("## Cutover"):][:900])

    print("\n# the README's undo")
    text = readme.read_text()
    print(text)
    check("enforce" in text and "worktree repair" in text and "worktree unlock" in text, "it covers enforce and the worktrees", text)
    blocks = re.findall(r"```sh\n(.*?)```", text, re.S)
    check(len(blocks) == 1, "its commands are one sh block", blocks)
    # The TUI makes these empty on start, which a plain mv back would land inside.
    (HOME / "workspaces").mkdir()
    (HOME / "archive").mkdir()
    config = json.loads((HOME / "config.json").read_text())
    config.pop("enforce")
    (HOME / "config.json").write_text(json.dumps(config, indent=2))
    script = iso.tmp / "undo.sh"
    script.write_text("set -e\n" + (blocks[0] if blocks else "false\n"))
    undo = subprocess.run(["bash", str(script)], env=iso.env, capture_output=True, text=True)
    check(undo.returncode == 0, "the undo runs", (undo.stdout, undo.stderr))
    check((HOME / "workspaces" / own / ".isovim.json").exists() and (HOME / "archive" / old).is_dir() and (HOME / "run" / own).is_dir(),
          "the workspaces, the archive and their run state are back", sorted(p.name for p in HOME.iterdir()))
    check(tree.is_dir() and is_repo(tree) and real(tree) in worktrees(app) and not worktrees(app)[real(tree)]["locked"],
          "the worktree is back where it was, known to its repo and unlocked", worktrees(app))
    rc, out, err = run("ls", "--json")
    check(rc == 0 and f"{own}/main" in out, "iso ls lists the legacy agents again", (rc, out, err))
finally:
    iso.stop()

print("\nFAILED: " + ", ".join(fails) if fails else "\nOK")
sys.exit(1 if fails else 0)
