"""Surfaces (isovim.surfaces): iso router surface question validates at once (bad JSON or a bad shape
fails without writing anything), blocks until iso answer answers it and prints the answer; a rerun
reattaches, and an answer given while no asker waited comes back at once; the question is removed
once collected. A file surface whose target is missing gets a .surface.error that goes once the
target exists; markdown frontmatter and tasks.md parse, and broken ones get error files; a chat
surface is consumed (removed) when opened, a consumable markdown one hidden until it changes. Every
change publishes surface.<repo>.<name>.created|changed|removed|answered|consumed, the repo encoded
(me/site%2Ecom). With the TUI up, the watcher (surfaces.watch) sees files the router writes by hand.
Completion offers surface subcommands, waiting questions and their options. Shell callers of
iso router ... are warned and still run.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/surfaces.py"""

import json
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

BIN = str(REPO / "bin" / "iso")
REPO_KEY = "me/site.com"
TOPIC = "surface.me/site%2Ecom"

iso = Iso("surfaces", agent_delay=0.3)
work = iso.tmp / "work" / REPO_KEY / "iso"
work.mkdir(parents=True)
events_log = iso.tmp / "home" / "events" / "events.jsonl"


def run(*args, timeout=30):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def events(prefix=TOPIC):
    if not events_log.exists():
        return []
    rows = [json.loads(line) for line in events_log.read_text().splitlines() if line]
    return [row for row in rows if row["topic"].startswith(prefix)]


def topics():
    return [row["topic"] for row in events()]


def scan():
    rc, out, err = run("__surfaces", REPO_KEY)
    assert rc == 0, err
    return {entry["name"]: entry for entry in json.loads(out)}


