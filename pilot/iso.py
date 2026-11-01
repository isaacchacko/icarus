"""Pilots an isolated isovim for ad hoc debugging: its own ISOVIM_HOME, tmux servers, socket, and a fake
agent instead of Claude. It runs the isovim of the tree this file is in (its own config dir points
at that tree's starter), so a worktree pilots its own code.

The TUI runs headless in a tmux pane: press real keys (keys/type), inspect nvim over RPC (lua),
read the screen (screen) and render it to PNG (screenshot). Run scripts with
`uv run --with pynvim --with pillow --with fonttools python <script>` from pilot/.
On macOS screenshot.py needs ~/.cache/isovim-test/nf351 (Nerd Fonts 3.5.1 symbols-only) for icons;
on Linux it uses JetBrains Mono Nerd Font Mono."""

import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import pynvim

import screenshot

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "pilot" / "out"


class Iso:
    def __init__(self, name, cols=140, rows=40, agent_delay=1):
        self.name = name
        self.cols, self.rows = cols, rows
        # Short and outside the scratch tree: unix socket paths cap near 104 bytes.
        self.tmp = Path(tempfile.mkdtemp(prefix="iso-"))
        self.ui = f"isot-ui-{os.getpid()}-{name}"[:60]
        self.env = {
            **os.environ,
            "ISOVIM_HOME": str(self.tmp / "home"),
            # Never the real ~/iso: a pilot that cleans up work must only see its own.
            "ISOVIM_WORK": str(self.tmp / "work"),
            "ISOVIM_TMUX_SOCKET": f"isot-panes-{os.getpid()}-{name}"[:60],
            "ISOVIM_SOCK": str(self.tmp / "s"),
            "ISOVIM_AGENT_CMD": str(REPO / "pilot" / "fake-agent"),
            "ISOVIM_CLAUDE_JSON": str(self.tmp / "claude.json"),
            "ISOVIM_NOTIFY_LOG": str(self.tmp / "notifications.log"),
            "FAKE_AGENT_DELAY": str(agent_delay),
            # No real other hosts in the sidebar; pilots that want one set it.
            "ISOVIM_PEERS": "-",
            # bin/iso links isovim's config here to this tree's starter, which loads this tree.
            "XDG_CONFIG_HOME": str(self.tmp / "config"),
        }
        (self.tmp / "config").mkdir()
        self.env.pop("TMUX", None)
        (self.tmp / "claude.json").write_text("{}")
        self.nvim = None

    # lifecycle

    def start(self):
        """A pilot that fails to come up is stopped, so its TUI doesn't keep running headless."""
        try:
            self._tmux_ui("-f", "/dev/null", "new-session", "-d", "-x", str(self.cols), "-y", str(self.rows), str(REPO / "bin" / "iso"))
            for option in (("escape-time", "0"), ("focus-events", "on"), ("default-terminal", "tmux-256color")):
                self._tmux_ui("set-option", "-g", *option)
            self.wait(lambda: Path(self.env["ISOVIM_SOCK"]).exists(), "TUI socket")
            self.nvim = pynvim.attach("socket", path=self.env["ISOVIM_SOCK"])
            self.wait(lambda: self.sidebar_win(), "sidebar")
        except BaseException:
            self.stop()
            raise
        return self

    def stop(self):
        if self.nvim:
            try:
                self.nvim.close()
            except Exception:
                pass
        # kill-server can leave the socket file behind; hundreds of them piled up in /tmp.
        sockets = Path(os.environ.get("TMUX_TMPDIR", "/tmp")) / f"tmux-{os.getuid()}"
        for name in (self.ui, self.env["ISOVIM_TMUX_SOCKET"]):
            subprocess.run(["tmux", "-L", name, "kill-server"], capture_output=True)
            (sockets / name).unlink(missing_ok=True)
        shutil.rmtree(self.tmp, ignore_errors=True)

    # driving

    def _tmux_ui(self, *args):
        return subprocess.run(["tmux", "-L", self.ui, *args], env=self.env, capture_output=True, text=True, check=True)

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
        result = subprocess.run([str(REPO / "bin" / "iso"), *args], env=self.env, capture_output=True, text=True)
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
        return self._tmux_ui("capture-pane", "-p", "-t", "=0:").stdout

    def screenshot(self, label):
        """Renders the TUI as it looks now to pilot/out/<name>-<label>.png."""
        ansi = self._tmux_ui("capture-pane", "-p", "-e", "-t", "=0:").stdout
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
