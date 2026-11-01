"""iso move carries the whole aN/ and loses nothing (the final review's blocker 1).
A new-layout agent's aN/ goes to the other host (here a fake one, a second isovim home that
pilot/fake-ssh runs the remote side in) whole: its scratch files beside w/, and in w/ the files git
doesn't carry (ignored, untracked), as well as its branch. The other host checks each file against
the sender's list (sizes and hashes) before it says the agent is there, and only then is it removed
here. A general/ agent's aN/, its only dir, goes the same way. Any failure leaves the agent here as
it was, still running, and nothing of it on the other host: a file here that can't be read, a copy
there that fails, a file that arrives different, an agent that won't start there.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/move_safe.py"""

import json
import os
import shutil
import subprocess
import sys
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


def commit(cwd, message):
    git("add", "-A", cwd=cwd)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", message, cwd=cwd)


iso = Iso("move_safe", agent_delay=0.2)
tmp, work = iso.tmp, iso.tmp / "work"
(tmp / "home").mkdir()
peer = tmp / "peer"
peer_env = {
    "ISOVIM_HOME": str(peer / "home"),
    "ISOVIM_WORK": str(peer / "work"),
    "ISOVIM_TMUX_SOCKET": f"isot-mvpeer-{os.getpid()}"[:60],
    "ISOVIM_SOCK": str(peer / "s"),
    "CLAUDE_CONFIG_DIR": str(peer / "claude"),
    "FAKE_ACP_LOG": str(peer / "fake-acp.log"),
    "ISOVIM_SELF": "peer",
    "ISOVIM_PEERS": "-",
    "ISOVIM_SYNC_ROOT": str(peer / "sync"),
}
for d in ("home", "work", "claude"):
    (peer / d).mkdir(parents=True)
ssh_env = tmp / "ssh-env"

# A tar on the peer's PATH that does what $MOVE_FAULT says to what bin/iso receive unpacks:
# "extract" fails the copy there partway, "corrupt" changes a file after it arrives.
faults = tmp / "faults"
faults.mkdir()
real_tar = shutil.which("tar")
(faults / "tar").write_text(f"""#!/usr/bin/env bash
if [ "${{MOVE_FAULT:-}}" = extract ] && [ "$1" = -xf ]; then
  "{real_tar}" "$@" || exit $?
  echo "tar: write error: No space left on device" >&2
  exit 2
fi
"{real_tar}" "$@" || exit $?
if [ "${{MOVE_FAULT:-}}" = corrupt ] && [ "$1" = -xf ]; then
  # bin/iso receive runs tar -xf - -C <incoming>.
  for f in "$4"/*/notes.md; do [ -f "$f" ] && echo changed in transit >> "$f"; done
fi
exit 0
""")
(faults / "tar").chmod(0o755)


def peer_faults(**extra):
    env = {**peer_env, **extra}
    ssh_env.write_text("".join(f"{k}={v}\n" for k, v in env.items()))


peer_faults()
iso.env.update(
    ISOVIM_SSH=str(REPO / "pilot" / "fake-ssh"),
    ISOVIM_REMOTE_BIN=BIN,
    FAKE_SSH_ENV=str(ssh_env),
    ISOVIM_SELF="pilothost",
    ISOVIM_PEERS="peer=peerhost",
    CLAUDE_CONFIG_DIR=str(tmp / "claude"),
    FAKE_ACP_CLAUDE_KEYED="1",
)
(tmp / "claude").mkdir()


