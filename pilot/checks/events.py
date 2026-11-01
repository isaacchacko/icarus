"""The event bus and `iso listen`: agents' status changes, spawn and exit, promotion and messages reach
listeners as JSON lines, with the TUI closed and open; * and ** patterns pick topics; --once ends on the
first match; many listeners follow at once; idle listeners use no CPU; the log moving aside at 1 MiB
loses nothing; --since reads back. An agent is two topic parts, scope and id: a legacy agent's are
agent.<ws>.<agent>.*, a new-layout agent's agent.<owner>/<repo>.aN.*, so agent.<repo>.** listens to a
whole repo and agent.*.*.status to everyone; msg.<scope>.<id> likewise. Topic parts are encoded ("%"
as %25, then "." as %2E): a new-layout agent in a repo with a dot in its name, and a PR in one,
publish encoded topics from Lua and from iso-hook alike, the same topic and body for the same
address, with the raw addr, scope and id or repo in the details; patterns match the encoded topic
as written; completion offers encoded scopes and agents; a "%" reads back exactly. Prints how much
CPU idle listeners used.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/events.py"""

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402


class Listener:
    def __init__(self, iso, *args):
        self.lines = []
        self.proc = subprocess.Popen([str(REPO / "bin" / "iso"), "listen", *args], env=iso.env, stdout=subprocess.PIPE, text=True)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            self.lines.append(json.loads(line))

    def topics(self):
        return [event["topic"] for event in self.lines]

    def cpu(self):
        """CPU seconds used so far: /proc on Linux, ps's TIME (m:ss.cc) on macOS."""
        stat = Path(f"/proc/{self.proc.pid}/stat")
        if stat.exists():
            fields = stat.read_text().rsplit(")", 1)[1].split()
            return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
        out = subprocess.run(["ps", "-o", "time=", "-p", str(self.proc.pid)], capture_output=True, text=True).stdout.strip()
        minutes, seconds = out.split(":")
        return int(minutes) * 60 + float(seconds)

    def stop(self):
        self.proc.terminate()
        self.proc.wait(5)


def has(listener, topic, **fields):
    return any(e["topic"] == topic and all(e.get(k) == v for k, v in fields.items()) for e in listener.lines)


def enc(part):
    return part.replace("%", "%25").replace(".", "%2E")


def at(addr):
    """An address as an agent topic's two parts: <scope>.<id>, each encoded."""
    scope, id = addr.rsplit("/", 1)
    return f"{enc(scope)}.{enc(id)}"


iso = Iso("events", agent_delay=0.5)
listeners = []


def listen(*args):
    listener = Listener(iso, *args)
    listeners.append(listener)
    return listener


