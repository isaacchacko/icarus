"""Pilots an isolated isovim for ad hoc debugging: its own ISOVIM_HOME, tmux servers, socket, and a fake
agent instead of Claude. It runs the isovim of the tree this file is in (its own config dir points
at that tree's starter), so a worktree pilots its own code.

The TUI runs headless in a tmux pane: press real keys (keys/type), inspect nvim over RPC (lua),
read the screen (screen) and render it to PNG (screenshot). Run scripts with
`uv run --with pynvim --with pillow --with fonttools python <script>` from pilot/.
On macOS screenshot.py needs ~/.cache/isovim-test/nf351 (Nerd Fonts 3.5.1 symbols-only) for icons;
on Linux it uses JetBrains Mono Nerd Font Mono."""

import atexit
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pynvim

import screenshot

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "pilot" / "out"
# Every process a world starts carries this in its env (tmux servers, the TUI and its nvim --embed
# server, supervisors, fake agents), so stop() finds what outlived its tmux servers.
MARKER = "ISOVIM_PILOT_WORLD"
WORLDS = []


def world_pids(tmp):
    """The live processes of the world at tmp: those carrying its marker, or whose command line or cwd
    names its dir. Never this process."""
    tmp = str(tmp)
    mark = f"{MARKER}={tmp}".encode()
    pids = set()
    if Path("/proc/self/environ").exists():
        for proc in Path("/proc").iterdir():
            if not proc.name.isdigit() or int(proc.name) == os.getpid():
                continue
            try:
                if mark + b"\0" in (proc / "environ").read_bytes() + b"\0":
                    pids.add(int(proc.name))
                elif named(tmp, (proc / "cmdline").read_bytes().decode(errors="replace") + "\0", os.readlink(proc / "cwd")):
                    pids.add(int(proc.name))
            except OSError:
                pass
    else:
        # macOS: ps -E prints each process's env after its command.
        out = subprocess.run(["ps", "-E", "-ww", "-axo", "pid=,command="], capture_output=True, text=True).stdout
        for line in out.splitlines():
            pid, _, rest = line.strip().partition(" ")
            if pid.isdigit() and int(pid) != os.getpid() and (mark.decode() in rest or named(tmp, rest + " ", "")):
                pids.add(int(pid))
    return pids


def named(tmp, cmdline, cwd):
    """Whether a command line (args ended by NUL or space) or cwd names tmp or a path in it, not
    another world whose name starts the same."""
    return any(tmp + end in cmdline for end in ("/", "\0", " ")) or cwd == tmp or cwd.startswith(tmp + "/")


