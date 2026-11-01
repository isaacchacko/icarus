"""Lifecycle (L6): removing a new-layout agent tears it down (its script panes stop and go, the repo's
teardown runs in its worktree, the worktree is force-removed from the base clone, aN/ is deleted, and
it's published exited); the reaper's dry run logs an orphan aN/ without touching it, ignores recorded
agents, skips young dirs, refuses a repo whose records dir is missing, only ever unlinks a symlink and
never touches a base clone, runs on the TUI's timer, shows in checkhealth, and --live tears down;
config syncs to a fake peer on every write (repos/ without base-clone/, config.json merged keeping the
peer's self and hosts), fails soft on a down host and catches it up on the next write, and `iso sync`
reports each host; iso jump drills down with . and .. (`iso __jump`, with scripted fzf picks), jumps
straight on a single match, and the iso shell function from `iso completion zsh|bash` cds there;
<leader>ij runs the drill-down in a picker.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/lifecycle.py"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def make_repo(iso, owner, name, files=None):
    """A bare origin <tmp>/origins/<owner>/<name>.git and a checkout of it at <tmp>/src/<name>."""
    origin = iso.tmp / "origins" / owner / f"{name}.git"
    origin.mkdir(parents=True)
    git("init", "-q", "--bare", "-b", "main", str(origin))
    src = iso.tmp / "src" / name
    src.mkdir(parents=True)
    git("init", "-q", "-b", "main", cwd=src)
    for path, text in {"README.md": f"{name}\n", **(files or {})}.items():
        (src / path).parent.mkdir(parents=True, exist_ok=True)
        (src / path).write_text(text)
    git("add", "-A", cwd=src)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init", cwd=src)
    git("remote", "add", "origin", str(origin), cwd=src)
    git("push", "-q", "origin", "main", cwd=src)
    git("remote", "set-head", "origin", "main", cwd=src)
    return src


def backdate(path, seconds=3600):
    then = time.time() - seconds
    os.utime(path, (then, then), follow_symlinks=False)


iso = Iso("lifecycle", agent_delay=0.3)
home, work, tmp = iso.tmp / "home", iso.tmp / "work", iso.tmp
home.mkdir()
picks, fzf_log = tmp / "picks", tmp / "fzf.log"
# The fake peers: an ssh stand-in that runs the remote side here, in a dir of the host's own, and
# fails as a down host would while <tmp>/down exists.
(tmp / "ssh-env").write_text("")
(tmp / "remote-iso").write_text("#!/bin/sh\necho '[]'\n")
os.chmod(tmp / "remote-iso", 0o755)
ssh = tmp / "ssh"
ssh.write_text(f"""#!/usr/bin/env bash
args=("$@"); i=0
while [ "${{args[$i]}}" = -o ] || [ "${{args[$i]}}" = -t ]; do [ "${{args[$i]}}" = -o ] && i=$((i+1)); i=$((i+1)); done
host="${{args[$i]}}"
if [ "$host" = downhost ] && [ -e {tmp}/down ]; then echo "ssh: connect to host downhost: Connection refused" >&2; exit 255; fi
mkdir -p {tmp}/hosts/"$host" && cd {tmp}/hosts/"$host" && exec {REPO}/pilot/fake-ssh "$@"
""")
os.chmod(ssh, 0o755)
(tmp / "down").write_text("")
peer_home = tmp / "hosts" / "peerhost" / "isovim-home"
down_home = tmp / "hosts" / "downhost" / "isovim-home"
peer_home.mkdir(parents=True)
(peer_home / "config.json").write_text(json.dumps({"self": "peer", "hosts": {"me": "mehost"}, "old": True}))
(home / "config.json").write_text(json.dumps({"self": "me", "hosts": {"peer": "peerhost"}, "aliases": {"p": "peer"}, "repo_dirs": ["~/code"]}))
iso.env.update(
    ISOVIM_PEERS="peer=peerhost,down=downhost",
    ISOVIM_SSH=str(ssh),
    ISOVIM_REMOTE_BIN=str(tmp / "remote-iso"),
    FAKE_SSH_ENV=str(tmp / "ssh-env"),
    # Relative, so each fake host's copy lands in its own dir.
    ISOVIM_SYNC_ROOT="isovim-home",
    ISOVIM_FZF=str(REPO / "pilot" / "fake-fzf"),
    FAKE_FZF_PICKS=str(picks),
    FAKE_FZF_LOG=str(fzf_log),
    ISOVIM_REAP_INTERVAL="1",
)

src = make_repo(iso, "o", "r")
mark = tmp / "teardown.mark"
config_dir = home / "repos" / "o" / "r"
config_dir.mkdir(parents=True)
(config_dir / "config.json").write_text(json.dumps({"teardown": [f"pwd > {mark}"], "run": ["sleep 300"]}))


def lua(code, *args):
    return iso.lua(code, *args)


def agents():
    return {row["id"]: row for row in json.loads(iso.cli("ls", "--json"))}


def events():
    log = home / "events" / "events.jsonl"
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def jump(*picked, args=(), command="__jump"):
    picks.write_text("".join(f"{p}\n" for p in picked))
    result = subprocess.run([str(REPO / "bin" / "iso"), command, *args], env=iso.env, capture_output=True, text=True)
    return result.returncode, result.stdout.strip()


try:
    iso.start()

    # Teardown on removal.
    a0 = iso.cli("agent", str(src), "terminal", "--v2", "--name", "t1")
    a1 = iso.cli("agent", str(src), "terminal", "--v2", "--name", "t2")
    check(a0 == "o/r/a0" and a1 == "o/r/a1", "two new-layout agents", (a0, a1))
    base = Path(iso.cli("repo", "base", "o/r", "--from", str(src)))
    w = work / "o" / "r" / "a0" / "w"
    git("-C", str(base), "worktree", "add", "-q", "-b", "t1", str(w))
    (w / "README.md").write_text("unsaved edit\n")
    (w / "untracked.txt").write_text("unsaved\n")
    pane = lua("return require('isovim.scripts').start('o/r', 'run', 'a0')")
    iso.wait(lambda: f"o/r/{pane}" in agents() and agents()[f"o/r/{pane}"]["status"] != "stopped", "the run script's pane")
    iso.cli("rm", "o/r/a0")
    gone = iso.wait(lambda: not (work / "o" / "r" / "a0").exists() and "removed", "a0/ deleted")
    check(gone and Path(mark.read_text().strip()) == w.parent.resolve() / "w", "removing an agent runs its teardown in its worktree, then deletes aN/",
          mark.read_text() if mark.exists() else "no mark")
    check(str(w) not in git("-C", str(base), "worktree", "list"), "its worktree is gone from the base clone, unsaved work and all",
          git("-C", str(base), "worktree", "list"))
    check((base / ".git").is_dir() and (base / "README.md").exists(), "the base clone stays")
    listed = agents()
    check("o/r/a0" not in listed and f"o/r/{pane}" not in listed and not (work / "o" / "r" / pane).exists()
          and not (work / "o" / "r" / "iso" / "agents" / f"{pane}.json").exists(),
          "its script pane is stopped and gone, record and dir", (list(listed), pane))
    topics = [e["topic"] for e in events()]
    check("agent.o/r.a0.exited" in topics and f"agent.o/r.{pane}.exited" in topics, "the agent and its pane are published exited",
          [t for t in topics if "exited" in t])
    check(git("-C", str(base), "branch", "--list", "t1") != "", "the worktree's branch stays in the base clone")

    # The reaper.
    r = work / "o" / "r"
    (r / "a7").mkdir()
    (r / "a7" / "notes.txt").write_text("orphan\n")
    (r / "a7" / "w").symlink_to(base)
    backdate(r / "a7")
    (r / "a8").mkdir()
    outside = tmp / "outside"
    outside.mkdir()
    (outside / "keep.txt").write_text("keep\n")
    (r / "a9").symlink_to(outside)
    backdate(r / "a9")
    (work / "x" / "y" / "iso").mkdir(parents=True)
    (work / "x" / "y" / "a0").mkdir()
    backdate(work / "x" / "y" / "a0")
    (r / "a1" / "w").mkdir(parents=True, exist_ok=True)
    reaper_log = home / "reaper.log"
    before = reaper_log.read_text().count(" done: ") if reaper_log.exists() else 0
    lines = iso.cli("reap", "--dry-run").splitlines()
    print("\n".join(lines))
    said = "\n".join(lines)
    check(all(line.split()[1] == "dry-run" for line in lines), "iso reap --dry-run is a dry run")
    check("would tear down o/r/a7" in said and "would tear down o/r/a9" in said and "unlink the symlink" in said,
          "the dry run logs the orphans it would tear down", said)
    check("o/r/a1" not in said, "a recorded agent is left out", said)
    check("skipped o/r/a8" in said, "a young dir is skipped (its record may be on its way)", said)
    check("refused x/y" in said, "a repo whose records dir is missing is refused", said)
    check((r / "a7" / "notes.txt").exists() and (r / "a9").is_symlink() and (r / "a8").exists() and (work / "x" / "y" / "a0").exists(),
          "the dry run touches nothing")
    check(reaper_log.read_text().count(" done: ") == before + 1 and said in reaper_log.read_text(), "the pass is in ~/.isovim/reaper.log")
    iso.wait(lambda: reaper_log.read_text().count(" done: ") >= before + 3, "the TUI's reaper timer")
    check(True, "the TUI runs the reaper on a timer")
    health = subprocess.run([str(REPO / "bin" / "iso"), "checkhealth"], env=iso.env, capture_output=True, text=True).stdout
    check("reaper (dry run):" in health and "dry-run done: 2 orphan(s)" in health, "checkhealth shows the reaper's last pass",
          [line for line in health.splitlines() if "reaper" in line])
    live = iso.cli("reap", "--live")
    print(live)
    check(not (r / "a7").exists() and (base / ".git").is_dir() and (base / "README.md").exists(),
          "--live tears an orphan down without following its symlink into the base clone")
    check(Path(mark.read_text().strip()) == r.resolve() / "a7", "an orphan's teardown runs in its dir", mark.read_text())
    check(not (r / "a9").is_symlink() and (outside / "keep.txt").exists(), "a symlinked orphan is only unlinked")
    check((r / "a8").exists() and (work / "x" / "y" / "a0").exists() and (r / "a1").exists()
          and (r / "iso" / "agents" / "a1.json").exists(), "--live keeps the young, the refused and the recorded")

    # Config sync.
    src2 = make_repo(iso, "o", "r2", {".superset/config.json": json.dumps({"setup": ["echo r2"]})})
    iso.cli("repo", "import", str(src2))
    synced = peer_home / "repos" / "o" / "r2" / "config.json"
    iso.wait(lambda: synced.exists() and json.loads(synced.read_text()).get("setup") == ["echo r2"], "repos/ synced to the peer")
    check(True, "a repo config write syncs repos/ to the peer")
    peer_config = json.loads((peer_home / "config.json").read_text())
    # The role prompts isovim seeded into this host's config.json on its first run go along too.
    peer_config.pop("prompts", None)
    check(peer_config == {"self": "peer", "hosts": {"me": "mehost"}, "aliases": {"p": "peer"}, "repo_dirs": ["~/code"]},
          "config.json is merged in, keeping the peer's self and hosts", peer_config)
    check((peer_home / "repos" / "o" / "r" / "config.json").exists() and not (peer_home / "repos" / "o" / "r" / "base-clone").exists(),
          "a base clone is never synced")
    check(not any((peer_home / name).exists() for name in ("events", "run", "reaper.log", "cache")), "events/ and run/ stay home",
          sorted(p.name for p in peer_home.iterdir()))
    sync_log = home / "sync.log"
    iso.wait(lambda: "FAILED down" in sync_log.read_text(), "the down host logged")
    check(not down_home.exists(), "a down host fails soft, logged in sync.log")
    (tmp / "down").unlink()
    src3 = make_repo(iso, "o", "r3", {".superset/config.json": json.dumps({"setup": ["echo r3"]})})
    iso.cli("repo", "import", str(src3))
    iso.wait(lambda: (down_home / "repos" / "o" / "r2" / "config.json").exists(), "the host that was down catches up")
    check(json.loads((down_home / "config.json").read_text())["self"] == "down", "the next write catches it up (its self is its own name)")
    # A write's own background sync may be going round (or start any moment); iso sync then only
    # queues behind it, so it's run until it runs itself.
    def own_sync():
        r = subprocess.run([str(REPO / "bin" / "iso"), "sync"], env=iso.env, capture_output=True, text=True)
        return None if "running already" in r.stdout else r
    result = iso.wait(own_sync, "an iso sync of its own", 30)
    check(result.returncode == 0 and result.stdout.split("\n")[:2] == ["synced to down", "synced to peer"], "iso sync reports each host",
          (result.returncode, result.stdout, result.stderr))
    (tmp / "down").write_text("")
    result = iso.wait(own_sync, "an iso sync of its own", 30)
    check(result.returncode == 1 and "FAILED down" in result.stdout, "iso sync fails on a down host", result.stdout)

    # iso jump.
    top = lua("return vim.tbl_map(function(r) return r.id end, require('isovim.jump').level({ require('isovim.jump').top() }))")
    check(top == [".", "..", "config", "o", "x"], "the top level: . and .., config, the owners", top)
    repo_level = lua("local j = require('isovim.jump') local top = j.top() local o = vim.iter(top.rows()):find(function(r) return r.id == 'o' end)"
                     " local rr = vim.iter(o.node.rows()):find(function(r) return r.id == 'r' end)"
                     " return vim.tbl_map(function(r) return r.id .. ' ' .. r.desc end, j.level({ top, o.node, rr.node }))")
    print(repo_level)
    ids = [row.split()[0] for row in repo_level]
    check(ids[:2] == [".", ".."] and {"a1", "a8", "iso", "config", "base-clone"} <= set(ids), "a repo's level: its agents, iso/, config, base clone", ids)
    check(any(row.startswith("a8 no record") for row in repo_level), "an orphan says so", repo_level)
    code, path = jump("o", "r", "a1", "w")
    check(code == 0 and path == str(r / "a1" / "w"), "iso __jump drills down to an agent's worktree", (code, path))
    code, path = jump("o", "r", ".")
    check(code == 0 and path == str(r), ". ends on the level's dir", path)
    code, path = jump("o", "..", "config", ".")
    check(code == 0 and path == str(home), ".. goes up a level", path)
    code, path = jump("o", "r", "config")
    check(code == 0 and path == str(config_dir), "a row with nothing below it ends the jump", path)
    code, path = jump("ESC")
    check(code == 130 and path == "", "Esc cancels with nothing printed", (code, path))
    fzf_log.write_text("")
    code, path = jump(args=["a1/w"])
    check(code == 0 and path == str(r / "a1" / "w") and fzf_log.read_text() == "", "iso jump <text> jumps straight to a single match",
          (code, path, fzf_log.read_text()))
    code, path = jump("o/r/a8", args=["o/r/a"])
    check(code == 0 and path == str(r / "a8") and "--query o/r/a" in fzf_log.read_text(), "with more than one match it opens fzf on the text",
          (code, path, fzf_log.read_text()))
    code, path = jump("config", ".", command="jump")
    check(code == 0 and path == str(home), "iso jump without the shell function prints the dir", path)
    shell_env = {**iso.env, "PATH": f"{REPO / 'bin'}:{os.environ['PATH']}", "ZC": str(tmp / "zcompdump")}
    for shell, line in (
        ("zsh", "autoload -U compinit && compinit -u -d \"$ZC\"; source <(iso completion zsh);"),
        ("bash", "source <(iso completion bash);"),
    ):
        picks.write_text("o\nr\na1\nw\n")
        script = line + " cd /; iso jump; pwd; iso version"
        result = subprocess.run([shell, "-c", script] if shell == "bash" else [shell, "-fc", script], env=shell_env, capture_output=True, text=True)
        out = result.stdout.strip().splitlines()
        check(result.returncode == 0 and out[:1] == [str(r / "a1" / "w")] and len(out) == 2,
              f"in {shell}, the iso function cds on iso jump and passes the rest through", (result.returncode, result.stdout, result.stderr))

    # <leader>ij in the TUI.
    lua("require('isovim.jump').on_pick = function(path) vim.g.isovim_jumped = path end")
    iso.keys("Escape")
    lua("vim.cmd.stopinsert()")
    iso.keys("Space", "i", "j")
    title = iso.wait(lambda: lua("local p = Snacks.picker.get()[1] return p and p.title"), "the jump picker")
    check(title == "Jump · iso", "<leader>ij opens the jump picker at the top", title)
    iso.screenshot("jump")
    # Down into o, by picking its row.
    lua("local p = Snacks.picker.get()[1] for i, item in ipairs(p:items()) do if item.id == 'o' then p.list:view(i) end end p:action('confirm')")
    title = iso.wait(lambda: lua("local p = Snacks.picker.get()[1] return p and p.title == 'Jump · o' and p.title"), "the o level")
    iso.keys("Enter")
    jumped = iso.wait(lambda: lua("return vim.g.isovim_jumped"), "a pick")
    check(jumped == str(work / "o"), "a level's . ends the jump there", jumped)
finally:
    iso.stop()

if fails:
    print(f"\n{len(fails)} failed: " + "; ".join(fails))
    sys.exit(1)
print("\nall lifecycle checks passed")
