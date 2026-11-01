"""The second review's smaller isovim fixes (handoff mac-final-review-2, N12-N15).

- N15: iso receive (a move's other end) of a legacy workspace is refused on a host with
  enforcement on, and nothing of it lands; with enforcement off it lands as before.
- N13: while the old _/ waits to be moved (deferred: its root is mid-turn), the plan counts the
  agents in _/ among the new-layout agents that keep running, and names the root there.
- N14: the plan doesn't say a failure stops before anything is moved (step 4 moves), and says that
  untracked files that aren't gitignored, a .env among them, go to the wip branch.
- N12: a step 4 that fails, then a TUI start (it makes workspaces/ again), then a rerun splits the
  old layout across two backups: the plan, the run's output and the README name both, and the
  README's one sh block, run as is, puts back what both hold.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/fixes_f.py"""

import io
import json
import re
import shutil
import subprocess
import sys
import tarfile
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


iso = Iso("fixes_f", agent_delay=0.2)
iso.env["ISOVIM_SELF"] = "pilothost"
iso.env["CLAUDE_CONFIG_DIR"] = str(iso.tmp / "claude-config")
iso.env["ISOVIM_CLU_SYSTEM"] = str(iso.tmp / "no-clu")
HOME = iso.tmp / "home"
WORK = iso.tmp / "work"
TODAY = time.strftime("%Y-%m-%d")
BACKUP = HOME / f"legacy-backup-{TODAY}"


def run(*args, env=None, timeout=120, stdin=None):
    r = subprocess.run([BIN, *args], env={**iso.env, **(env or {})}, capture_output=True, timeout=timeout, input=stdin)
    return r.returncode, r.stdout.decode(), r.stderr.decode()


def tmux(*args):
    return subprocess.run(["tmux", "-L", iso.env["ISOVIM_TMUX_SOCKET"], *args], capture_output=True, text=True)


def section(plan, start, end=None):
    text = plan.split(start, 1)[1] if start in plan else ""
    return text.split(end, 1)[0] if end and end in text else text


