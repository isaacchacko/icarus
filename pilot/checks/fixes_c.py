"""The spec review's lane C fixes (spec gaps).
11. iso move <owner>/<repo>/aN <host> moves a new-layout agent to another host (here a fake one, a
    second isovim home that pilot/fake-ssh runs the remote side in): refused mid-turn, with a dirty
    worktree, and for a bare repo key; its record, journal and session's transcript go, its branch is
    pushed and made again as aN/w from that host's base clone (cloned from origin there), it takes
    the next aN when that host used its own, it resumes its session there (the fake adapter keeps
    sessions as Claude Code does, by the path it runs in), and it's gone here. The sidebar's m moves a
    new-layout row by its address.
12. codex-acp is in the launch table: iso spawn --kind codex makes a codex agent over ACP whose
    session requests carry the role prompt as systemPrompt (append) and set codex's no-prompts mode,
    with isovim's hooks in CODEX_CONFIG; checkhealth names both adapters.
13. A markdown surface and the Task Board open rendered (no frontmatter; the board drawn by isovim,
    not render-markdown: the sections that hold tasks, a glyph per status, `code` and owners like (a1)
    drawn, wrapped tasks hung, "## Doing (2)" read as doing, one that doesn't parse shown as it is and
    marked broken in the sidebar, alone with no input box), the markdown one with an input box under
    it whose text goes to the repo's router's queue, and the view follows the file;
    an agent removed with no parent hands its children to the repo's router; autopr registers nothing
    for a new-layout agent. (root.<scope>.raised|decided are checked in rootmode.py.)
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/fixes_c.py"""

import json
import os
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


def make_repo(iso, owner, name):
    origin = iso.tmp / "origins" / owner / f"{name}.git"
    origin.mkdir(parents=True)
    git("init", "-q", "--bare", "-b", "main", str(origin))
    src = iso.tmp / "src" / name
    src.mkdir(parents=True)
    git("init", "-q", "-b", "main", cwd=src)
    (src / "README.md").write_text(f"{name}\n")
    git("add", "-A", cwd=src)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init", cwd=src)
    git("remote", "add", "origin", str(origin), cwd=src)
    git("push", "-q", "-u", "origin", "main", cwd=src)
    git("remote", "set-head", "origin", "main", cwd=src)
    return src, origin


iso = Iso("fixes_c", agent_delay=0.2)
home, work, tmp = iso.tmp / "home", iso.tmp / "work", iso.tmp
home.mkdir()
# The fake peer: ssh runs the remote command here, with the peer's own isovim home, work root,
# tmux server and Claude dir.
peer = tmp / "peer"
peer_env = {
    "ISOVIM_HOME": str(peer / "home"),
    "ISOVIM_WORK": str(peer / "work"),
    "ISOVIM_TMUX_SOCKET": f"isot-peer-{os.getpid()}"[:60],
    "ISOVIM_SOCK": str(peer / "s"),
    "CLAUDE_CONFIG_DIR": str(peer / "claude"),
    "FAKE_ACP_LOG": str(peer / "fake-acp.log"),
    "ISOVIM_SELF": "peer",
    "ISOVIM_PEERS": "-",
    "ISOVIM_SYNC_ROOT": str(peer / "sync"),
}
for d in ("home", "work", "claude"):
    (peer / d).mkdir(parents=True)
(tmp / "ssh-env").write_text("".join(f"{k}={v}\n" for k, v in peer_env.items()))
iso.env.update(
    ISOVIM_SSH=str(REPO / "pilot" / "fake-ssh"),
    ISOVIM_REMOTE_BIN=BIN,
    FAKE_SSH_ENV=str(tmp / "ssh-env"),
    ISOVIM_SELF="pilothost",
    ISOVIM_PEERS="peer=peerhost",
    CLAUDE_CONFIG_DIR=str(tmp / "claude"),
    FAKE_ACP_CLAUDE_KEYED="1",
)
(tmp / "claude").mkdir()