try:
    ws = iso.cli("new", "alpha")
    statuses = listen("agent.*.*.status")
    everything = listen("**")
    one_msg = listen("msg.*.*", "--once")
    lifecycle = listen("agent.**.spawned", "agent.*.*.exited", "agent.*.*.promoted")
    # A legacy agent's scope is its workspace: agent.<ws>.<agent>.*.
    in_ws = listen(f"agent.{enc(ws)}.*.*")
    crowd = [listen("**") for _ in range(5)]
    time.sleep(1.5)

    # The TUI closed: the CLI and the hooks publish on their own.
    agent = iso.cli("agent", ws, "claude", "--name", "bee")
    bee = at(agent)
    assert bee.split(".")[0] == ws, bee
    iso.wait(lambda: has(lifecycle, f"agent.{bee}.spawned", kind="claude", role="worker"), "spawned")
    iso.wait(lambda: has(statuses, f"agent.{bee}.status", state="ready", previous=None), "ready")
    iso.cli("send", agent, "hello")
    iso.wait(lambda: has(one_msg, f"msg.{bee}", text="hello", kind="from", addr=agent, scope=ws), "msg")
    assert one_msg.proc.wait(5) == 0 and len(one_msg.lines) == 1, one_msg.lines
    iso.wait(lambda: has(statuses, f"agent.{bee}.status", state="idle", previous="checking"), "idle")
    states = [e["state"] for e in statuses.lines]
    assert states == ["ready", "working", "checking", "idle"], states
    assert set(statuses.topics()) == {f"agent.{bee}.status"}, statuses.topics()
    assert {(e["addr"], e["scope"], e["id"]) for e in statuses.lines} == {(agent, *agent.rsplit("/", 1))}, statuses.lines

    iso.cli("role", agent, "router")
    iso.wait(lambda: has(lifecycle, f"agent.{bee}.promoted", role="router", previous="worker"), "promoted")
    iso.cli("role", agent, "router")  # already one: nothing published
    iso.cli("rm", agent)
    iso.wait(lambda: has(lifecycle, f"agent.{bee}.exited", reason="stopped"), "exited")
    expected = [f"agent.{bee}.{what}" for what in ("spawned", "promoted", "exited")]
    assert lifecycle.topics() == expected, lifecycle.topics()

    # A program that ends on its own (a shell typed exit) is published from tmux's session-closed hook.
    shell = iso.cli("agent", ws, "terminal", "--name", "sh")
    iso.cli("send", shell, "exit")
    iso.wait(lambda: has(lifecycle, f"agent.{at(shell)}.exited", reason="ended"), "terminal ended")
    iso.wait(lambda: has(statuses, f"agent.{at(shell)}.status", state="exited"), "terminal exited state")
    iso.wait(lambda: {f"agent.{at(shell)}.exited", f"agent.{bee}.status"} <= set(in_ws.topics()), "agent.<ws>.*.* takes a workspace's")
    assert {e["scope"] for e in in_ws.lines} == {ws}, in_ws.lines

    # A new-layout agent in a repo with a dot in its name: its scope is the repo, one part, "." as %2E.
    site = iso.tmp / "src" / "site.com"
    site.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(site)], check=True)
    subprocess.run(["git", "-C", str(site), "remote", "add", "origin", "git@github.com:Owner/site.com.git"], check=True)
    repo = "owner/site%2Ecom"
    dot = f"{repo}.a0"
    dotted = listen(f"agent.{dot}.**")
    dotted_msg = listen(f"msg.{dot}")
    whole_repo = listen(f"agent.{repo}.**")
    repo_status = listen(f"agent.{repo}.*.status")
    repo_msg = listen(f"msg.{repo}.*")
    # Patterns aren't decoded: the raw repo, or a split at its dot, matches nothing. And * and ** are
    # whole parts, never globbed inside one, so a repo's prefix with * or ** is a literal part, and
    # the old one-part address is no topic.
    unencoded = listen("agent.owner/site.com.a0.status", "agent.*.com.a0.*", "agent.**.com.**", "agent.owner/**",
                       "agent.owner/site%2E*.**", "agent.owner/site%2Ecom/a0.status", "msg.owner/site%2Ecom/a0")
    time.sleep(1.5)
    v2 = iso.cli("agent", str(site), "claude", "--v2", "--name", "dot")
    assert v2 == "owner/site.com/a0", v2
    iso.wait(lambda: has(dotted, f"agent.{dot}.spawned", addr=v2, scope="owner/site.com", id="a0", kind="claude"), "v2 spawned, encoded")
    iso.wait(lambda: has(statuses, f"agent.{dot}.status", addr=v2, state="ready"), "agent.*.*.status takes every agent")
    iso.cli("send", v2, "hello")
    iso.wait(lambda: has(dotted_msg, f"msg.{dot}", addr=v2, scope="owner/site.com", text="hello"), "v2 message, encoded")
    # Its states come from iso-hook, which encodes the same way.
    iso.wait(lambda: has(dotted, f"agent.{dot}.status", addr=v2, scope="owner/site.com", id="a0", state="idle", previous="checking"),
             "v2 idle from the hook")
    assert all(t.split(".")[:3] == ["agent", repo, "a0"] and t.count(".") == 3 for t in dotted.topics()), dotted.topics()
    assert {(e["addr"], e["scope"], e["id"]) for e in dotted.lines} == {(v2, "owner/site.com", "a0")}, dotted.lines
    # The whole repo, by its scope: everything, its states, its messages.
    assert whole_repo.topics() == dotted.topics(), (whole_repo.topics(), dotted.topics())
    assert repo_status.topics() and set(repo_status.topics()) == {f"agent.{dot}.status"}, repo_status.topics()
    assert repo_msg.topics() == [f"msg.{dot}"], repo_msg.topics()
    assert not unencoded.lines, unencoded.lines

    # "%" is escaped before ".", so a part with both reads back exactly. iso-hook, as for an agent with that address.
    odd = "o/50%.x%2E/a1"
    odd_topic = "agent.o/50%25%2Ex%252E.a1.status"
    assert f"agent.{at(odd)}.status" == odd_topic
    odd_listener = listen(odd_topic)
    time.sleep(1.5)
    odd_state = iso.tmp / "home" / "run" / "odd" / "a1.state"
    odd_state.parent.mkdir(parents=True)
    subprocess.run([str(REPO / "bin" / "iso-hook"), "interrupt"],
                   env={**iso.env, "ISOVIM_STATE": str(odd_state), "ISOVIM_ADDR": odd}, check=True)
    iso.wait(lambda: has(odd_listener, odd_topic, addr=odd, scope="o/50%.x%2E", id="a1", state="idle"), "a % address, encoded by the hook")
    assert "/".join(unquote(part) for part in odd_topic.split(".")[1:3]) == odd

    seen = everything.topics()
    for listener in crowd:
        iso.wait(lambda: listener.topics() == seen, "every listener sees every event")
    print(f"{len(seen)} events, the same in {len(crowd) + 1} '**' listeners")

    # Idle: nothing happens, and the listeners do nothing.
    before = [listener.cpu() for listener in listeners if listener.proc.poll() is None]
    time.sleep(10)
    after = [listener.cpu() for listener in listeners if listener.proc.poll() is None]
    used = max(b - a for a, b in zip(before, after))
    print(f"idle 10s: the busiest of {len(after)} listeners used {used:.2f}s CPU")
    assert used <= 0.02, used

    # Past 1 MiB the log moves aside; listeners carry on in the new one, missing nothing in between.
    log = iso.tmp / "home" / "events" / "events.jsonl"
    filler = "".join(json.dumps({"topic": "filler", "time": time.time(), "pad": "x" * 200}) + "\n" for _ in range(5200))
    with open(log, "a") as f:
        f.write(filler)
    marked = [f"agent.{ws}.m{n}.status" for n in range(3)]
    marks = listen(*marked)
    time.sleep(1.5)
    (iso.tmp / "home" / "run" / ws).mkdir(parents=True, exist_ok=True)
    for n in range(3):
        # As a hook would, for three made-up agents.
        state = iso.tmp / "home" / "run" / ws / f"m{n}.state"
        subprocess.run([str(REPO / "bin" / "iso-hook"), "interrupt"], env={**iso.env, "ISOVIM_STATE": str(state)}, check=True)
    assert Path(str(log) + ".1").exists() and log.stat().st_size < 1024, "rotated"
    iso.wait(lambda: marks.topics() == marked, "events across the rotation")
    iso.wait(lambda: everything.topics()[-3:] == marked, "a listener from before the rotation follows too")
    assert everything.topics().count("filler") == 5200

    # The TUI open: the same events, now also from what it does itself. gh is a stand-in.
    fake_gh = iso.tmp / "bin" / "gh"
    fake_gh.parent.mkdir()
    fake_gh.write_text('#!/bin/sh\ncase "$*" in *view*) cat "$FAKE_GH_PR" ;; *) echo "[]" ;; esac\n')
    fake_gh.chmod(0o755)
    iso.env["PATH"] = f"{fake_gh.parent}:{iso.env['PATH']}"
    iso.env["FAKE_GH_PR"] = str(iso.tmp / "pr.json")
    iso.start()
    # Lua's topics and bodies are the hook's: the same status for the same address, published from Lua.
    iso.lua("local scope, id = ...; require('isovim.events').publish_agent(scope, id, 'status', { state = 'lua', previous = 'idle' })",
            *odd.rsplit("/", 1))
    iso.wait(lambda: has(odd_listener, odd_topic, state="lua"), "Lua publishes the hook's topic")
    hook_event, lua_event = odd_listener.lines[0], odd_listener.lines[-1]
    assert hook_event.keys() == lua_event.keys() and all(hook_event[k] == lua_event[k] for k in ("topic", "addr", "scope", "id")), odd_listener.lines
    tui_lifecycle = listen("agent.*.*.*")
    pr_events = listen("pr.**")
    time.sleep(1.5)
    cee = iso.cli("agent", ws, "claude", "--name", "cee")
    iso.cli("send", cee, "hi there")
    iso.wait(lambda: has(tui_lifecycle, f"agent.{at(cee)}.status", state="idle"), "idle with the TUI open")
    iso.lua("require('isovim').restart(...)", *cee.split("/"))
    iso.wait(lambda: has(tui_lifecycle, f"agent.{at(cee)}.exited", reason="stopped"), "TUI restart stops it")
    iso.wait(lambda: [t for t in tui_lifecycle.topics() if t.endswith("spawned")] == [f"agent.{at(cee)}.spawned"] * 2, "and starts it again")
    time.sleep(1)
    assert not has(tui_lifecycle, f"agent.{at(cee)}.exited", reason="ended"), "a stop isn't an end of its own"

    # A terminal whose shell exits goes from the workspace, as a closed tab would.
    term = iso.cli("agent", ws, "terminal", "--name", "tt")
    iso.cli("send", term, "exit")
    iso.wait(lambda: has(tui_lifecycle, f"agent.{at(term)}.exited", reason="ended"), "TUI terminal ended")
    iso.wait(lambda: iso.lua("return require('isovim.store').agent(...) == nil", *term.split("/")), "the exited terminal is dropped")

    # PRs: what changed between two fetches, in a repo with a dot in its name.
    def pr(checks, review):
        (iso.tmp / "pr.json").write_text(json.dumps({
            "number": 7, "title": "Seven", "state": "OPEN", "isDraft": False, "url": "https://github.com/o/site.com/pull/7",
            "statusCheckRollup": checks, "reviewDecision": review}))
    pr([{"status": "IN_PROGRESS"}], "REVIEW_REQUIRED")
    iso.cli("pr", ws, "o/site.com#7")
    refetch = ("local ws = ...; local file = require('isovim.store').run_dir(ws) .. '/prs.json';"
               " if vim.fn.filereadable(file) == 1 then local c = vim.json.decode(table.concat(vim.fn.readfile(file)));"
               " c.fetched = 0; vim.fn.writefile({ vim.json.encode(c) }, file) end;"
               " require('isovim.prs').list(ws, function() end)")
    iso.lua(refetch, ws)
    iso.wait(lambda: has(pr_events, "pr.o/site%2Ecom.7.ci", checks="pending"), "first fetch")
    assert has(pr_events, "pr.o/site%2Ecom.7.state", state="OPEN", previous=None, ws=ws, title="Seven"), pr_events.lines
    assert has(pr_events, "pr.o/site%2Ecom.7.review", review="REVIEW_REQUIRED"), pr_events.lines
    assert {(e["repo"], e["number"]) for e in pr_events.lines} == {("o/site.com", 7)}, pr_events.lines
    pr([{"status": "COMPLETED", "conclusion": "SUCCESS"}], "APPROVED")
    seen = len(pr_events.lines)
    iso.lua(refetch, ws)
    iso.wait(lambda: has(pr_events, "pr.o/site%2Ecom.7.review", review="APPROVED", previous="REVIEW_REQUIRED"), "approved")
    assert has(pr_events, "pr.o/site%2Ecom.7.ci", checks="pass", previous="pending"), pr_events.lines
    assert [e["topic"] for e in pr_events.lines[seen:]] .count("pr.o/site%2Ecom.7.state") == 0, "state didn't change"

    # Completion offers topics, agents and PRs, encoded.
    offered = iso.cli("__complete", "listen", "").split("\n")
    values = {line.split("\t")[0] for line in offered[:-1]}
    assert {"agent.*.*.status", "msg.*.*", "**", f"agent.{ws}.**", f"msg.{ws}.*", f"agent.{at(cee)}.*", f"msg.{at(cee)}",
            f"agent.{repo}.**", f"msg.{repo}.*", f"agent.{dot}.*", f"msg.{dot}", "pr.o/site%2Ecom.7.*"} <= values, values
    assert not any("site.com" in value for value in values), values

    # --since reads back, through the moved-aside log too.
    back = listen("agent.*.*.promoted", "--since", "1h", "--once")
    assert back.proc.wait(5) == 0 and back.lines[0]["role"] == "router", back.lines
    print("ok")
finally:
    for listener in listeners:
        if listener.proc.poll() is None:
            listener.stop()
    iso.stop()