def kill_pids(pids, grace=3):
    """SIGTERM, then SIGKILL whatever is left after grace seconds: a TUI's nvim server busy in Lua
    ignores its client going away, and one held 4 GB for days."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in pids:
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        deadline = time.time() + grace
        while time.time() < deadline:
            pids = {pid for pid in pids if alive(pid)}
            if not pids:
                return
            time.sleep(0.05)


def alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    # A zombie is gone but for its parent's wait.
    try:
        return Path(f"/proc/{pid}/stat").read_text().split(") ")[-1][0] != "Z"
    except OSError:
        return True


def reap_stale():
    """Stops the worlds whose pilot died without stopping them (SIGKILL, an OOM kill): their owner pid
    is gone. A world still in use by another run is left alone."""
    for tmp in Path(tempfile.gettempdir()).glob("iso-*"):
        owner = tmp / "owner.pid"
        try:
            pid = int(owner.read_text().strip())
        except (OSError, ValueError):
            continue
        if not alive(pid):
            kill_pids(world_pids(tmp))
            shutil.rmtree(tmp, ignore_errors=True)


def _stop_all():
    for world in list(WORLDS):
        world.stop()


def guard(tmp, owner, sockets):
    """Run by a world's guardian (its own session, so a kill of the pilot's group spares it): once
    the pilot that owns the world ends without stopping it, however it ended (a SIGTERM from a
    timeout, which pynvim's event loop leaves at its default, a SIGKILL, the OOM killer), it ends
    the world's processes and removes its dir. A world stopped as it should be just leaves."""
    tmp = Path(tmp)
    while tmp.exists() and alive(owner):
        time.sleep(0.5)
    if tmp.exists():
        kill_pids(world_pids(tmp))
        for name in sockets:
            Iso.kill_tmux(name)
        shutil.rmtree(tmp, ignore_errors=True)


atexit.register(_stop_all)


class Iso:
    def __init__(self, name, cols=140, rows=40, agent_delay=1):
        self.name = name
        self.cols, self.rows = cols, rows
        # Short and outside the scratch tree: unix socket paths cap near 104 bytes.
        reap_stale()
        self.tmp = Path(tempfile.mkdtemp(prefix="iso-"))
        (self.tmp / "owner.pid").write_text(str(os.getpid()))
        WORLDS.append(self)
        self.ui = f"isot-ui-{os.getpid()}-{name}"[:60]
        # The isovim it runs: a check that edits the source sets a copy, so no other isovim reloads.
        self.repo = REPO
        # Never the caller's isovim identity: a pilot run from inside an agent would act as that agent.
        # Nor the Claude Code session it may run in: CLAUDECODE, CLAUDE_CODE_* (its messaging socket
        # among them), CLAUDE_PID and TMUX_PANE would reach real agents. A login or provider set in
        # the env (CLAUDE_CODE_OAUTH_TOKEN, CLAUDE_CODE_USE_*) stays.
        def kept(k):
            if k.startswith("ISOVIM_") or k in ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "TMUX_PANE"):
                return False
            return not k.startswith("CLAUDE_CODE_") or k == "CLAUDE_CODE_OAUTH_TOKEN" or k.startswith("CLAUDE_CODE_USE_")
        inherited = {k: v for k, v in os.environ.items() if kept(k)}
        self.env = {
            **inherited,
            MARKER: str(self.tmp),
            "ISOVIM_HOME": str(self.tmp / "home"),
            # Never the real ~/.iso: a pilot that cleans up work must only see its own.
            "ISOVIM_WORK": str(self.tmp / "work"),
            "ISOVIM_TMUX_SOCKET": f"isot-panes-{os.getpid()}-{name}"[:60],
            "ISOVIM_SOCK": str(self.tmp / "s"),
            "ISOVIM_AGENT_CMD": str(REPO / "pilot" / "fake-agent"),
            # An ACP agent's supervisor runs a fake adapter, which logs what it's sent here.
            "ISOVIM_ACP_CMD": str(REPO / "pilot" / "fake-acp-agent"),
            "FAKE_ACP_LOG": str(self.tmp / "fake-acp.log"),
            "ISOVIM_CLAUDE_JSON": str(self.tmp / "claude.json"),
            "ISOVIM_NOTIFY_LOG": str(self.tmp / "notifications.log"),
            "FAKE_AGENT_DELAY": str(agent_delay),
            # Logged in, as `claude auth status` and `codex login status` say through a stand-in
            # (isovim.auth); a check writes false to FAKE_AUTH_FILE to log out. Never kept, so a
            # change shows at once.
            "ISOVIM_AUTH_CLAUDE": str(REPO / "pilot" / "fake-auth"),
            "ISOVIM_AUTH_CODEX": str(REPO / "pilot" / "fake-auth"),
            "FAKE_AUTH_FILE": str(self.tmp / "fake-auth"),
            "ISOVIM_AUTH_TTL": "0",
            # No real other hosts in the sidebar; pilots that want one set it.
            "ISOVIM_PEERS": "-",
            # A pilot with a fake peer (fake-ssh runs the remote side here) syncs config into its
            # tmp dir, never into a real home.
            "ISOVIM_SYNC_ROOT": str(self.tmp / "peer-home"),
            # bin/iso links isovim's config here to this tree's starter, which loads this tree.
            "XDG_CONFIG_HOME": str(self.tmp / "config"),
        }
        (self.tmp / "config").mkdir()
        self.env.pop("TMUX", None)
        (self.tmp / "claude.json").write_text("{}")
        self.nvim = None
        # Not marked as the world's, and naming its dir only in its env, so the sweep spares it.
        subprocess.Popen(
            [sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import iso, os, json;"
             " iso.guard(os.environ['ISOVIM_PILOT_GUARD'], int(sys.argv[2]), json.loads(sys.argv[3]))",
             str(Path(__file__).resolve().parent), str(os.getpid()), json.dumps([self.ui, self.env["ISOVIM_TMUX_SOCKET"]])],
            env={k: v for k, v in os.environ.items() if k != MARKER} | {"ISOVIM_PILOT_GUARD": str(self.tmp)},
            cwd="/", stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )

    # lifecycle

    def start(self):
        """A pilot that fails to come up is stopped, so its TUI doesn't keep running headless."""
        try:
            self._tmux_ui("-f", "/dev/null", "new-session", "-d", "-x", str(self.cols), "-y", str(self.rows), str(self.repo / "bin" / "iso"))
            for option in (("escape-time", "0"), ("focus-events", "on"), ("default-terminal", "tmux-256color")):
                self._tmux_ui("set-option", "-g", *option)
            self.wait(lambda: Path(self.env["ISOVIM_SOCK"]).exists(), "TUI socket")
            self.nvim = pynvim.attach("socket", path=self.env["ISOVIM_SOCK"])
            self.wait(lambda: self.sidebar_win(), "sidebar")
        except BaseException:
            self.stop()
            raise
        return self

    def close_tui(self):
        """Quits the TUI alone, as closing its terminal would; the agents' tmux server stays up."""
        if self.nvim:
            try:
                self.nvim.close()
            except Exception:
                pass
            self.nvim = None
        self.kill_tmux(self.ui)
        lock = Path(self.env["ISOVIM_HOME"]) / "isovim.lock"

        def gone():
            try:
                os.kill(int(lock.read_text().strip()), 0)
                return False
            except (OSError, ValueError):
                return True

        self.wait(gone, "the TUI to quit")

    def stop(self):
        """Ends every process of the world, on success, failure or timeout alike (atexit and SIGTERM
        call it too), then removes its dir. Safe to call twice."""
        if self.nvim:
            try:
                self.nvim.close()
            except Exception:
                pass
            self.nvim = None
        for name in (self.ui, self.env["ISOVIM_TMUX_SOCKET"]):
            self.kill_tmux(name)
        kill_pids(world_pids(self.tmp))
        shutil.rmtree(self.tmp, ignore_errors=True)
        if self in WORLDS:
            WORLDS.remove(self)

    @staticmethod
    def kill_tmux(name, timeout=10):
        """Kills a tmux server and waits for its process to end: kill-server returns while the server
        is still going down, and a client started then reaches the dying server and fails ("server
        exited unexpectedly"). kill-server can leave the socket file behind; hundreds piled up in /tmp."""
        pid = subprocess.run(["tmux", "-L", name, "display-message", "-p", "#{pid}"], capture_output=True, text=True).stdout.strip()
        subprocess.run(["tmux", "-L", name, "kill-server"], capture_output=True)
        deadline = time.time() + timeout
        while pid.isdigit() and time.time() < deadline:
            try:
                os.kill(int(pid), 0)
            except OSError:
                break
            time.sleep(0.05)
        sockets = Path(os.environ.get("TMUX_TMPDIR", "/tmp")) / f"tmux-{os.getuid()}"
        (sockets / name).unlink(missing_ok=True)

    # driving

    def _tmux_ui(self, *args):
        result = subprocess.run(["tmux", "-L", self.ui, *args], env=self.env, capture_output=True, text=True)
        if result.returncode != 0:
            raise AssertionError(f"tmux {' '.join(args)} failed ({result.returncode}): {result.stderr.strip()}")
        return result

    def keys(self, *keys):
        """tmux key names: "Enter", "Escape", "C-q", "a"."""
        self._tmux_ui("send-keys", "-t", "=0:", *keys)
        time.sleep(0.15)

    def type(self, text):
        self._tmux_ui("send-keys", "-t", "=0:", "-l", text)
        time.sleep(0.15)

    def lua(self, code, *args):
        return self.nvim.exec_lua(code, *args)

    def cli(self, *args, check=True):
        result = subprocess.run([str(self.repo / "bin" / "iso"), *args], env=self.env, capture_output=True, text=True)
        if check and result.returncode != 0:
            raise AssertionError(f"iso {' '.join(args)} failed: {result.stderr}")
        return result.stdout.strip()

    def wait(self, check, what, timeout=10):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            try:
                last = check()
                if last:
                    return last
            except Exception as error:
                last = error
            time.sleep(0.1)
        raise AssertionError(f"timed out waiting for {what} (last: {last!r})\n--- screen ---\n{self.screen()}")

    # viewing

    def screen(self):
        """The TUI's screen; a check that hasn't started it (or whose TUI quit) gets a note instead."""
        try:
            return self._tmux_ui("capture-pane", "-p", "-t", "=0:").stdout
        except AssertionError:
            return "(no TUI)"

    def screenshot(self, label):
        """Renders the TUI as it looks now to pilot/out/<name>-<label>.png."""
        # -N keeps each line's trailing blanks, which carry the background they were drawn with.
        ansi = self._tmux_ui("capture-pane", "-p", "-e", "-N", "-t", "=0:").stdout
        OUT.mkdir(exist_ok=True)
        return screenshot.render(ansi, OUT / f"{self.name}-{label}.png", self.cols, self.rows)

    def sidebar_win(self, role="list"):
        """The sidebar column's window: inbox, list (the host list), terminals or footer."""
        return self.lua(
            "for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do"
            " if vim.b[vim.api.nvim_win_get_buf(w)].isovim_sidebar == ... then return w end end",
            role,
        )

    def sidebar(self, role="list"):
        """Non-empty rows of a sidebar window (the host list by default), e.g. ["⠋ alpha", "● beta"]."""
        win = self.sidebar_win(role)
        rows = self.lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(...), 0, -1, false)", win) if win else []
        return [row.strip() for row in rows if row.strip()]

    def tabs(self):
        """Listed buffers, as the tab bar shows them (bufferline's own state goes stale while it hides)."""
        return self.lua(
            "return vim.tbl_map(function(b) return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ':t') end,"
            " vim.tbl_filter(function(b) return vim.bo[b].buflisted end, vim.api.nvim_list_bufs()))"
        )

    def mode(self):
        return self.lua("return vim.api.nvim_get_mode().mode")

    def current_buffer(self):
        return self.lua("return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t')")

    def toasts(self):
        return self.lua(
            "return vim.tbl_map(function(n) return n.msg end,"
            " vim.tbl_filter(function(n) return n.title == 'isovim' end, Snacks.notifier.get_history()))"
        )

    def desktop_notifications(self):
        log = Path(self.env["ISOVIM_NOTIFY_LOG"])
        return log.read_text().splitlines() if log.exists() else []

    def focus_sidebar(self):
        self.lua("vim.api.nvim_set_current_win(...)", self.sidebar_win())

    def workspace_id(self, name):
        rows = json.loads(self.cli("ls", "--json"))
        return next(row["id"].split("/")[0] for row in rows if row["workspace"] == name)