def run(*args, cwd=None, env=None, timeout=120):
    r = subprocess.run([BIN, *args], env={**iso.env, **(env or {})}, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def on_peer(*args, timeout=120):
    return run(*args, env={**peer_env, "FAKE_SSH_ENV": ""}, timeout=timeout)


def lua(code, *args):
    return iso.lua(code, *args)


def journal(address, root=work):
    key, agent = address.rsplit("/", 1)
    path = root / key / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def chunks(address, root=work):
    return [e["update"]["content"].get("text", "") for e in journal(address, root)
            if e["kind"] == "update" and e["update"].get("sessionUpdate") == "agent_message_chunk"]


def reply(address, text, prefix, timeout=30, peer_side=False):
    root = peer / "work" if peer_side else work
    before = len(chunks(address, root))
    rc, _, err = (on_peer if peer_side else run)("send", address, text)
    assert rc == 0, err
    return iso.wait(lambda: next((c for c in chunks(address, root)[before:] if c.startswith(prefix)), None),
                    f"{address}'s reply to {text!r}", timeout)


def record(address, root=work):
    key, agent = address.rsplit("/", 1)
    path = root / key / "iso" / "agents" / f"{agent}.json"
    return json.loads(path.read_text()) if path.exists() else None


def tmux_has(socket, name):
    return subprocess.run(["tmux", "-L", socket, "has-session", "-t", "=" + name], capture_output=True).returncode == 0


def fake_log():
    path = Path(iso.env["FAKE_ACP_LOG"])
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def task_board_view():
    """The Task Board drawn by surface_view, not by render-markdown: a heading's first word names its
    status, `code` and an owner like (a1) are drawn, wrapped tasks hang, a board that doesn't parse
    says so in the view and the sidebar."""
    iso_dir = work / "acme" / "web" / "iso"

    def board_after(text, what):
        (iso_dir / "tasks.md").write_text(text)
        return iso.wait(lambda: (lambda b: b if what(b) else None)(lua(
            "return vim.api.nvim_buf_get_lines(require('isovim.surface_view').views['acme/web/tasks'].buf, 0, -1, false)")),
            "the board to follow tasks.md", 15)

    def marks(row):
        return lua("""
          local view = require('isovim.surface_view').views['acme/web/tasks']
          local ns = vim.api.nvim_get_namespaces().isovim_surface_view
          local line = vim.api.nvim_buf_get_lines(view.buf, ..., ... + 1, false)[1]
          local out = {}
          for _, m in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, ns, { ..., 0 }, { ..., -1 }, { details = true })) do
            out[#out + 1] = { text = line:sub(m[3] + 1, m[4].end_col), hl = m[4].hl_group or '', conceal = m[4].conceal }
          end
          return out
        """, row)

    board = board_after("## Doing (2)\n- [ ] Bind `<C-j>` to the queue (a1)\n- [ ] the composer (acme/web/a2, a3)\n\n## Done (1)\n- [x] shipped (a4)\n",
                        lambda b: "Doing  2" in b)
    check(board == ["Task Board  acme/web", "", "Doing  2", "  ◐ Bind `<C-j>` to the queue (a1)", "  ◐ the composer (acme/web/a2, a3)",
                    "", "Done  1", "  ✓ shipped (a4)"],
          "headings with a count, \"## Doing (2)\", parse as their first word (they broke the whole board)", board)
    info = lua("""
      local view = require('isovim.surface_view').views['acme/web/tasks']
      local win = vim.fn.bufwinid(view.buf)
      return { ft = vim.bo[view.buf].filetype, bi = vim.wo[win].breakindent, bio = vim.wo[win].breakindentopt, cl = vim.wo[win].conceallevel }
    """)
    check(info["ft"] == "isovim_tasks" and info["bi"] and info["bio"] == "shift:2" and info["cl"] == 2,
          "not a markdown buffer (render-markdown drew every task as a bullet and an empty checkbox, and <C-j> as an HTML tag);"
          " wrapped tasks hang under their text", info)
    bind = marks(3)
    check({"text": "◐", "hl": "DiagnosticInfo", "conceal": None} in [dict(m, conceal=m.get("conceal")) for m in bind]
          and [m["text"] for m in bind if m.get("conceal") == ""] == ["`", "`"]
          and {"text": "<C-j>", "hl": "@markup.raw"} in [{"text": m["text"], "hl": m["hl"]} for m in bind]
          and {"text": "(a1)", "hl": "Comment"} in [{"text": m["text"], "hl": m["hl"]} for m in bind],
          "the doing glyph in its color, `code` drawn as code with its backticks hidden, the owner (a1) dimmed", bind)
    check({"text": "(acme/web/a2, a3)", "hl": "Comment"} in [{"text": m["text"], "hl": m["hl"]} for m in marks(4)],
          "an owner list of addresses dimmed too", marks(4))
    check({"text": "shipped (a4)", "hl": "Comment"} in [{"text": m["text"], "hl": m["hl"]} for m in marks(7)], "a done task dimmed", marks(7))
    # Narrow, beside a chat, every task wraps; each continuation starts under its text, not its glyph.
    (iso_dir / "tasks.md").write_text("# doing\n" + "- " + " ".join(["a long task that wraps"] * 8) + " (a1)\n")
    lua("vim.api.nvim_win_set_width(vim.fn.bufwinid(require('isovim.surface_view').views['acme/web/tasks'].buf), 50)")
    def wrapped():
        rows = [r for r in iso.screen().splitlines() if "wraps" in r or "a long" in r]
        return rows if len(rows) > 2 and "◐ a long" in rows[0] else None
    rows = iso.wait(wrapped, "the long task on screen", 15)
    starts = {r.split("│")[-1][:4] for r in rows[1:]}
    check(len(rows) > 2 and "◐ a long" in rows[0] and starts == {"    "}, "a wrapped task hangs under its text", rows)
    iso.screenshot("task-board-wrapped")
    board = board_after("# doing\n- one (a1)\n# notes\n- remember the milk\n", lambda b: any("doesn't parse" in l for l in b))
    entry = lua("return vim.iter(require('isovim.surfaces').list('acme/web')):find(function(e) return e.name == 'tasks' end)")
    chunks = lua("return require('isovim.sidebar').surface_chunks(...)", entry)
    check('under "notes"' in board[2] and board[4:] == ["# doing", "- one (a1)", "# notes", "- remember the milk"]
          and ["  broken", "DiagnosticError"] in chunks,
          "a board that doesn't parse says why over the file as it is (it was every section at 0), and its row says broken", (board, chunks))
    board_after("# todo\n# doing\n- Landing page on TUI start (a1)\n# waiting\n# blocked\n- Cutover on victoria (a6)\n# done\n",
                lambda b: "Blocked  1" in b)
    iso.screenshot("task-board")


try:
    iso.start()
    src, origin = make_repo(iso, "acme", "web")

    print("# 11. iso move for a new-layout agent")
    rc, a, err = run("spawn", "--repo", str(src), "--name", "mover")
    check(rc == 0 and a == "acme/web/a0", "a new-layout agent", (rc, a, err))
    reply(a, "hello", "reply to:")
    agent_dir = work / "acme" / "web" / "a0"
    w = agent_dir / "w"
    blocked = reply(a, f"write {agent_dir / 'f.txt'} hi", "blocked:", 60)
    check((w / ".git").exists(), "its first edit made its worktree", blocked)
    branch = git("branch", "--show-current", cwd=w)
    (w / "f.txt").write_text("hi\n")
    (w / "README.md").write_text("changed\n")
    rc, _, err = run("move", a, "peerhost")
    check(rc == 1 and "uncommitted changes" in err and record(a), "a worktree with uncommitted changes to tracked files is refused", (rc, err))
    git("add", "-A", cwd=w)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "the agent's work", cwd=w)
    head = git("rev-parse", "HEAD", cwd=w)
    rc, _, err = run("send", a, "slow 4")
    iso.wait(lambda: any(e["kind"] == "turn" and e.get("state") == "start" for e in journal(a)[-6:]), "the slow turn to start")
    rc, _, err = run("move", a, "peerhost")
    check(rc == 1 and "mid-turn" in err and record(a), "a move mid-turn is refused", (rc, err))
    iso.wait(lambda: [e for e in journal(a) if e["kind"] == "turn"][-1]["state"] == "end", "the slow turn's end in the journal", 30)
    rc, _, err = run("move", "acme/web", "peerhost")
    check(rc == 1 and "isn't an agent's address" in err, "iso move of a bare repo key is an error", (rc, err))
    rc, _, err = run("move", "acme/web/a", "peerhost")
    check(rc == 1 and record(a), "and of an address's prefix", (rc, err))
    session = record(a)["session"]
    # The peer used a0 already: the agent comes in as a1.
    (peer / "work" / "acme" / "web" / "iso" / "agents").mkdir(parents=True)
    (peer / "work" / "acme" / "web" / "iso" / "next").write_text("1\n")
    rc, out, err = run("move", a, "peerhost", timeout=180)
    check(rc == 0 and out == "acme/web/a0 moved to peerhost as acme/web/a1", "iso move moves it, and says where it is", (rc, out, err))
    there = "acme/web/a1"
    moved = record(there, peer / "work")
    check(moved and moved["session"] == session and moved.get("parent") is None and moved["name"] == "mover",
          "its record is there, as a1 (a0 was taken there), with its session", moved)
    pw = peer / "work" / "acme" / "web" / "a1" / "w"
    check((pw / ".git").exists() and git("rev-parse", "HEAD", cwd=pw) == head and git("branch", "--show-current", cwd=pw) == branch,
          "its worktree is made again there from its pushed branch", (pw, branch))
    check(git("rev-parse", f"refs/heads/{branch}", cwd=origin) == head, "the branch was pushed to origin")
    check((peer / "home" / "repos" / "acme" / "web" / "base-clone" / ".git").exists(), "the peer's base clone was made from origin")
    prompts = [e["text"] for e in journal(there, peer / "work") if e["kind"] == "prompt"]
    check(prompts[:2] == ["hello", f"write {agent_dir / 'f.txt'} hi"], "its journal went along", prompts)
    key = "".join(c if c.isalnum() else "-" for c in os.path.realpath(peer / "work" / "acme" / "web" / "a1"))
    check((peer / "claude" / "projects" / key / f"{session}.jsonl").exists(),
          "its session's transcript is under the key of the path it runs in there", sorted(p.name for p in (peer / "claude" / "projects").iterdir()))
    check(tmux_has(peer_env["ISOVIM_TMUX_SOCKET"], "iso2-acme+web+a1"), "it was running, so it runs there")
    iso.wait(lambda: any(e["kind"] == "session" for e in journal(there, peer / "work")[len(prompts):]), "its session up there", 60)
    sessions = [e for e in journal(there, peer / "work") if e["kind"] == "session"]
    check(sessions[-1]["how"] == "resume" and sessions[-1]["sessionId"] == session, "it resumed its session there", sessions[-1])
    history = reply(there, "history", "history:", 30, peer_side=True)
    check("hello" in history, "and the session remembers what came before", history)
    check(not record(a) and not agent_dir.exists() and not journal(a), "it's gone here: record, aN/ and journal", list((work / "acme" / "web").iterdir()))
    check(not tmux_has(iso.env["ISOVIM_TMUX_SOCKET"], "iso2-acme+web+a0"), "and stopped here")

    # The sidebar's m on a new-layout row moves it by its address.
    rc, b, err = run("spawn", "--repo", str(src), "--name", "second")
    reply(b, "hello", "reply to:")
    lua("vim.ui.select = function(items, _, cb) cb(items[1]) end")
    lua("require('isovim.sidebar').actions.isovim_move({ ws = 'acme/web', agent = ..., name = 'second' })", b.rsplit("/", 1)[1])
    iso.wait(lambda: not record(b), "the sidebar's move", 90)
    check(record("acme/web/a2", peer / "work") and record("acme/web/a2", peer / "work")["name"] == "second",
          "m on a new-layout row moves that agent (it keeps a2: the peer never used it)", list((peer / "work" / "acme" / "web" / "iso" / "agents").iterdir()))
    subprocess.run(["tmux", "-L", peer_env["ISOVIM_TMUX_SOCKET"], "kill-server"], capture_output=True)

    print("\n# 12. codex-acp in the launch table")
    rc, c, err = run("spawn", "--repo", str(src), "--kind", "codex", "--name", "cx", "--read-only")
    check(rc == 0, "iso spawn --kind codex", (rc, c, err))
    check(record(c)["kind"] == "codex" and record(c)["acp"], "a codex agent over ACP", record(c))
    reply(c, "hello", "reply to:")
    frames = [e["frame"] for e in fake_log() if "frame" in e]
    new = [f for f in frames if f.get("method") == "session/new" and (f.get("params") or {}).get("systemPrompt")]
    check(new and new[-1]["params"]["systemPrompt"]["mode"] == "append" and "isovim" in new[-1]["params"]["systemPrompt"]["content"][0]["text"]
          and "claudeCode" not in (new[-1]["params"].get("_meta") or {}), "its role prompt goes as systemPrompt (append), not claude's _meta", new[-1:])
    modes = [f["params"]["modeId"] for f in frames if f.get("method") == "session/set_mode"]
    check(modes and modes[-1] == "read-only", "a read-only codex agent is set to codex's read-only mode", modes)
    rc, c2, err = run("spawn", "--repo", str(src), "--kind", "codex", "--name", "cx2")
    reply(c2, "hello", "reply to:")
    frames = [e["frame"] for e in fake_log() if "frame" in e]
    modes = [f["params"]["modeId"] for f in frames if f.get("method") == "session/set_mode"]
    check(modes[-1] == "agent-full-access", "any other codex agent to agent-full-access", modes)
    hooks = [f for f in frames if f.get("method") == "_codex/hooks/list"]
    check(hooks, "it asks codex-acp for the hooks to trust", len(hooks))
    rc, _, err = run("restart", c2)
    iso.wait(lambda: [e for e in journal(c2) if e["kind"] == "session"][-1]["how"] == "resume", "the codex agent resumed", 60)
    check(True, "a restarted codex agent resumes its session")
    env = lua("return require('isovim.acp.adapter').command('/tmp', { kind = 'codex' }).env")
    config = json.loads(env["CODEX_CONFIG"])
    check("iso-hook' stop" in config["hooks"]["Stop"][0]["hooks"][0]["command"] and "PreToolUse" not in config["hooks"]
          and env["INITIAL_AGENT_MODE"] == "agent-full-access", "isovim's hooks go to codex in CODEX_CONFIG", env)
    rc, _, err = run("spawn", "--kind", "gemini", "x")
    check(rc == 1 and "--kind is one of claude, codex" in err, "an unknown kind is refused", err)
    rc, out, err = run("checkhealth")
    check("claude-agent-acp 0.99.1" in out + err and "codex-acp 2.5.0" in out + err, "checkhealth names both adapters", out + err)

    print("\n# 13. surfaces rendered, orphans, autopr")
    rc, router, err = run("spawn", "--repo", str(src), "--role", "router", "--name", "router")
    check(rc == 0, "a router", (rc, router, err))
    reply(router, "hello", "reply to:")
    iso_dir = work / "acme" / "web" / "iso"
    (iso_dir / "notes.md").write_text("---\nname: Release notes\nicon: N\n---\n\nThe **plan** is set.\n")
    (iso_dir / "tasks.md").write_text("# Todo\n- write docs\n## doing\n- ship it\n# Done\n- events\n")
    iso.wait(lambda: lua("local n = {} for _, e in ipairs(require('isovim.surfaces').list('acme/web')) do n[e.name] = true end"
                         " return n.notes and n.tasks or false"), "the watcher to see the surfaces", 15)
    lines = lua("""
      local s = require('isovim.surfaces')
      local entry = vim.iter(s.list('acme/web')):find(function(e) return e.name == 'notes' end)
      local view = require('isovim.surface_view').open(entry)
      return { lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), ft = vim.bo[view.buf].filetype,
        mod = vim.bo[view.buf].modifiable, input = vim.fn.bufwinid(view.input) ~= -1,
        below = vim.fn.win_screenpos(vim.fn.bufwinid(view.input))[1] > vim.fn.win_screenpos(vim.fn.bufwinid(view.buf))[1],
        listed = #vim.tbl_filter(function(b) return vim.api.nvim_buf_get_name(b):find('notes.md', 1, true) ~= nil end, vim.api.nvim_list_bufs()) }
    """)
    check(lines["lines"] == ["# Release notes", "", "The **plan** is set."] and lines["ft"] == "markdown" and not lines["mod"],
          "a markdown surface opens rendered: its body without the frontmatter, read-only markdown", lines)
    check(lines["input"] and lines["below"] and lines["listed"] == 0, "with its input box under it, not the raw file", lines)
    iso.screenshot("surface")
    lua("""
      local view = require('isovim.surface_view').views['acme/web/notes']
      vim.api.nvim_buf_set_lines(view.input, 0, -1, false, { 'ship the notes' })
      require('isovim.surface_view').submit(view)
    """)
    got = iso.wait(lambda: next((e for e in journal(router) if e["kind"] == "prompt" and "ship the notes" in e["text"]), None),
                   "the input box's text at the router", 30)
    check(got["text"] == "[on the acme/web surface notes] ship the notes", "the input box sends to the repo's router", got)
    (iso_dir / "notes.md").write_text("---\nname: Release notes\n---\nRewritten.\n")
    iso.wait(lambda: lua("return vim.api.nvim_buf_get_lines(require('isovim.surface_view').views['acme/web/notes'].buf, 0, -1, false)")[-1]
             == "Rewritten.", "the view to follow the file", 15)
    check(True, "the view follows the file as the router rewrites it")
    board = lua("""
      local s = require('isovim.surfaces')
      local entry = vim.iter(s.list('acme/web')):find(function(e) return e.name == 'tasks' end)
      return vim.api.nvim_buf_get_lines(require('isovim.surface_view').open(entry).buf, 0, -1, false)
    """)
    check(board[0] == "Task Board  acme/web" and "Todo  1" in board and "  ○ write docs" in board and "Doing  1" in board
          and "  ✓ events" in board and not any(line.startswith("Blocked") for line in board),
          "the Task Board opens as the sections that hold tasks, each task after its status's glyph", board)
    task_board_view()

    rc, worker, err = run("spawn", "--repo", str(src), "--name", "parent")
    child = iso.cli("agent", str(src), "terminal", "--v2", "--name", "kid", "--parent", worker)
    check(record(child)["parent"] == worker, "a child of a top-level worker", record(child))
    iso.cli("rm", worker)
    check(record(child)["parent"] == router, "the worker removed, its child goes to the repo's router", record(child))
    iso.cli("rm", router)
    check(record(child).get("parent") is None, "the router removed (no parent), its child is top-level", record(child))

    rc, plain, err = run("spawn", "--repo", str(src), "--name", "pr")
    sid = record(plain)["session"]
    project = Path(lua("return require('isovim.panes').claude_project(...)", str(work / "acme" / "web" / plain.rsplit("/", 1)[1])))
    project.mkdir(parents=True, exist_ok=True)
    url = "https://github.com/acme/web/pull/7"
    lines_ = [{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "input": {"command": "gh pr create --fill"}}]}},
              {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": url}]}}]
    (project / f"{sid}.jsonl").write_text("".join(json.dumps(l) + "\n" for l in lines_))
    rc, out, err = run("autopr", plain)
    meta = iso_dir / ".isovim.json"
    prs = json.loads(meta.read_text()).get("prs", []) if meta.exists() else []
    check(rc == 0 and out == "" and url not in prs, "autopr registers nothing for a new-layout agent", (rc, out, err, prs))
finally:
    subprocess.run(["tmux", "-L", peer_env["ISOVIM_TMUX_SOCKET"], "kill-server"], capture_output=True)
    (Path(os.environ.get("TMUX_TMPDIR", "/tmp")) / f"tmux-{os.getuid()}" / peer_env["ISOVIM_TMUX_SOCKET"]).unlink(missing_ok=True)
    iso.stop()

print(f"\n{len(fails)} failure(s)" + (": " + ", ".join(fails) if fails else ""))
sys.exit(1 if fails else 0)