def run(*args, env=None, timeout=180):
    r = subprocess.run([BIN, *args], env={**iso.env, **(env or {})}, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def journal(address, root=work):
    key, agent = address.rsplit("/", 1)
    path = root / key / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def chunks(address, root=work):
    return [e["update"]["content"].get("text", "") for e in journal(address, root)
            if e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk"]


def reply(address, text, prefix, timeout=30):
    before = len(chunks(address))
    rc, _, err = run("send", address, text)
    assert rc == 0, err
    return iso.wait(lambda: next((c for c in chunks(address)[before:] if c.startswith(prefix)), None),
                    f"{address}'s reply to {text!r}", timeout)


def record(address, root=work):
    key, agent = address.rsplit("/", 1)
    path = root / key / "iso" / "agents" / f"{agent}.json"
    return json.loads(path.read_text()) if path.exists() else None


def tmux_has(socket, name):
    return subprocess.run(["tmux", "-L", socket, "has-session", "-t", "=" + name], capture_output=True).returncode == 0


def running_here(address):
    key, agent = address.rsplit("/", 1)
    return tmux_has(iso.env["ISOVIM_TMUX_SOCKET"], "iso2-" + key.replace("/", "+") + "+" + agent)


def snapshot(root):
    """Every file and link under root but w/.git, as {relative path: bytes or link target}."""
    out = {}
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root).as_posix()
        if rel == "w/.git" or rel.startswith("w/.git/"):
            continue
        if path.is_symlink():
            out[rel] = "-> " + os.readlink(path)
        elif path.is_file():
            out[rel] = path.read_bytes()
    return out


def peer_agents(key):
    agents = peer / "work" / key / "iso" / "agents"
    return sorted(p.stem for p in agents.glob("a*.json")) if agents.exists() else []


def peer_dirs(key):
    root = peer / "work" / key
    return sorted(p.name for p in root.glob("a*") if p.is_dir()) if root.exists() else []


def incoming():
    return sorted(p.name for p in (peer / "home").glob("incoming.*"))


def repo_agent(src, name, untracked=True):
    """A running repo agent with its worktree made, and files git doesn't carry in and beside it."""
    rc, a, err = run("spawn", "--repo", str(src), "--name", name)
    assert rc == 0, (rc, a, err)
    reply(a, "hello", "reply to:")
    agent_dir = work / "acme" / "web" / a.rsplit("/", 1)[1]
    reply(a, f"write {agent_dir / 'f.txt'} hi", "blocked:", 60)
    w = agent_dir / "w"
    iso.wait(lambda: (w / ".git").exists(), f"{a}'s worktree")
    (w / ".gitignore").write_text(".env\nbuild/\n")
    commit(w, "ignore .env")
    (agent_dir / "notes.md").write_text(f"{name}'s plan\n")
    (agent_dir / "results").mkdir()
    (agent_dir / "results" / "out.csv").write_bytes(b"a,b\n1,2\n\x00\x01binary\n")
    (agent_dir / "link").symlink_to("notes.md")
    (w / ".env").write_text("SECRET=1\n")
    (w / "build").mkdir()
    (w / "build" / "big.bin").write_bytes(os.urandom(300_000))
    if untracked:
        (w / "scratch.txt").write_text("not yet added\n")
    return a, agent_dir


def refused_intact(a, agent_dir, before, what, rc, out, err, peers_before):
    key = a.rsplit("/", 1)[0]
    check(rc != 0, f"{what}: the move fails", (rc, out, err))
    check(record(a) is not None, f"{what}: its record is still here", (rc, out, err))
    after = snapshot(agent_dir) if agent_dir.exists() else {}
    check(after == before, f"{what}: its aN/ here is as it was", sorted(set(before) ^ set(after)) or
          [k for k in before if before[k] != after.get(k)])
    iso.wait(lambda: running_here(a), f"{a} running here again", 30) if rc != 0 else None
    check(running_here(a), f"{what}: it's still running here")
    check(peer_agents(key) == peers_before[0] and peer_dirs(key) == peers_before[1],
          f"{what}: nothing of it is left on the other host", (peer_agents(key), peer_dirs(key), peers_before))
    check(incoming() == [], f"{what}: nor a half-unpacked copy there", incoming())


try:
    iso.start()
    origin = tmp / "origins" / "acme" / "web.git"
    origin.mkdir(parents=True)
    git("init", "-q", "--bare", "-b", "main", str(origin))
    src = tmp / "src" / "web"
    src.mkdir(parents=True)
    git("init", "-q", "-b", "main", cwd=src)
    (src / "README.md").write_text("web\n")
    commit(src, "init")
    git("remote", "add", "origin", str(origin), cwd=src)
    git("push", "-q", "-u", "origin", "main", cwd=src)
    git("remote", "set-head", "origin", "main", cwd=src)

    print("# a repo agent's whole aN/ goes")
    a, agent_dir = repo_agent(src, "mover")
    before = snapshot(agent_dir)
    rc, out, err = run("move", a, "peerhost")
    check(rc == 0 and out.startswith(f"{a} moved to peerhost"), "an agent with untracked and ignored files in w/ moves", (rc, out, err))
    there = peer / "work" / "acme" / "web" / a.rsplit("/", 1)[1]
    got = snapshot(there) if there.exists() else {}
    for rel in ("notes.md", "results/out.csv", "link", "w/.env", "w/build/big.bin", "w/scratch.txt", "w/README.md", "w/.gitignore"):
        check(got.get(rel) == before.get(rel), f"{rel} arrived as it was", (rel, rel in got))
    check((there / "w" / ".git").is_file() and git("status", "--porcelain", "--ignored", cwd=there / "w").splitlines()
          == ["?? scratch.txt", "!! .env", "!! build/"], "its worktree there is a git worktree, scratch.txt untracked and .env ignored",
          git("status", "--porcelain", "--ignored", cwd=there / "w") if (there / "w").exists() else None)
    check(not agent_dir.exists() and record(a) is None, "and only then it's gone here")

    print("\n# a general/ agent's aN/ goes")
    rc, g, err = run("spawn", "--repo", "general", "--name", "gen")
    check(rc == 0 and g.startswith("general/a"), "a general agent", (rc, g, err))
    reply(g, "hello", "reply to:")
    gdir = work / "general" / g.rsplit("/", 1)[1]
    gdir.mkdir(parents=True, exist_ok=True)
    (gdir / "notes.md").write_text("general notes\n")
    (gdir / "results").mkdir()
    (gdir / "results" / "out.csv").write_text("x\n")
    gbefore = snapshot(gdir)
    rc, out, err = run("move", g, "peerhost")
    check(rc == 0, "it moves", (rc, out, err))
    gthere = peer / "work" / "general" / g.rsplit("/", 1)[1]
    check((snapshot(gthere) if gthere.exists() else {}) == gbefore, "its aN/ arrived whole", gthere)
    check(not gdir.exists(), "and it's gone here")
    subprocess.run(["tmux", "-L", peer_env["ISOVIM_TMUX_SOCKET"], "kill-server"], capture_output=True)

    print("\n# a failure leaves the agent here")
    (peer / "notmp").mkdir()
    (peer / "notmp").chmod(0o500)
    with_faults = f"{faults}:{os.environ['PATH']}"
    for n, (what, env, why) in enumerate((
            ("a file here that can't be read", {}, "can't read"),
            ("the copy there fails", dict(PATH=with_faults, MOVE_FAULT="extract"), "the copy here failed"),
            ("a file arrives different", dict(PATH=with_faults, MOVE_FAULT="corrupt"), "notes.md arrived different"),
            ("it won't start there", dict(TMUX_TMPDIR=str(peer / "notmp")), "it didn't start here"))):
        # An agent of its own each, with no untracked file, so it gets past the dirty-worktree
        # refusal to the copy.
        b, bdir = repo_agent(src, f"stayer{n}", untracked=False)
        if not env:
            (bdir / "locked.txt").write_text("can't read me\n")
        before = snapshot(bdir)
        if not env:
            (bdir / "locked.txt").chmod(0)
        peers_before = (peer_agents("acme/web"), peer_dirs("acme/web"))
        peer_faults(**env)
        rc, out, err = run("move", b, "peerhost")
        if (bdir / "locked.txt").exists():
            (bdir / "locked.txt").chmod(0o644)
        refused_intact(b, bdir, before, what, rc, out, err, peers_before)
        check(why in err, f"{what}: and the error says why", err)
        peer_faults()
        if record(b) is not None and rc != 0:
            reply(b, "still here?", "reply to:")
            check(True, f"{what}: and it still answers here")

    rc, out, err = run("move", b, "peerhost")
    check(rc == 0, "with the faults gone, it moves", (rc, out, err))
finally:
    subprocess.run(["tmux", "-L", peer_env["ISOVIM_TMUX_SOCKET"], "kill-server"], capture_output=True)
    (Path(os.environ.get("TMUX_TMPDIR", "/tmp")) / f"tmux-{os.getuid()}" / peer_env["ISOVIM_TMUX_SOCKET"]).unlink(missing_ok=True)
    (peer / "notmp").chmod(0o700) if (peer / "notmp").exists() else None
    iso.stop()

print(f"\n{len(fails)} failure(s)" + (": " + ", ".join(fails) if fails else ""))
sys.exit(1 if fails else 0)
