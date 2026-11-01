"""m on a repo's header in the sidebar sends the whole repo to another host.
The picker lists the peers, this host left out. Picking one moves every agent of the repo there by
iso move (--all): each resumes there and is gone here, a worker keeps its router as its parent, and
the list then shows that host with the repo under it. A refusal moves none of them and says why: a
host that doesn't answer, or one of the agents mid-turn. On an agent's row m still moves that agent
alone. The other host is a second isovim home that pilot/fake-ssh runs the remote side in, as in
move_safe.py; a host named dead answers as an unreachable ssh does.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/send_to_host.py"""

import json
import os
import shlex
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


iso = Iso("send_to_host", agent_delay=0.2)
tmp, work = iso.tmp, iso.tmp / "work"
peer = tmp / "peer"
peer_env = {
    "ISOVIM_HOME": str(peer / "home"),
    "ISOVIM_WORK": str(peer / "work"),
    "ISOVIM_TMUX_SOCKET": f"isot-sendpeer-{os.getpid()}"[:60],
    "ISOVIM_SOCK": str(peer / "s"),
    "CLAUDE_CONFIG_DIR": str(peer / "claude"),
    "FAKE_ACP_LOG": str(peer / "fake-acp.log"),
    "ISOVIM_SELF": "peer",
    "ISOVIM_PEERS": "-",
    "ISOVIM_SYNC_ROOT": str(peer / "sync"),
}
for d in ("home", "work", "claude"):
    (peer / d).mkdir(parents=True)
(tmp / "claude").mkdir()
ssh_env = tmp / "ssh-env"
ssh_env.write_text("".join(f"{k}={shlex.quote(v)}\n" for k, v in peer_env.items()))
# ssh to deadhost fails as an unreachable host does; any other goes to the fake peer.
ssh = tmp / "ssh"
ssh.write_text(f"""#!/usr/bin/env bash
args=("$@")
while [ "${{1:-}}" = -o ] || [ "${{1:-}}" = -t ]; do
  [ "$1" = -o ] && shift
  shift
done
if [ "$1" = deadhost ]; then
  cat > /dev/null
  echo "ssh: connect to host deadhost port 22: No route to host" >&2
  exit 255
fi
exec {REPO / "pilot" / "fake-ssh"} "${{args[@]}}"
""")
ssh.chmod(0o755)
iso.env.update(
    ISOVIM_SSH=str(ssh),
    ISOVIM_REMOTE_BIN=BIN,
    FAKE_SSH_ENV=str(ssh_env),
    ISOVIM_SELF="pilothost",
    # This host is among them too, as a config listing every host would have it.
    ISOVIM_PEERS="peer=peerhost,dead=deadhost,pilothost=pilothost",
    CLAUDE_CONFIG_DIR=str(tmp / "claude"),
)


