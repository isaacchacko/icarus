"""The sidebar's Terminals window: above the footer, a C-j/C-k stop, collapsible, sized to its rows; it
lists the shown host's terminals and repo script panes (robot at the right, `<action> · <workspace>`),
which leave the host list; t opens a terminal in ~; Enter opens, r renames, d removes; another host's
come from its `iso ls`; the help lists the window's keys.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/terminals.py"""

import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

ROBOT = "\U000f06a9"

iso = Iso("terminals", cols=120, rows=34)
# A fake peer: `ssh other iso ls --json` prints a terminal, a script pane and an agent.
remote_rows = [
    {"id": "r1/main", "workspace": "beta", "agent": "main", "kind": "claude", "status": "idle", "hidden": False},
    {"id": "r1/terminal", "workspace": "beta", "agent": "remote-shell", "kind": "terminal", "status": "idle", "hidden": False},
    {"id": "r1/run", "workspace": "beta", "agent": "run", "kind": "command", "script": "run", "status": "idle", "hidden": False},
]
(iso.tmp / "remote.json").write_text(json.dumps(remote_rows))
(iso.tmp / "remote-iso").write_text(f"#!/bin/sh\ncat {iso.tmp / 'remote.json'}\n")
os.chmod(iso.tmp / "remote-iso", 0o755)
(iso.tmp / "ssh-env").write_text("")
iso.env.update(
    ISOVIM_PEERS="other=other",
    ISOVIM_SSH=str(REPO / "pilot" / "fake-ssh"),
    ISOVIM_REMOTE_BIN=str(iso.tmp / "remote-iso"),
    FAKE_SSH_ENV=str(iso.tmp / "ssh-env"),
)


def current_role():
    return iso.lua("return vim.b.isovim_sidebar")


def row_of(rows, text):
    return next(i for i, row in enumerate(rows) if text in row)


