"""isovim keeps itself up to date (isovim.update). The pilot TUI runs from a checkout of a bare origin in
its world's dir, with self-update on. A lua/ change pushed to origin is fetched by the timer,
fast-forwarded and hot reloaded, with no restart. `iso update` (an agent's, and bin/iso-hook's after a
git push) checks at once. A tracked change, another branch and a diverged checkout each leave the
checkout alone and say why once; untracked files don't count. A push to starter/, bin/iso and
lazy-lock.json is pulled, then waits for you: not while you're in insert mode or a picker, then a
notice that a key postpones, then after you've been idle the TUI restarts through bin/iso's loop,
which restores the plugins first (a stand-in nvim logs the Lazy restore) and runs the new bin/iso;
the agents' chats, the current workspace, the scope and a composer's draft come back.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/self_update.py"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pynvim

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso, alive  # noqa: E402

fails = []
IDLE, NOTICE = 3000, 2000


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


def git(*args, cwd):
    return subprocess.run(["git", "-c", "user.name=pilot", "-c", "user.email=pilot@example.com", *args],
                          check=True, capture_output=True, text=True, cwd=cwd).stdout.strip()


iso = Iso("self_update", agent_delay=0.2)
iso.env.update({
    "ISOVIM_SELF": "pilothost",
    "ISOVIM_SELF_UPDATE": "1",
    # The timer's first look is 5s after the start; after that only `iso update` asks.
    "ISOVIM_UPDATE_INTERVAL": "600000",
    "ISOVIM_UPDATE_IDLE": str(IDLE),
    "ISOVIM_UPDATE_NOTICE": str(NOTICE),
})
ORIGIN, SRC, DEV = iso.tmp / "origin.git", iso.tmp / "isovim", iso.tmp / "dev"
staging = iso.tmp / "staging"
for part in ("bin", "lua", "starter", "prompts"):
    shutil.copytree(REPO / part, staging / part, symlinks=True)
git("init", "-q", "-b", "main", cwd=staging)
git("add", "-A", cwd=staging)
git("commit", "-q", "-m", "the copy", cwd=staging)
git("init", "-q", "--bare", "-b", "main", str(ORIGIN), cwd=iso.tmp)
git("push", "-q", str(ORIGIN), "main", cwd=staging)
git("clone", "-q", str(ORIGIN), str(SRC), cwd=iso.tmp)
git("clone", "-q", str(ORIGIN), str(DEV), cwd=iso.tmp)
# Untracked, as ~/Programs/isovim's .claude/ and .vibe-wise/ are.
(SRC / ".claude").mkdir()
(SRC / ".claude" / "settings.local.json").write_text("{}\n")
iso.repo = SRC

# A stand-in nvim that logs bin/iso's Lazy restore instead of touching the real plugins.
LAZY_LOG = iso.tmp / "lazy-restore.log"
shim = iso.tmp / "shim"
shim.mkdir()
(shim / "nvim").write_text(f"""#!/usr/bin/env bash
case "$*" in
*"Lazy! restore"*) echo restore >>'{LAZY_LOG}'; exit 0 ;;
esac
exec '{shutil.which("nvim")}' "$@"
""")
(shim / "nvim").chmod(0o755)
iso.env["PATH"] = f"{shim}:{iso.env['PATH']}"


def run(*args, env=None):
    r = subprocess.run([str(SRC / "bin" / "iso"), *args], env=env or iso.env, capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout.strip(), r.stderr


def push(message, edits):
    """Commits edits ({path: fn(text) -> text}) in the other clone and pushes them to origin."""
    git("pull", "-q", "--ff-only", cwd=DEV)
    for rel, fn in edits.items():
        path = DEV / rel
        path.write_text(fn(path.read_text() if path.exists() else ""))
    git("add", "-A", cwd=DEV)
    git("commit", "-q", "-m", message, cwd=DEV)
    git("push", "-q", "origin", "main", cwd=DEV)
    return git("rev-parse", "HEAD", cwd=DEV)


def head():
    return git("rev-parse", "HEAD", cwd=SRC)


def tui_pid():
    return iso.lua("return vim.uv.os_getppid()")


def toasts_after(n, pred):
    return [t for t in iso.toasts()[n:] if pred(t)]


def wait_toast(n, what, pred, timeout=20):
    return iso.wait(lambda: next(iter(toasts_after(n, pred)), None), what, timeout)


def declines_after(n):
    return toasts_after(n, lambda t: t.startswith("isovim isn't updating itself"))


def journal_ends(agent):
    path = iso.tmp / "work" / "acme" / agent[0] / "iso" / "journal" / f"{agent[1]}.jsonl"
    lines = path.read_text().splitlines() if path.exists() else []
    return sum(1 for line in lines if json.loads(line).get("kind") == "turn" and json.loads(line).get("state") == "end")


def composer(ws, agent):
    return iso.lua("local c = require('isovim.acp.chat').get(...) return c and vim.api.nvim_buf_get_lines(c.composer, 0, -1, false) or vim.NIL",
                   ws, agent)


def reattach(old_pid, timeout=40):
    """After a restart: the new TUI's socket, and the TUI process behind it a new one."""
    try:
        iso.nvim.close()
    except Exception:
        pass
    iso.nvim = None

    def up():
        if not Path(iso.env["ISOVIM_SOCK"]).exists():
            return False
        nvim = pynvim.attach("socket", path=iso.env["ISOVIM_SOCK"])
        pid = nvim.exec_lua("return vim.uv.os_getppid()")
        if pid == old_pid:
            nvim.close()
            return False
        iso.nvim = nvim
        return True

    iso.wait(up, "the restarted TUI", timeout)
    iso.wait(lambda: iso.sidebar_win(), "the restarted TUI's sidebar")


