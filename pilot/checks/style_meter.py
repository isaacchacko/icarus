"""The style meter in the sidebar's title: the rank and count of live claude/codex agents on this host,
hidden ones included and terminals not; a rank-up flashes the letter, a rank-down doesn't; the top
rank shimmers; the badges keep to the right; the footer's last line is ISOVIM <commit>.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/style_meter.py"""

import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import Iso  # noqa: E402

RANKS = [(0, "–", "quiet"), (1, "D", "dabbling"), (2, "C", "cooking"), (4, "B", "buzzing"), (7, "S", "swarming"), (10, "SS", "supersonic"), (15, "SSS", "singularity")]


def title_row(iso):
    """The tab line's cells over the sidebar, as drawn."""
    width = iso.lua("return vim.api.nvim_win_get_width(...)", iso.sidebar_win())
    return iso.screen().splitlines()[0][1:width]


def letter_hl(iso):
    return iso.lua("return require('isovim.meter').chunks()[1][2]")


def live(iso):
    return int(re.search(r"\((\d+)\)", title_row(iso)).group(1))


iso = Iso("style-meter", cols=120, rows=30)
try:
    iso.start()
    shots = []
    iso.wait(lambda: title_row(iso).strip().startswith("– (0) - quiet"), "the quiet meter")
    assert letter_hl(iso) == "Comment", letter_hl(iso)
    shots.append(iso.screenshot("0"))

    footer = iso.wait(lambda: (rows := iso.sidebar("footer")) and re.fullmatch(r"ISOVIM [0-9a-f]{7,}", rows[-1]) and rows[-1], "footer")
    print("footer:", footer)

    src = iso.tmp / "src"
    src.mkdir()
    ws = iso.cli("new", "alpha", "--dir", str(src))
    # A terminal never counts.
    iso.cli("agent", ws, "terminal")
    count = 0

    def add(n):
        global count
        for i in range(n):
            hidden = ["--hidden"] if (count + i) % 4 == 3 else []
            iso.cli("agent", ws, "codex" if (count + i) % 3 == 2 else "claude", "--name", f"a{count + i}", *hidden)
        count += n

    # iso new may or may not start main; count from what's running.
    time.sleep(2)
    count = live(iso)
    print("after iso new and a terminal:", count, "live")
    for target, letter, phrase in RANKS[1:]:
        add(target - count)
        iso.wait(lambda: live(iso) == target, f"{target} live")
        row = title_row(iso)
        assert row.startswith(f"{letter} ({target}) - {phrase}"), row
        assert letter_hl(iso).endswith("Flash"), (target, letter_hl(iso))
        if target in (2, 7):
            shots.append(iso.screenshot(f"{target}-flash"))
        iso.wait(lambda: not letter_hl(iso).endswith("Flash"), "flash to settle", timeout=3)
        print(f"{target}: {row.rstrip()}  flash then {letter_hl(iso)}")
        if target in (2, 4, 7, 10):
            shots.append(iso.screenshot(str(target)))

    seen = set()
    end = time.time() + 2
    while time.time() < end:
        seen.add(letter_hl(iso))
        time.sleep(0.1)
    assert seen == {"IsovimRankSSS", "IsovimRankSSSShimmer"}, seen
    print("shimmer:", sorted(seen))
    sessions = iso.lua("return vim.tbl_count(require('isovim.panes').sessions()[...] or {})", ws)
    assert sessions == 16, f"{sessions} sessions: the terminal should be running, and not counted"
    shots.append(iso.screenshot("15"))

    # The badges keep to the right edge, the meter whole.
    iso.focus_sidebar()
    for key in ("H", "P", "L", "T"):
        iso.keys(key)
    row = iso.wait(lambda: (r := title_row(iso)).rstrip().endswith("H P L T") and r, "badges")
    assert row.startswith("SSS (15) - singularity"), row
    print("badges:", row.rstrip())
    shots.append(iso.screenshot("15-badges"))
    for key in ("H", "P", "L", "T"):
        iso.keys(key)

    # Down a rank: no flash.
    for i in range(count - 1, count - 7, -1):
        iso.cli("rm", f"{ws}/a{i}")
    iso.wait(lambda: live(iso) == 9, "9 live")
    assert title_row(iso).startswith("S (9) - swarming"), title_row(iso)
    assert letter_hl(iso) == "IsovimRankS", letter_hl(iso)
    print("down to 9:", letter_hl(iso))

    # A colorscheme change clears the groups; they come back.
    iso.lua("vim.cmd.colorscheme('tokyonight-night')")
    assert iso.lua("return vim.api.nvim_get_hl(0, {name = 'IsovimRankSFlash'}).reverse") is True
    print("shots:", *shots, sep="\n  ")
finally:
    iso.stop()