try:
    HOME.mkdir(parents=True)
    rc, own, err = run("new", "own")
    assert rc == 0, err
    own = own.strip()
    rc, old, err = run("new", "old")
    assert rc == 0, err
    old = old.strip()
    assert run("archive", old)[0] == 0

    print("# N15. iso receive of a legacy workspace, on a cut-over host")
    peer = iso.tmp / "peer-home"
    peer.mkdir(exist_ok=True)
    moved_id = "abcdef"
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        manifest = json.dumps({"id": moved_id, "running": []}).encode()
        info = tarfile.TarInfo("manifest.json")
        info.size = len(manifest)
        tar.addfile(info, io.BytesIO(manifest))
        tar.add(str(HOME / "workspaces" / own), arcname=moved_id)
    payload = buf.getvalue()
    at_peer = {"ISOVIM_HOME": str(peer), "ISOVIM_WORK": str(iso.tmp / "peer-work")}
    rc, out, err = run("receive", env={**at_peer, "ISOVIM_ENFORCE": "1"}, stdin=payload)
    check(rc != 0 and "cutover" in err, "it's refused with enforcement on", (rc, out, err))
    check(not (peer / "workspaces" / moved_id).exists() and not list(peer.glob("incoming.*")),
          "and nothing of it lands", sorted(p.name for p in peer.rglob("*")))
    rc, out, err = run("receive", env={**at_peer, "ISOVIM_ENFORCE": "0"}, stdin=payload)
    check(rc == 0 and (peer / "workspaces" / moved_id / ".isovim.json").exists(), "with enforcement off it lands as before",
          (rc, out, err))

    print("\n# N13. the plan while _/ waits to move")
    old_iso = WORK / "_" / "iso"
    (old_iso / "agents").mkdir(parents=True)
    (old_iso / "agents" / "a0.json").write_text(json.dumps({"name": "root", "kind": "claude", "acp": True, "role": "root"}))
    (WORK / "_" / "a0").mkdir()
    (HOME / "run" / "_").mkdir(parents=True, exist_ok=True)
    (HOME / "run" / "_" / "a0.state").write_text("working\n")
    tmux("new-session", "-d", "-s", "iso2-_+a0", "sleep 600")
    rc, plan, err = run("cutover", "--dry-run")
    log = (HOME / "migrate.log").read_text() if (HOME / "migrate.log").exists() else ""
    check((WORK / "_" / "iso" / "agents" / "a0.json").exists() and "deferred" in log, "(the move of _/ is deferred)", log[-300:])
    kept = section(plan, "\nKept\n", "\n\n")
    count = re.search(r"new-layout agents: (\d+)", kept)
    check(count and int(count.group(1)) >= 1 and "_/a0" in kept, "the plan counts the agent in _/ and names it", kept)
    last = plan.rstrip().split("\n\n")[-1]
    check("_/a0" in last and "keep running" in last, "and says this host's root there keeps running", last)

    print("\n# N14. the plan's wording")
    head = plan.split("\n\n", 1)[0]
    check("before anything is moved" not in head and "step 4" in head, "a failure isn't said to stop before anything moves", head)
    step1 = section(plan, "1. Push", "\n\n")
    check(".env" in step1 and "gitignored" in step1 and "wip" in step1 and "aren't pushed" not in step1.split("gitignored")[0][-40:],
          "untracked files that aren't gitignored, a .env too, are said to go to the wip branch", step1)
    tmux("kill-session", "-t", "=iso2-_+a0")
    shutil.rmtree(WORK / "_")
    shutil.rmtree(HOME / "run" / "_")

    print("\n# N12. a failed step 4, a TUI start and a rerun")
    # Renaming a dir to another parent needs write on it: archive/ can't move, so step 4 stops after
    # moving workspaces/.
    (HOME / "archive").chmod(0o555)
    try:
        run("cutover", "--dry-run")
        rc, out, err = run("cutover", "--yes", timeout=300)
    finally:
        (HOME / "archive").chmod(0o755)
    check(rc != 0 and (BACKUP / "workspaces" / own).is_dir() and (HOME / "archive" / old).is_dir(),
          "step 4 fails after moving workspaces/", (rc, out, err))
    check(str(BACKUP / "README.md") in out + err, "the failure prints the backup's README path", (out, err))
    # As the TUI's start does.
    (HOME / "workspaces").mkdir()
    rc, plan, err = run("cutover", "--dry-run")
    step4 = section(plan, "4. Move", "\n\n")
    second = Path(f"{BACKUP}-2")
    check(f"legacy-backup-{TODAY}-2" in step4 and f"legacy-backup-{TODAY}/" in step4.replace(f"legacy-backup-{TODAY}-2", ""),
          "the plan moves into a second backup and names the first", step4)
    rc, out, err = run("cutover", "--yes", timeout=300)
    check(rc == 0 and "cut over" in out, "the rerun runs", (rc, out, err))
    check(str(second / "README.md") in out and str(BACKUP) in out.replace(str(second), ""), "its output names both backups", out)
    text = (second / "README.md").read_text()
    check(str(BACKUP / "workspaces") in text and str(second / "archive") in text, "the README names what each backup holds", text)
    first = (BACKUP / "README.md").read_text()
    check(str(second) in first, "and the first backup's README points to the second", first)
    blocks = re.findall(r"```sh\n(.*?)```", text, re.S)
    check(len(blocks) == 1, "its commands are one sh block", blocks)
    (HOME / "workspaces").mkdir()
    (HOME / "archive").mkdir()
    config = json.loads((HOME / "config.json").read_text())
    config.pop("enforce", None)
    (HOME / "config.json").write_text(json.dumps(config, indent=2))
    script = iso.tmp / "undo.sh"
    script.write_text("set -e\n" + (blocks[0] if blocks else "false\n"))
    undo = subprocess.run(["bash", str(script)], env=iso.env, capture_output=True, text=True)
    check(undo.returncode == 0, "the undo runs", (undo.stdout, undo.stderr))
    check((HOME / "workspaces" / own / ".isovim.json").exists() and (HOME / "archive" / old).is_dir()
          and not (HOME / "workspaces" / "workspaces").exists(),
          "both backups' parts are back, nothing nested", sorted(str(p.relative_to(HOME)) for p in HOME.glob("*/*")))
    rc, out, err = run("ls", "--json")
    check(rc == 0 and f"{own}/main" in out, "iso ls lists the legacy workspace again", (rc, out, err))
finally:
    for p in iso.tmp.rglob("*"):
        if p.is_dir() and not p.is_symlink():
            p.chmod(0o755)
    iso.stop()

print("\nFAILED: " + ", ".join(fails) if fails else "\nOK")
sys.exit(1 if fails else 0)