try:
    # Pushed before the TUI starts: the timer's first look, 5s in, finds it.
    lua_sha = push("a lua change", {"lua/isovim/sidebar.lua": lambda t: 'vim.g.self_update_probe = "lua"\n' + t})
    iso.start()
    pid = tui_pid()
    print("# a lua/ change, found by the timer")
    wait_toast(0, "the update's toast", lambda t: t.startswith("isovim updated (1 commit)"), 30)
    toast = wait_toast(0, "the hot reload", lambda t: t.startswith("isovim reloaded"))
    check(head() == lua_sha, "the checkout fast-forwarded to origin", (head(), lua_sha))
    check(toast == "isovim reloaded: sidebar.lua" and iso.lua("return vim.g.self_update_probe") == "lua",
          "lua/ hot reloaded onto the pulled code", toast)
    check((SRC / ".claude" / "settings.local.json").exists(), "untracked files are left as they were")
    time.sleep((IDLE + NOTICE) / 1000 + 2)
    check(tui_pid() == pid and not toasts_after(0, lambda t: "restart" in t), "no restart for lua/", iso.toasts())

    print("\n# iso update checks at once: an agent's, and bin/iso-hook's after a git push")
    app = iso.tmp / "src" / "app"
    web = iso.tmp / "src" / "web"
    for repo, name in ((app, "app"), (web, "web")):
        repo.mkdir(parents=True)
        git("init", "-q", str(repo), cwd=iso.tmp)
        git("-C", str(repo), "remote", "add", "origin", f"git@github.com:Acme/{name}.git", cwd=iso.tmp)
    rc, a0, err = run("spawn", "--acp", "--repo", str(app), "--name", "alpha", "hello alpha")
    rc1, a1, err1 = run("spawn", "--acp", "--repo", str(web), "--name", "beta", "hello beta")
    check(a0 == "acme/app/a0" and a1 == "acme/web/a0", "two ACP agents, in two repos", (a0, err, a1, err1))
    iso.wait(lambda: journal_ends(("app", "a0")) >= 1 and journal_ends(("web", "a0")) >= 1, "their first turns", 30)
    agent_env = {**iso.env, "ISOVIM_ADDR": a0}
    n = len(iso.toasts())
    sha = push("prompts, by an agent", {"prompts/self-update-1.md": lambda t: "one\n"})
    started = time.time()
    rc, out, err = run("worker", "update", env=agent_env)
    check(rc == 0 and out == "isovim is checking for an update", "iso worker update asks the TUI", (rc, out, err))
    iso.wait(lambda: head() == sha, "the pull iso worker update asked for", 15)
    check(time.time() - started < 10, "at once, not on the timer", time.time() - started)
    sha = push("prompts, after a push", {"prompts/self-update-2.md": lambda t: "two\n"})
    hook = subprocess.run([str(SRC / "bin" / "iso-hook"), "tool-done"], env={**agent_env, "ISOVIM_STATE": str(iso.tmp / "a0.state")},
                          input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "git push origin HEAD:main"}}),
                          capture_output=True, text=True, timeout=10)
    iso.wait(lambda: head() == sha, "the pull after the hook saw a git push", 15)
    check(hook.returncode == 0, "bin/iso-hook's tool-done after a git push runs iso update", hook.stderr)
    check(not toasts_after(n, lambda t: "reload" in t), "a change outside lua/ and starter/ reloads nothing", iso.toasts()[n:])

    print("\n# a tracked change, another branch, a diverged checkout: left alone, said once")
    (SRC / "prompts" / "self-update-1.md").write_text("mine\n")
    n = len(iso.toasts())
    sha = push("prompts, while dirty", {"prompts/self-update-3.md": lambda t: "three\n"})
    before = head()
    run("update")
    wait_toast(n, "the dirty checkout's note", lambda t: "local changes" in t)
    run("update")
    time.sleep(3)
    check(head() == before and (SRC / "prompts" / "self-update-1.md").read_text() == "mine\n",
          "a tracked change: the checkout and the change stay", head())
    check(declines_after(n) == ["isovim isn't updating itself: its checkout has local changes"], "said once", declines_after(n))
    git("checkout", "--", "prompts/self-update-1.md", cwd=SRC)
    git("checkout", "-q", "-b", "feature", cwd=SRC)
    n = len(iso.toasts())
    run("update")
    wait_toast(n, "the other branch's note", lambda t: "not main" in t)
    run("update")
    time.sleep(3)
    check(head() == before and declines_after(n) == ["isovim isn't updating itself: its checkout is on feature, not main"],
          "another branch: left alone, said once", declines_after(n))
    git("checkout", "-q", "main", cwd=SRC)
    git("branch", "-q", "-D", "feature", cwd=SRC)
    (SRC / "prompts" / "local.md").write_text("a local commit\n")
    git("add", "-A", cwd=SRC)
    git("commit", "-q", "-m", "local", cwd=SRC)
    local = head()
    n = len(iso.toasts())
    run("update")
    wait_toast(n, "the diverged note", lambda t: "diverged" in t)
    run("update")
    time.sleep(3)
    check(head() == local and declines_after(n) == ["isovim isn't updating itself: its checkout has diverged from origin/main"],
          "diverged: left alone, said once", declines_after(n))
    git("reset", "-q", "--hard", "origin/main", cwd=SRC)
    n = len(iso.toasts())
    iso.keys("Escape")
    iso.keys("Space", "i", "U")
    wait_toast(n, "<leader>iU's answer", lambda t: t.startswith("isovim updated") or t == "isovim is up to date")
    check(head() == sha, "<leader>iU checks now and pulls", head())

    print("\n# starter/, bin/iso and lazy-lock.json: a restart, once you're idle")
    iso.cli("open", a1)
    iso.cli("open", a0)
    iso.wait(lambda: iso.lua("return require('isovim').current") == "acme/app", "acme/app current")
    iso.lua("require('isovim.acp.chat').focus_composer('acme/app', 'a0')")
    iso.type("a draft")
    iso.wait(lambda: composer("acme/app", "a0") == ["a draft"], "the draft")
    pid = tui_pid()
    n = len(iso.toasts())
    push("starter, bin/iso and the lockfile", {
        "starter/lua/config/options.lua": lambda t: t + "vim.g.self_update_starter = 'restarted'\n",
        "bin/iso": lambda t: t.replace('set -euo pipefail\n', 'set -euo pipefail\nexport ISOVIM_PROBE=new-bin\n', 1),
        "starter/lazy-lock.json": lambda t: t.replace("\n", " \n", 1),
    })
    run("update")
    toast = wait_toast(n, "the update's toast", lambda t: t.startswith("isovim updated"))
    check("restarts onto it once you've been idle" in toast, "it says it restarts once you're idle", toast)
    toast = wait_toast(n, "isovim.reload's note", lambda t: "starter/ changed" in t)
    check("isovim restarts onto it once you're idle" in toast and "isovim restores the plugins" in toast,
          "the reload's note says the restart is coming, not to restart", toast)
    check(iso.mode() == "i", "in insert mode in the composer", iso.mode())
    time.sleep((IDLE + NOTICE) / 1000 + 2)
    check(tui_pid() == pid and not toasts_after(n, lambda t: "restarting in" in t), "not while you're in insert mode", iso.toasts()[n:])
    iso.keys("Escape")
    iso.lua("Snacks.picker.files()")
    iso.wait(lambda: iso.lua("return #Snacks.picker.get()") == 1, "a picker")
    # Its list, in normal mode, as after <C-w> from its input.
    iso.lua("vim.api.nvim_set_current_win(Snacks.picker.get()[1].list.win.win)")
    time.sleep((IDLE + NOTICE) / 1000 + 2)
    check(tui_pid() == pid and iso.mode() == "n" and not toasts_after(n, lambda t: "restarting in" in t),
          "not while a picker is open", iso.toasts()[n:])
    iso.lua("for _, p in ipairs(Snacks.picker.get()) do p:close() end")
    iso.wait(lambda: iso.lua("return #Snacks.picker.get()") == 0, "the picker closed")
    iso.lua("vim.api.nvim_set_current_win(vim.fn.bufwinid(require('isovim.acp.chat').get('acme/app', 'a0').composer))")
    iso.lua("require('isovim').set_scope('terminals')")
    notice = wait_toast(n, "the notice", lambda t: "restarting in" in t, IDLE / 1000 + 5)
    check(notice == "isovim updated: restarting in 2s · any key to wait", "the notice, once you've been idle", notice)
    iso.keys("Escape")
    postponed = time.time()
    wait_toast(n, "the postponement", lambda t: "waits until you're idle again" in t, 5)
    time.sleep(NOTICE / 1000 + 0.5)
    check(tui_pid() == pid, "a key postpones it", iso.toasts()[n:])
    reattach(pid)
    waited = time.time() - postponed
    check(waited >= (IDLE + NOTICE) / 1000, "then it restarts, once you've been idle again and the notice is up", waited)
    check(iso.lua("return vim.env.ISOVIM_PROBE") == "new-bin" and iso.lua("return vim.g.self_update_starter") == "restarted",
          "the relaunch runs the new bin/iso and the new starter/")
    check(LAZY_LOG.exists() and "restore" in LAZY_LOG.read_text(), "bin/iso restored the plugins for the changed lockfile")
    check(git("status", "--porcelain", "--untracked-files=no", cwd=SRC) == "", "the checkout is clean after it")
    iso.wait(lambda: iso.lua("return require('isovim.acp.chat').get('acme/app', 'a0') ~= nil"), "a0's chat back", 15)
    check(iso.lua("return require('isovim.acp.chat').get('acme/web', 'a0') ~= nil"), "both chats are open again")
    check(iso.lua("local c = require('isovim.acp.chat').get('acme/app', 'a0') return vim.fn.bufwinid(c.buf) ~= -1"),
          "the current workspace's chat is on screen")
    check(iso.lua("return require('isovim').current") == "acme/app", "the same workspace current",
          iso.lua("return require('isovim').current"))
    check(iso.lua("return require('isovim').current_scope") == "terminals", "the same scope (not the workspace's own)",
          iso.lua("return require('isovim').current_scope"))
    check(composer("acme/app", "a0") == ["a draft"], "the composer's draft", composer("acme/app", "a0"))
    check(iso.mode() == "n", "in normal mode", iso.mode())
    lock = int((Path(iso.env["ISOVIM_HOME"]) / "isovim.lock").read_text())
    check(lock == tui_pid() and alive(lock), "the lock names the new TUI", lock)
    check(not (Path(iso.env["ISOVIM_HOME"]) / "restart.json").exists(), "what it saved is used once")
    iso.screenshot("restarted")
finally:
    iso.stop()

print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