def run(*args, timeout=180):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def journal(address, root=work):
    key, agent = address.rsplit("/", 1)
    path = root / key / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def chunks(address):
    return [e["update"]["content"].get("text", "") for e in journal(address)
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


def peer_agents():
    agents = peer / "work" / "acme" / "web" / "iso" / "agents"
    return sorted(p.stem for p in agents.glob("a*.json")) if agents.exists() else []


def picker():
    return iso.lua("local p = Snacks.picker.get()[1] if not p then return nil end"
                   " local c = p:current() return {title = p.title, current = c and c.item or vim.NIL,"
                   " items = vim.tbl_map(function(i) return i.item end, p:items())}")


def close_picker():
    iso.lua("for _, p in ipairs(Snacks.picker.get()) do p:close() end")


def errors():
    return iso.lua("return vim.tbl_map(function(n) return n.msg end,"
                   " vim.tbl_filter(function(n) return n.level == 'error' or n.level == vim.log.levels.ERROR end,"
                   " Snacks.notifier.get_history()))")


def on_repo_row():
    """The cursor in the list, on acme/web's header; its line."""
    iso.focus_sidebar()
    iso.lua("vim.cmd.stopinsert()")

    def line():
        kinds = iso.lua("return require('isovim.sidebar').debug_kinds()")
        lines = iso.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
        return next((i + 1 for i, k in enumerate(kinds) if k == "repo" and "web" in lines[i]), None)
    n = iso.wait(line, "acme/web's header in the list")
    iso.lua("vim.api.nvim_win_set_cursor(0, {..., 0})", n)
    return n


def send(host):
    """m on the repo's header, then the host picked in the picker as you would: typed, then Enter."""
    on_repo_row()
    iso.keys("m")
    shown = iso.wait(picker, "m's host picker", 5)
    iso.type(host)
    iso.wait(lambda: (picker() or {}).get("current") == host, f"the picker on {host}", 5)
    iso.keys("Enter")
    return shown


def intact(what, a0, a1):
    check(record(a0) is not None and record(a1) is not None, f"{what}: both agents are still here")
    check(all(tmux_has(iso.env["ISOVIM_TMUX_SOCKET"], "iso2-acme+web+" + a.rsplit("/", 1)[1]) for a in (a0, a1)),
          f"{what}: and still running here")
    check(peer_agents() == [], f"{what}: nothing of them went to the other host", peer_agents())


try:
    iso.start()
    origin = tmp / "origins" / "acme" / "web.git"
    origin.mkdir(parents=True)
    git("init", "-q", "--bare", "-b", "main", str(origin))
    src = tmp / "src" / "web"
    src.mkdir(parents=True)
    git("init", "-q", "-b", "main", cwd=src)
    (src / "README.md").write_text("web\n")
    git("add", "-A", cwd=src)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init", cwd=src)
    git("remote", "add", "origin", str(origin), cwd=src)
    git("push", "-q", "-u", "origin", "main", cwd=src)
    git("remote", "set-head", "origin", "main", cwd=src)

    rc, a0, err = run("spawn", "--repo", str(src), "--role", "router", "--name", "lead")
    assert rc == 0, (rc, a0, err)
    rc, a1, err = run("spawn", "--repo", str(src), "--name", "helper")
    assert rc == 0, (rc, a1, err)
    # The worker is the router's, as the router's own spawn would make it.
    rec = work / "acme" / "web" / "iso" / "agents" / f"{a1.rsplit('/', 1)[1]}.json"
    rec.write_text(json.dumps({**json.loads(rec.read_text()), "parent": a0}))
    for a in (a0, a1):
        reply(a, "hello", "reply to:")

    print("# the picker")
    shown = None
    try:
        on_repo_row()
        iso.keys("m")
        shown = iso.wait(picker, "m's host picker on a repo's header", 5)
    except AssertionError as e:
        check(False, "m on a repo's header opens a host picker", str(e).splitlines()[0])
    if shown:
        check(sorted(shown["items"]) == ["dead", "peer"], "it lists the peers, this host left out", shown)
        close_picker()

    print("\n# a host that doesn't answer")
    try:
        send("dead")
        msg = iso.wait(lambda: next((m for m in errors() if "deadhost" in m), None), "the move's error", 60)
        check("No route to host" in msg and "nothing moved" in msg, "it says the host didn't answer, and that nothing moved", msg)
    except AssertionError as e:
        check(False, "a move to an unreachable host says why", str(e).splitlines()[0])
    intact("unreachable host", a0, a1)

    print("\n# one of them mid-turn")
    rc, _, err = run("send", a1, "slow 6")
    iso.wait(lambda: any(e["kind"] == "turn" and e.get("state") == "start" for e in journal(a1)[-6:]), "the slow turn to start")
    try:
        send("peer")
        msg = iso.wait(lambda: next((m for m in errors() if "mid-turn" in m), None), "the move's error", 60)
        check(a1 in msg and "nothing moved" in msg, "it names the agent mid-turn, and nothing moved", msg)
    except AssertionError as e:
        check(False, "a move with an agent mid-turn says why", str(e).splitlines()[0])
    intact("mid-turn", a0, a1)
    iso.wait(lambda: [e for e in journal(a1) if e["kind"] == "turn"][-1]["state"] == "end", "the slow turn's end", 30)

    print("\n# the repo goes")
    try:
        send("peer")
        iso.wait(lambda: record(a0) is None and record(a1) is None, "both gone here", 120)
    except AssertionError as e:
        check(False, "m and the peer picked moves the repo", str(e).splitlines()[0])
    there0, there1 = record(a0, peer / "work"), record(a1, peer / "work")
    check(there0 and there0["name"] == "lead" and there1 and there1["name"] == "helper",
          "both agents are on the other host", peer_agents())
    check(there1 and there1.get("parent") == a0, "the worker's parent there is its router there", there1)
    check(all(tmux_has(peer_env["ISOVIM_TMUX_SOCKET"], "iso2-acme+web+" + a.rsplit("/", 1)[1]) for a in (a0, a1)),
          "they run there")
    check(not any(tmux_has(iso.env["ISOVIM_TMUX_SOCKET"], "iso2-acme+web+" + a.rsplit("/", 1)[1]) for a in (a0, a1)),
          "and are stopped here")
    check(not (work / "acme" / "web" / a0.rsplit("/", 1)[1]).exists() and not journal(a0), "nothing of them is left here")
    try:
        iso.wait(lambda: any("moved to peer" in t for t in iso.toasts()), "the toast", 10)
        check(True, "a toast says it moved")
    except AssertionError:
        check(False, "a toast says it moved", iso.toasts()[-3:])

    print("\n# the sidebar")
    try:
        iso.wait(lambda: iso.lua("return vim.g.isovim_sidebar_host") == "peer", "the list on the peer", 10)
        rows = iso.wait(lambda: (lambda r: r if any("router" in x for x in r) and any("helper" in x for x in r) else None)(iso.sidebar()),
                        "the peer's rows with the repo's agents", 30)
        check(True, "the list shows the other host, the repo's agents under it")
        check(any("web" in r for r in rows), "and the repo's header", rows)
        at = iso.lua("local w = vim.api.nvim_get_current_win() return vim.b[vim.api.nvim_win_get_buf(w)].isovim_sidebar == 'list'"
                     " and require('isovim.sidebar').debug_kinds()[vim.api.nvim_win_get_cursor(w)[1]] or vim.NIL")
        check(at == "repo", "the cursor on it", at)
    except AssertionError as e:
        check(False, "the list shows the other host with the repo under it", (str(e).splitlines()[0], iso.sidebar()))
    iso.lua("require('isovim.sidebar').step_host(-1)")
    iso.lua("require('isovim.sidebar').step_host(-1)")
    iso.wait(lambda: iso.lua("return vim.g.isovim_sidebar_host") is None, "the list back on this host")
    rows = iso.sidebar()
    check(not any("web" in r or "helper" in r for r in rows), "this host's list no longer has them", rows)

    print("\n# m on an agent's row")
    rc, b, err = run("spawn", "--repo", str(src), "--name", "solo")
    reply(b, "hello", "reply to:")
    rc, c, err = run("spawn", "--repo", str(src), "--name", "stays")
    reply(c, "hello", "reply to:")
    iso.focus_sidebar()
    lines = iso.wait(lambda: (lambda l: l if any("solo" in x for x in l) else None)(iso.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")),
                     "solo's row")
    iso.lua("vim.api.nvim_win_set_cursor(0, {..., 0})", next(i + 1 for i, x in enumerate(lines) if "solo" in x))
    iso.keys("m")
    iso.wait(picker, "the host picker", 5)
    iso.type("peer")
    iso.wait(lambda: (picker() or {}).get("current") == "peer", "the picker on peer", 5)
    iso.keys("Enter")
    iso.wait(lambda: record(b) is None, "solo gone here", 120)
    check((record(b, peer / "work") or {}).get("name") == "solo", "m on an agent's row moves that agent", peer_agents())
    check(record(c) is not None, "and leaves the repo's others here", record(c))
    check(iso.lua("return vim.g.isovim_sidebar_host") is None, "and the list stays on this host")
finally:
    subprocess.run(["tmux", "-L", peer_env["ISOVIM_TMUX_SOCKET"], "kill-server"], capture_output=True)
    iso.stop()

print(f"\n{len(fails)} failed" if fails else "\nall ok")
sys.exit(1 if fails else 0)