class Asker:
    """A blocking iso router surface question in the background."""

    def __init__(self, spec, *flags):
        self.proc = subprocess.Popen([BIN, "router", "surface", "question", spec, "--repo", REPO_KEY, *flags],
                                     env=iso.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.out = self.err = None

    def finish(self, timeout=15):
        self.out, self.err = self.proc.communicate(timeout=timeout)
        return self.proc.returncode, self.out.strip()

    def alive(self):
        return self.proc.poll() is None


def complete(*words):
    lines = iso.cli("__complete", *words).split("\n")
    return [line.split("\t", 1)[0] for line in lines[:-1] if line]


counter = [0]


def inside(address, *cmds, timeout=60):
    """Runs each iso command from inside the agent's pane, as its tool would; returns [(rc, out, err)]."""
    counter[0] += 1
    d = iso.tmp / f"in{counter[0]}"
    d.mkdir()
    lines = [f"{BIN} {cmd} > {d}/{i}.out 2> {d}/{i}.err; echo $? > {d}/{i}.rc" for i, cmd in enumerate(cmds)]
    (d / "s.sh").write_text("\n".join(lines + [f"touch {d}/done"]) + "\n")
    rc, _, err = run("send", address, f"run bash {d}/s.sh")
    assert rc == 0, err
    iso.wait(lambda: (d / "done").exists(), f"commands in {address}", timeout)
    return [(int((d / f"{i}.rc").read_text()), (d / f"{i}.out").read_text(), (d / f"{i}.err").read_text()) for i in range(len(cmds))]


SHIP = json.dumps({"question": "Ship it?", "options": [{"label": "yes"}, {"label": "no", "description": "not yet"}]})
PICK = json.dumps({"question": "Which ones?", "options": [{"label": "red"}, {"label": "green"}, {"label": "blue"}],
                   "multi": True, "other": True})

try:
    # Validation is synchronous: nothing is written, the asker doesn't block.
    for bad, why in (("{not json", "isn't JSON"), ('{"question": "x"}', "options"),
                     ('{"question": "x", "options": [{"label": "a"}], "colour": 1}', "unknown key"),
                     ('{"question": "x", "options": [{"label": "a"}, {"label": "A"}]}', "two options")):
        start = time.time()
        rc, _, err = run("router", "surface", "question", bad, "--repo", REPO_KEY, timeout=10)
        assert rc != 0 and why in err and time.time() - start < 5, (bad, rc, err)
    assert not list(work.glob("*.surface")), list(work.iterdir())
    print("ok   invalid questions fail at once")

    # It blocks until answered, then prints the answer and removes the question.
    asker = Asker(SHIP)
    question = work / "ship-it.surface"
    iso.wait(question.exists, "the question's file")
    time.sleep(0.5)
    assert asker.alive(), asker.finish()
    assert "ship-it" in complete("answer", ""), complete("answer", "")
    assert f"{REPO_KEY}/ship-it" in complete("answer", "")
    assert set(complete("answer", "ship-it", "")) == {"yes", "no"}, complete("answer", "ship-it", "")
    rc, out, _ = run("answer", "ship-it")
    assert rc != 0 and "1. yes" in out and "2. no · not yet" in out, out
    rc, _, err = run("answer", "ship-it", "maybe")
    assert rc != 0 and "isn't one of its options" in err, err
    assert asker.alive()
    rc, out, _ = run("answer", "ship-it", "1")
    assert rc == 0 and out == "yes", out
    rc, out = asker.finish()
    assert rc == 0 and out == "yes", (rc, out, asker.err)
    assert "warning" in asker.err and "is for agents" in asker.err, asker.err
    assert not question.exists()
    assert [t for t in topics() if ".ship-it." in t] == [f"{TOPIC}.ship-it.{w}" for w in ("created", "answered", "removed")], topics()
    answered = next(e for e in events() if e["topic"].endswith(".answered"))
    assert answered["repo"] == REPO_KEY and answered["answer"]["labels"] == ["yes"] and answered["answer"]["by"] == "user", answered
    print("ok   a question blocks until iso answer, prints the answer, and goes")

    # Rerunning reattaches; an answer given with no asker waiting is kept and returned at once.
    asker = Asker(PICK)
    pick = work / "which-ones.surface"
    iso.wait(pick.exists, "the second question")
    asker.proc.send_signal(signal.SIGTERM)
    asker.proc.wait(5)
    assert pick.exists(), "a pending question outlives its asker"
    again = Asker(PICK)
    time.sleep(1)
    assert again.alive() and "reattached" in again.proc.stderr.readline() + again.proc.stderr.readline(), "the rerun reattaches"
    assert len(list(work.glob("which-ones*.surface"))) == 1
    again.proc.send_signal(signal.SIGTERM)
    again.proc.wait(5)
    rc, out, _ = run("answer", f"{REPO_KEY}/which-ones", "red", "blue", "and", "teal")
    assert rc == 0 and out.split("\n") == ["red", "blue", "and teal"], out
    assert pick.exists(), "the answer waits for its asker"
    assert scan()["which-ones"]["needs_you"] is False
    rc, _, err = run("answer", "which-ones", "green")
    assert rc != 0 and "already answered" in err, err
    start = time.time()
    rc, out = Asker(PICK).finish(timeout=10)
    assert rc == 0 and out.split("\n") == ["red", "blue", "and teal"] and time.time() - start < 5, out
    assert not pick.exists()
    print("ok   a rerun reattaches, and a stored answer returns at once")

    # A file surface whose target is missing is broken until it exists.
    target = iso.tmp / "notes" / "plan.txt"
    rc, out, err = run("router", "surface", "file", str(target), "--repo", REPO_KEY)
    assert rc == 0 and out.endswith("plan.txt.surface"), (out, err)
    error = work / "plan.txt.surface.error"
    assert error.exists() and "doesn't exist" in error.read_text() and "surface.error" in err, err
    entry = scan()["plan.txt"]
    assert entry["type"] == "file" and entry["exists"] is False and entry["error"], entry
    target.parent.mkdir()
    target.write_text("the plan\n")
    entry = scan()["plan.txt"]
    assert entry["exists"] is True and "error" not in entry and not error.exists(), entry
    rc, _, err = run("router", "surface", "folder", str(target.parent), "--repo", REPO_KEY)
    assert rc == 0 and scan()["notes"]["type"] == "folder", err
    print("ok   a file surface's .surface.error comes and goes with its target")

    # Markdown and the Task Board, parsed from what the router writes.
    (work / "status.md").write_text("---\nname: Release status\nicon: R\ncolor: green\nconsumable: true\n---\n# Ready\nall green\n")
    (work / "tasks.md").write_text("# Todo\n- write docs\n- [ ] ship\n## doing\n* surfaces\n# Done\nevents\n")
    (work / "bad.md").write_text("---\ncolor: mauve-ish\n---\nhi\n")
    (work / "tasks.md.bak").write_text("not a surface")
    (work / "journal").mkdir()
    (work / "journal" / "a1.md").write_text("not a surface either")
    entries = scan()
    status = entries["status"]
    assert (status["type"], status["title"], status["icon"], status["color"], status["consumable"], status["needs_you"]) == \
        ("markdown", "Release status", "R", "green", True, True), status
    assert status["body"].startswith("# Ready"), status
    tasks = entries["tasks"]
    assert tasks["type"] == "tasks" and tasks["title"] == "Task Board", tasks
    assert [(t["status"], t["text"]) for t in tasks["tasks"]] == \
        [("todo", "write docs"), ("todo", "ship"), ("doing", "surfaces"), ("done", "events")], tasks["tasks"]
    assert tasks["counts"] == {"todo": 2, "doing": 1, "waiting": 0, "blocked": 0, "done": 1}, tasks["counts"]
    assert "color is" in entries["bad"]["error"] and (work / "bad.md.surface.error").exists()
    assert set(entries) == {"plan.txt", "notes", "status", "tasks", "bad"}, set(entries)
    (work / "tasks.md").write_text("# Todo\nok\n# Someday\nnope\n")
    assert "Someday" in scan()["tasks"]["error"] and (work / "tasks.md.surface.error").exists()
    (work / "tasks.md").write_text("# Todo\nok\n")
    (work / "bad.md").unlink()
    entries = scan()
    assert "error" not in entries["tasks"] and not list(work.glob("*.surface.error")), list(work.iterdir())
    print("ok   markdown frontmatter and tasks.md parse; broken ones get error files")

    # Chat: needs an agent; consumed (removed) when opened.
    ws = iso.cli("new", "alpha")
    rc, _, err = run("router", "surface", "chat", "nobody/none", "--repo", REPO_KEY)
    assert rc != 0, err
    rc, out, err = run("router", "surface", "chat", f"{ws}/main", "--repo", REPO_KEY)
    assert rc == 0, err
    chat_name = Path(out).name[: -len(".surface")]
    chat = scan()[chat_name]
    assert chat["type"] == "chat" and chat["agent"] == f"{ws}/main" and chat["needs_you"], chat

    # The TUI: its watcher publishes what the router writes by hand, and opening consumes.
    iso.start()
    iso.lua("vim.g.surface_changes = 0; require('isovim.surfaces').watch(function() vim.g.surface_changes = vim.g.surface_changes + 1 end)")
    before = iso.lua("return vim.g.surface_changes")
    (work / "later.md").write_text("hello\n")
    iso.wait(lambda: f"{TOPIC}.later.created" in topics(), "the watcher to see later.md")
    iso.wait(lambda: iso.lua("return vim.g.surface_changes") > before, "on_change")
    (work / "later.md").write_text("hello again\n")
    iso.wait(lambda: f"{TOPIC}.later.changed" in topics(), "the watcher to see it change")
    listed = iso.lua("return vim.tbl_map(function(e) return e.name end, require('isovim.surfaces').list(...))", REPO_KEY)
    assert "later" in listed and chat_name in listed, listed
    (work / "later.md").unlink()
    iso.wait(lambda: f"{TOPIC}.later.removed" in topics(), "the watcher to see it go")
    ghost = iso.tmp / "ghost.txt"
    (work / "ghost.surface").write_text(json.dumps({"type": "file", "path": str(ghost)}))
    iso.wait(lambda: (work / "ghost.surface.error").exists(), "the watcher to write ghost's error")
    ghost.write_text("boo")
    iso.wait(lambda: not (work / "ghost.surface.error").exists(), "the error to go once the target exists", timeout=15)

    consumed = iso.lua("""
      local s, repo, chat = require('isovim.surfaces'), ...
      local function find(name) for _, e in ipairs(s.list(repo)) do if e.name == name then return e end end end
      s.consume(find(chat))
      s.open(find('status'))
      local status = find('status')
      return {status.consumed == true, status.needs_you}
    """, REPO_KEY, chat_name)
    assert consumed == [True, False], consumed
    assert not (work / f"{chat_name}.surface").exists()
    assert f"{TOPIC}.{chat_name}.consumed" in topics() and f"{TOPIC}.status.consumed" in topics(), topics()
    (work / "status.md").write_text("---\nconsumable: true\n---\nnew news\n")
    iso.wait(lambda: iso.lua("for _, e in ipairs(require('isovim.surfaces').list(...)) do if e.name == 'status' then return e.needs_you end end", REPO_KEY),
             "a rewritten consumable to need you again")

    # The TUI answers a question too (the sidebar's Inbox will call this).
    asker = Asker(SHIP)
    iso.wait(question.exists, "a question while the TUI is up")
    iso.wait(lambda: iso.lua("for _, e in ipairs(require('isovim.surfaces').list(...)) do if e.name == 'ship-it' then return true end end", REPO_KEY), "the cache to have it")
    err = iso.lua("""
      local s = require('isovim.surfaces')
      for _, e in ipairs(s.list(...)) do if e.name == 'ship-it' then
        local bad = select(2, s.answer(e, {labels = {'yes', 'no'}}))
        local ok, why = s.answer(e, {labels = {'no'}})
        return {bad, ok and ok.by or why}
      end end
    """, REPO_KEY)
    assert err[0] == "it takes one option" and err[1] == "user", err
    rc, out = asker.finish()
    assert rc == 0 and out == "no", (out, asker.err)
    print("ok   the TUI's watcher, list, open, consume and answer")

    # The pseudo-repos: the host root's surfaces go in root/iso/, a repo-less agent's in general/iso/
    # (_ is general's other name), each with its own events; iso answer finds root/<name>.
    root_iso, general_iso = iso.tmp / "work" / "root" / "iso", iso.tmp / "work" / "general" / "iso"
    boss = iso.cli("new", "boss")
    iso.cli("root", f"{boss}/main")
    for address in (f"{boss}/main", f"{ws}/main"):
        iso.cli("open", address)
    root_note, general_note = iso.tmp / "root-note.txt", iso.tmp / "general-note.txt"
    root_note.write_text("for the root\n")
    general_note.write_text("for no repo\n")
    got = inside(f"{boss}/main", f"router surface file {root_note}")
    assert got[0][0] == 0 and got[0][1].strip() == str(root_iso / "root-note.txt.surface"), got
    got = inside(f"{ws}/main", f"router surface file {general_note}")
    assert got[0][0] == 0 and got[0][1].strip() == str(general_iso / "general-note.txt.surface"), got
    assert not (iso.tmp / "work" / "_" / "iso" / "general-note.txt.surface").exists()
    rc, _, err = run("router", "surface", "folder", str(iso.tmp / "notes"), "--repo", "_")
    assert rc == 0 and (general_iso / "notes.surface").exists(), err
    rc, out, err = run("__surfaces")
    assert rc == 0, err
    by_repo = {(e["repo"], e["name"]) for e in json.loads(out)}
    assert {("root", "root-note.txt"), ("general", "general-note.txt"), ("general", "notes")} <= by_repo, by_repo
    asker = subprocess.Popen([BIN, "router", "surface", "question", SHIP, "--repo", "root"], env=iso.env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    iso.wait((root_iso / "ship-it.surface").exists, "the root's question")
    assert "root/ship-it" in complete("answer", ""), complete("answer", "")
    rc, out, _ = run("answer", "root/ship-it", "no")
    assert rc == 0 and out == "no", out
    assert asker.communicate(timeout=15)[0].strip() == "no"
    iso.wait(lambda: iso.lua("return vim.tbl_map(function(e) return e.name end, require('isovim.surfaces').list('root'))") == ["root-note.txt"],
             "the TUI's watcher to list the root's surfaces")
    assert {"surface.root.root-note%2Etxt.created", "surface.root.ship-it.answered", "surface.general.general-note%2Etxt.created"} \
        <= {row["topic"] for row in events("surface.")}, [row["topic"] for row in events("surface.")]
    print("ok   the root's surfaces go in root/iso/, a repo-less agent's in general/iso/")

    # <leader>in walks what waits on you: the root's first, then the repos', general last; a
    # question left unanswered steps aside, then comes round again; with nothing, the legacy agents.
    (root_iso / "brief.md").write_text("---\nconsumable: true\n---\nread me\n")
    (root_iso / "decide.surface").write_text(json.dumps({"type": "question", "question": "Decide?", "options": [{"label": "a"}]}))
    (work / "news.md").write_text("---\nconsumable: true\n---\nnews\n")
    (general_iso / "aside.md").write_text("---\nconsumable: true\n---\naside\n")
    iso.wait(lambda: iso.lua("""
      local n = 0
      for _, key in ipairs({'root', ..., 'general'}) do
        for _, e in ipairs(require('isovim.surfaces').list(key)) do if e.needs_you then n = n + 1 end end
      end
      return n
    """, REPO_KEY) == 5, "the watcher to see what waits (brief, decide, news, status, aside)")
    iso.lua("vim.g.asked = vim.NIL; vim.ui.select = function(_, opts) vim.g.asked = opts.prompt end")

    def step():
        before = len(events("surface."))
        iso.lua("vim.g.asked = vim.NIL; require('isovim').next_needs_you()")
        new = [row for row in events("surface.")[before:] if row["topic"].endswith(".consumed")]
        return iso.lua("return vim.g.asked") or (new[0]["repo"] + "/" + new[0]["name"] if new else None)

    walked = [step() for _ in range(6)]
    assert walked == ["root/brief", "Decide?", f"{REPO_KEY}/news", f"{REPO_KEY}/status", "general/aside", "Decide?"], walked
    run("answer", "root/decide", "a")
    iso.wait(lambda: iso.lua("return #vim.tbl_filter(function(e) return e.needs_you end, require('isovim.surfaces').list('root'))") == 0,
             "the root's question answered")
    iso.lua("vim.g.told = vim.NIL; local n = Snacks.notify.info; Snacks.notify.info = function(m, ...) vim.g.told = m return n(m, ...) end")
    iso.lua("require('isovim').next_needs_you()")
    assert iso.lua("return vim.g.told") == "Nothing needs you", iso.lua("return vim.g.told")
    iso.lua("require('isovim').open(...)", boss, "main")
    run("send", f"{ws}/main", "ask may I?")
    iso.wait(lambda: iso.lua("return require('isovim.status').get(...)", ws, "main") == "attention", "alpha to ask")
    iso.lua("require('isovim').next_needs_you()")
    iso.wait(lambda: iso.lua("return vim.b.isovim_id") == ws, "the legacy agent that asks, opened")
    print("ok   <leader>in walks the waiting surfaces, the root's first, then falls back to the agents")

    expected = {f"{TOPIC}.{n}.{w}" for n, w in (("plan%2Etxt", "created"), ("plan%2Etxt", "changed"), ("status", "created"),
                                                 ("tasks", "changed"), ("bad", "removed"), (chat_name, "removed"))}
    assert expected <= set(topics()), expected - set(topics())
    assert all(e["repo"] == REPO_KEY and e["name"] for e in events()), events()
    assert set(complete("router", "surface", "")) >= {"question", "file", "folder", "chat"}, complete("router", "surface", "")
    assert "answer" in complete("root", "") and "answer" not in complete("worker", "")
    print("ok   events and completion")
finally:
    iso.stop()
