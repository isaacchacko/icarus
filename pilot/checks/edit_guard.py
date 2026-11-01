"""The edit guard (the final review's B3): an agent's spawn records the clone its spawner works from,
as a user's spawn from a clone does, and a new-layout agent's edits in any clone or checkout of its
repo outside its own aN/w are refused, whatever its record says: the clone the record names, a clone
of the repo nothing records, the base clone, another agent's worktree, a clone's .git, and a record
whose checkout is null. The first such edit makes the agent's worktree, and the edit made again
under w/ goes through. A mutating git command whose target is such a clone (its cwd after a cd, or
-C) is refused too, while git in its own w/ runs. pilot/fake-acp-agent runs the session's
PreToolUse hooks from _meta as Claude Code does.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/edit_guard.py"""

import json
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
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True)
    return result.stdout.strip()


iso = Iso("edit_guard", agent_delay=0.2)
iso.env["ISOVIM_SELF"] = "pilothost"


def run(*args, cwd=None, timeout=90):
    r = subprocess.run([BIN, *args], env=iso.env, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def unit_dir(key):
    return iso.tmp / "work" / Path(key)


def record_file(address):
    key, agent = address.rsplit("/", 1)
    return unit_dir(key) / "iso" / "agents" / f"{agent}.json"


def record(address):
    path = record_file(address)
    return json.loads(path.read_text()) if path.exists() else {}


def chunks(address):
    key, agent = address.rsplit("/", 1)
    path = unit_dir(key) / "iso" / "journal" / f"{agent}.jsonl"
    entries = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    return [e["update"]["content"].get("text", "") for e in entries
            if e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk"]


def reply(address, text, prefixes, timeout=60):
    """Sends text to the agent and returns its first new reply starting with one of prefixes."""
    prefixes = (prefixes,) if isinstance(prefixes, str) else prefixes
    before = len(chunks(address))
    rc, _, err = run("send", address, text)
    assert rc == 0, err
    return iso.wait(lambda: next((c for c in chunks(address)[before:] if c.startswith(prefixes)), None),
                    f"{address}'s reply to {text!r}", timeout)


def spawned(by, args, name):
    """The address an agent's own `iso <role> spawn` printed."""
    out = iso.tmp / f"{name}.out"
    reply(by, f"run {BIN} {args} > {out} 2>&1", "ran:", 120)
    return out.read_text().strip()


try:
    iso.start()
    remote = iso.tmp / "remotes" / "acme" / "app.git"
    remote.mkdir(parents=True)
    git("init", "-q", "--bare", "-b", "main", str(remote))
    app = iso.tmp / "src" / "app"
    git("clone", "-q", str(remote), str(app))
    git("checkout", "-qb", "main", cwd=app)
    (app / "README").write_text("app\n")
    git("add", "-A", cwd=app)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "first", cwd=app)
    git("push", "-q", "-u", "origin", "main", cwd=app)
    git("remote", "set-head", "origin", "main", cwd=app)
    # Another clone of the repo, which no workspace or record knows.
    other = iso.tmp / "elsewhere" / "app-copy"
    git("clone", "-q", str(remote), str(other))
    head = git("rev-parse", "HEAD", cwd=app)
    base = Path(iso.cli("repo", "base", "acme/app", "--from", str(app)))

    print("# a router's spawn records the clone it works from")
    rc, router, err = run("spawn", "--repo", str(app), "--role", "router", "--name", "r")
    check(rc == 0 and record(router).get("checkout") == str(app.resolve()), "the user's router records the clone", (rc, router, err, record(router)))
    kid = spawned(router, "router spawn --name kid kid task", "kid")
    check(kid.startswith("acme/app/a") and record(kid).get("parent") == router, "iso router spawn makes the router's child in acme/app", kid)
    check(record(kid).get("checkout") == str(app.resolve()), "and records the router's clone as its checkout, not null", record(kid))

    print("\n# its edits in the user's clone")
    w = unit_dir("acme/app") / kid.rsplit("/", 1)[1] / "w"
    first = reply(kid, f"write {app / 'from-kid.txt'} x", ("blocked:", "write:"))
    check(first.startswith("blocked:") and not (app / "from-kid.txt").exists(), "an edit in the user's clone, by absolute path, is refused", first)
    check((w / ".git").exists() and str(w / "from-kid.txt") in first, "the refusal makes the worktree and names the path there", first)
    done = reply(kid, f"write {w / 'from-kid.txt'} x", ("blocked:", "write:"))
    check(done.startswith("write:") and (w / "from-kid.txt").read_text() == "x", "made again under w/, it lands", done)
    again = reply(kid, f"write {app / 'again.txt'} x", ("blocked:", "write:"))
    check(again.startswith("blocked:") and not (app / "again.txt").exists(), "with w made, the user's clone is still refused", again)
    loose = reply(kid, f"write {other / 'loose.txt'} x", ("blocked:", "write:"))
    check(loose.startswith("blocked:") and not (other / "loose.txt").exists() and str(w / "loose.txt") in loose,
          "a clone of the repo that nothing records is refused", loose)
    hooks = reply(kid, f"write {app / '.git' / 'hooks' / 'pre-commit'} x", ("blocked:", "write:"))
    check(hooks.startswith("blocked:") and not (app / ".git" / "hooks" / "pre-commit").exists(), "so is the clone's .git", hooks)
    shared = reply(kid, f"write {base / 'README'} x", ("blocked:", "write:"))
    check(shared.startswith("blocked:") and (base / "README").read_text() == "app\n", "and the base clone", shared)

    print("\n# a record whose checkout is null")
    kid2 = spawned(router, "router spawn --name nul nul task", "nul")
    data = record(kid2)
    data["checkout"] = None
    record_file(kid2).write_text(json.dumps(data))
    w2 = unit_dir("acme/app") / kid2.rsplit("/", 1)[1] / "w"
    nul = reply(kid2, f"write {app / 'from-nul.txt'} x", ("blocked:", "write:"))
    check(nul.startswith("blocked:") and not (app / "from-nul.txt").exists() and (w2 / ".git").exists(),
          "its edit in the user's clone is refused, and its worktree made", nul)
    check(reply(kid2, f"write {w2 / 'from-nul.txt'} x", ("blocked:", "write:")).startswith("write:") and (w2 / "from-nul.txt").exists(),
          "and the edit lands in its w/")
    theirs = reply(kid2, f"write {w / 'theirs.txt'} x", ("blocked:", "write:"))
    check(theirs.startswith("blocked:") and not (w / "theirs.txt").exists(), "another agent's worktree is refused", theirs)

    print("\n# git that would change a clone")
    cd = reply(kid, f"bash cd {app} && git commit --allow-empty -qm evil", ("blocked:", "bash:"))
    check(cd.startswith("blocked:") and "git commit" in cd and git("rev-parse", "HEAD", cwd=app) == head,
          "cd into the user's clone and git commit is refused", cd)
    dash_c = reply(kid, f"bash git -C {app} checkout -qb evil", ("blocked:", "bash:"))
    check(dash_c.startswith("blocked:") and "evil" not in git("branch", cwd=app), "git -C <the user's clone> checkout -b is refused", dash_c)
    elsewhere = reply(kid2, f"bash git -C {other} reset --hard HEAD", ("blocked:", "bash:"))
    check(elsewhere.startswith("blocked:"), "so is a mutating git in a clone nothing records, for a null checkout", elsewhere)
    reads = reply(kid, f"bash git -C {app} status --short", ("blocked:", "bash:"))
    check(reads.startswith("bash:") and "(exit 0)" in reads, "git that only reads the user's clone runs", reads)
    own = reply(kid, f"bash cd {w} && git add -A && git -c user.name=t -c user.email=t@t commit -qm mine", ("blocked:", "bash:"))
    check(own.startswith("bash:") and "(exit 0)" in own and git("log", "-1", "--format=%s", cwd=w) == "mine", "git commit in its own w/ runs", own)
    plain = reply(kid, "bash echo hi", ("blocked:", "bash:"))
    check(plain.startswith("bash:") and "hi" in plain, "a command with no git runs", plain)

    print("\n# a fork keeps the checkout")
    fork = spawned(kid, f"worker fork {kid} --name forked", "fork")
    check(fork.startswith("acme/app/a") and record(fork).get("checkout") == str(app.resolve()), "iso worker fork records the clone", (fork, record(fork)))
finally:
    iso.stop()

print(f"\n{len(fails)} failure(s)" + (": " + ", ".join(fails) if fails else ""))
sys.exit(1 if fails else 0)