try:
    iso.start()
    src = iso.tmp / "src"
    (src / ".isovim").mkdir(parents=True)
    (src / ".isovim" / "config.json").write_text(json.dumps({"run": ["echo serving", "sleep 300"]}))
    ws = iso.cli("new", "alpha", "--dir", str(src))
    iso.wait(lambda: any("alpha" in row for row in iso.sidebar()), "alpha in the list")

    # Terminals sits right above the footer.
    layout = iso.lua(
        "local out = {} for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do"
        " local role = vim.b[vim.api.nvim_win_get_buf(w)].isovim_sidebar"
        " if role then out[#out + 1] = {role, vim.api.nvim_win_get_position(w)[1], vim.api.nvim_win_get_height(w)} end end return out"
    )
    layout.sort(key=lambda entry: entry[1])
    print("column:", layout)
    assert [entry[0] for entry in layout] == ["inbox", "list", "terminals", "footer"], layout
    assert iso.sidebar("terminals") == ["▾ Terminals 0"], iso.sidebar("terminals")

    # t in the list: a terminal, in ~.
    iso.focus_sidebar()
    iso.keys("t")
    iso.wait(lambda: iso.lua("return vim.b.isovim_agent") == "terminal", "the new terminal in the main window")
    cwd = iso.wait(lambda: (iso.lua("return (require('isovim.panes').titles()[...] or {}).path", f"{ws}/terminal")), "the terminal's pane")
    print("terminal cwd:", cwd)
    assert os.path.realpath(cwd) == os.path.realpath(os.path.expanduser("~")), cwd

    # A run script pane: robot at the right, named for its action and workspace.
    iso.lua("require('isovim.scripts').start(..., 'run')", ws)
    rows = iso.wait(lambda: len(r := iso.sidebar("terminals")) == 3 and r, "two terminals")
    print("terminals:", rows)
    assert rows[0] == "▾ Terminals 2", rows
    script_row = rows[row_of(rows, "run · alpha")]
    assert script_row.endswith(ROBOT), script_row
    raw = iso.lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(...), 0, -1, false)", iso.sidebar_win("terminals"))
    width = iso.lua("return vim.api.nvim_win_get_width(...)", iso.sidebar_win("terminals"))
    robot_line = next(line for line in raw if "run · alpha" in line)
    assert iso.lua("return vim.api.nvim_strwidth(...)", robot_line) == width, (robot_line, width)
    assert not rows[row_of(rows, "terminal")].endswith(ROBOT), rows
    assert iso.lua("return vim.api.nvim_win_get_height(...)", iso.sidebar_win("terminals")) == 3

    # Moved out of the host list, not copied.
    iso.focus_sidebar()
    iso.keys("Tab")
    listed = iso.wait(lambda: len(r := iso.sidebar()) > 1 and r, "alpha expanded")
    print("list:", listed)
    assert not any("terminal" in row or "run" in row for row in listed), listed
    shots = [iso.screenshot("local")]

    # C-j / C-k reach it.
    iso.keys("C-j")
    assert current_role() == "terminals", current_role()
    iso.keys("C-j")
    assert current_role() == "footer", current_role()
    iso.keys("C-k")
    assert current_role() == "terminals", current_role()

    # Tab collapses and expands; Enter on the title too.
    iso.keys("Tab")
    iso.wait(lambda: iso.sidebar("terminals") == ["▸ Terminals 2"], "collapsed")
    assert iso.lua("return vim.api.nvim_win_get_height(...)", iso.sidebar_win("terminals")) == 1
    iso.keys("Enter")
    iso.wait(lambda: len(iso.sidebar("terminals")) == 3, "expanded")

    # Enter opens the script pane in the main window.
    iso.lua("vim.api.nvim_win_set_cursor(0, {(...), 0})", row_of(iso.sidebar("terminals"), "run · alpha") + 1)
    iso.keys("Enter")
    iso.wait(lambda: iso.lua("return vim.b.isovim_agent") == "run", "the run pane opened")
    assert iso.lua("return vim.b.isovim_sidebar") is None

    # r renames the terminal.
    iso.lua("vim.api.nvim_set_current_win(...)", iso.sidebar_win("terminals"))
    iso.lua("vim.api.nvim_win_set_cursor(0, {(...), 0})", row_of(iso.sidebar("terminals"), "terminal") + 1)
    iso.keys("r")
    time.sleep(0.3)
    iso.keys("C-u")
    iso.type("logs")
    iso.keys("Enter")
    iso.wait(lambda: any("logs" in row for row in iso.sidebar("terminals")), "renamed")

    # The help lists the window.
    iso.keys("?")
    help_lines = iso.wait(
        lambda: iso.lua(
            "for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do if vim.api.nvim_win_get_config(w).relative ~= '' then"
            " local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)"
            " if lines[1] and lines[1]:match('^# Sidebar') then return lines end end end"
        ),
        "help",
    )
    section = help_lines[help_lines.index(next(l for l in help_lines if l.startswith("# Terminals"))):]
    print("help:", section[:8])
    assert any("collapse or expand Terminals" in line for line in section[:8]), section
    iso.keys("G")
    shots.append(iso.screenshot("help"))
    iso.keys("q")

    # d removes it.
    iso.lua("vim.api.nvim_set_current_win(...)", iso.sidebar_win("terminals"))
    iso.lua("vim.api.nvim_win_set_cursor(0, {(...), 0})", row_of(iso.sidebar("terminals"), "logs") + 1)
    iso.keys("d")
    time.sleep(0.4)
    print(iso.screen())
    iso.keys("y")
    time.sleep(0.2)
    iso.keys("Enter")
    iso.wait(lambda: iso.sidebar("terminals")[0] == "▾ Terminals 1", "removed")

    # The other host's terminals, from its `iso ls`; its host list keeps only the agent.
    iso.keys(">")
    rows = iso.wait(lambda: len(r := iso.sidebar("terminals")) == 3 and r, "the other host's terminals")
    print("other's terminals:", rows)
    assert any("remote-shell" in row for row in rows), rows
    assert rows[row_of(rows, "run · beta")].endswith(ROBOT), rows
    iso.lua("vim.api.nvim_set_current_win(...)", iso.sidebar_win())
    iso.keys("Tab")
    listed = iso.wait(lambda: len(r := iso.sidebar()) > 1 and r, "beta expanded")
    print("other's list:", listed)
    assert not any("remote-shell" in row or "run" in row for row in listed), listed
    shots.append(iso.screenshot("remote"))
    iso.keys("<")
    iso.wait(lambda: iso.sidebar("terminals")[0] == "▾ Terminals 1", "back to this host")
    print("ok", *shots)
finally:
    iso.stop()
