"""No pilot world outlives its run: its tmux servers, the TUI and its nvim --embed server, the agents'
supervisors and adapters all end when the check ends, whether it passes, fails, is sent SIGTERM (a
timeout), or is SIGKILLed (its guardian ends it). Each run's TUI server is wedged in a Lua loop
first, as one leaked 4 GB for days on cleopatra: it ignores its client going away.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/no_leaks.py
NO_LEAKS_PILOT=<another tree's pilot/> runs the worlds with that tree's harness (to show one leaking)."""

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import kill_pids, world_pids  # noqa: E402

PILOT = os.environ.get("NO_LEAKS_PILOT", str(Path(__file__).resolve().parent.parent))
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


# A run: a world with the TUI up and a General ACP agent spawned, its TUI server wedged; then it ends
# as `how` says. It prints the world's dir and "ready" once all that's running.
CHILD = r'''
import os, signal, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
from iso import REPO, Iso
how = sys.argv[2]
iso = Iso("no_leaks_" + how, agent_delay=0.2)
print(iso.tmp, flush=True)
def body():
    iso.start()
    plain = iso.tmp / "plain"
    plain.mkdir()
    r = subprocess.run([str(REPO / "bin" / "iso"), "spawn", "--name", "leaky"], env=iso.env, cwd=plain,
                       capture_output=True, text=True, timeout=90)
    assert r.returncode == 0, r.stderr
    journal = iso.tmp / "work" / "general" / "iso" / "journal" / "a0.jsonl"
    iso.wait(lambda: journal.exists() and '"session"' in journal.read_text(), "the agent's session", 30)
    iso.nvim.command("lua vim.defer_fn(function() while true do end end, 300)")
    time.sleep(1)
    print("ready", flush=True)
    if how == "fail":
        raise AssertionError("a check failing")
    if how in ("sigterm", "sigkill"):
        time.sleep(600)
if how == "pass":
    try:
        body()
    finally:
        iso.stop()
else:
    body()
'''


def run(how):
    child = subprocess.Popen([sys.executable, "-c", CHILD, PILOT, how], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    tmp = Path(child.stdout.readline().strip())
    ready = child.stdout.readline().strip() == "ready"
    during = world_pids(tmp) if ready else set()
    if how == "sigterm":
        child.send_signal(signal.SIGTERM)
    elif how == "sigkill":
        child.send_signal(signal.SIGKILL)
    try:
        child.wait(timeout=60)
    except subprocess.TimeoutExpired:
        child.kill()
    # A dead run's guardian ends its world within a few seconds.
    deadline = time.time() + 20
    while (world_pids(tmp) or tmp.exists()) and time.time() < deadline:
        time.sleep(0.25)
    left = world_pids(tmp)
    names = {pid: Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode()[:100] for pid in left if Path(f"/proc/{pid}").exists()}
    print(f"# {how}: {len(during)} processes while running")
    check(ready and len(during) >= 3, f"{how}: the run came up with its TUI, server and supervisor", (ready, during, child.stderr.read()[-500:] if not ready else ""))
    check(not left, f"{how}: no process of its world is left", names)
    check(not tmp.exists(), f"{how}: its dir is gone", tmp)
    kill_pids(left)


for how in ("pass", "fail", "sigterm", "sigkill"):
    run(how)

print("\n" + ("ALL OK" if not fails else f"{len(fails)} FAILED: {fails}"))
sys.exit(1 if fails else 0)
