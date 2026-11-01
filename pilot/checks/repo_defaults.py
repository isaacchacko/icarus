"""Repo glyphs and colors: a repo first seen without a color gets the next palette color and the default
glyph written into its config, in first-seen order, wrapping past the palette; the file then decides,
across a restart and over a hand edit; a config that isn't JSON is never written; repo_defaults in
config.json sets the glyph and palette.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/repo_defaults.py"""

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import Iso  # noqa: E402

PALETTE = ["red", "orange", "yellow", "lime", "green", "teal", "cyan", "sky", "blue", "purple", "magenta", "pink"]
REPO_GLYPH = ""


def make_repo(iso, name):
    path = iso.tmp / "src" / name
    path.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "remote", "add", "origin", f"git@github.com:o/{name}.git"], check=True)
    return path


def repo_config(iso, name):
    return iso.tmp / "home" / "repos" / "o" / name / "config.json"


def open_workspace(iso, name):
    """A workspace in a new repo, waited on until the sidebar has seen it and written its color."""
    iso.cli("new", name, "--dir", str(make_repo(iso, name)))
    path = repo_config(iso, name)
    return iso.wait(lambda: path.exists() and "color" in (config := json.loads(path.read_text())) and config, name)


def restart(iso):
    iso.nvim.close()
    for name in (iso.ui, iso.env["ISOVIM_TMUX_SOCKET"]):
        subprocess.run(["tmux", "-L", name, "kill-server"], capture_output=True)
    Path(iso.env["ISOVIM_SOCK"]).unlink(missing_ok=True)
    iso.start()


iso = Iso("repo-defaults")
try:
    home = iso.tmp / "home"
    # Already configured: counts as one color taken, and is never touched.
    pre = repo_config(iso, "pre")
    pre.parent.mkdir(parents=True)
    pre.write_text('{"color": "blue", "note": "keep"}\n')
    # Not JSON: never written, shown with defaults.
    bad = repo_config(iso, "bad")
    bad.parent.mkdir(parents=True)
    bad.write_text("{not json")
    # A glyph but no color: given a color, keeps its glyph.
    glyphed = repo_config(iso, "glyphed")
    glyphed.parent.mkdir(parents=True)
    glyphed.write_text('{"glyph": "G", "extra": {"a": [1, 2]}}')
    iso.start()

    iso.cli("new", "bad", "--dir", str(make_repo(iso, "bad")))
    iso.wait(lambda: iso.lua("return require('isovim.repos').style('o/bad').glyph") == REPO_GLYPH, "bad shown")
    assert bad.read_text() == "{not json", bad.read_text()

    first = open_workspace(iso, "glyphed")
    assert first == {"glyph": "G", "color": "orange", "extra": {"a": [1, 2]}}, first
    seen = {}
    for i in range(1, 14):
        name = f"r{i:02}"
        seen[name] = open_workspace(iso, name)
    # pre and glyphed took slots 0 and 1, so r01 gets the third color, yellow; r10 pink, then r11 wraps to red.
    expected = {f"r{i:02}": PALETTE[(i + 1) % 12] for i in range(1, 14)}
    assert {n: c["color"] for n, c in seen.items()} == expected, seen
    assert all(c["glyph"] == REPO_GLYPH for c in seen.values()), seen
    assert pre.read_text() == '{"color": "blue", "note": "keep"}\n', pre.read_text()
    assert bad.read_text() == "{not json", bad.read_text()

    # iso ls --json carries the same, as hex.
    rows = {row["workspace"]: row["repo"] for row in json.loads(iso.cli("ls", "--json"))}
    assert rows["r01"] == {"name": "o/r01", "glyph": REPO_GLYPH, "color": "#e0af68"}, rows["r01"]
    assert rows["r11"]["color"] == "#f7768e" and rows["glyphed"]["glyph"] == "G", rows

    # A hand edit wins and is left as written.
    hand = '{"glyph": "H", "color": "#123456"}'
    repo_config(iso, "r02").write_text(hand)
    iso.wait(lambda: iso.lua("return require('isovim.repos').style('o/r02').color") == "#123456", "hand edit")
    iso.lua("require('isovim').refresh()")
    assert repo_config(iso, "r02").read_text() == hand

    before = {n: repo_config(iso, n).read_text() for n in seen}
    restart(iso)
    iso.lua("require('isovim').refresh()")
    assert {n: repo_config(iso, n).read_text() for n in seen} == before
    assert iso.lua("return require('isovim.repos').style('o/r13').color") == "#e0af68"
    assert bad.read_text() == "{not json"

    # A custom palette (with an unusable entry dropped) and glyph.
    (home / "config.json").write_text(json.dumps({"repo_defaults": {"glyph": "X", "palette": ["#111111", "bogus", "teal"]}}))
    taken = 15  # pre, glyphed, r01..r13
    for i, name in enumerate(["c1", "c2", "c3"]):
        config = open_workspace(iso, name)
        assert config == {"glyph": "X", "color": ["#111111", "teal"][(taken + i) % 2]}, (name, config)
    print("OK")
finally:
    iso.stop()
