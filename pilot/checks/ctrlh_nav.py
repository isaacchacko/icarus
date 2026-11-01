"""<C-h> to the sidebar from the main column and <C-l> back: from an ACP agent's composer in insert
mode (no <Esc> first), its chat, a surface view and its input box, <C-h> lands in the sidebar's
list in normal mode on the row you last left there, found by what it stands for even after a
refresh moved it (an agent spawned meanwhile, listed above it); a row that's gone gives way to the
agent of the window you came from; it goes to the sidebar window you were last in (Terminals here);
<C-l> comes back to the window you came from, typing again where you were with the text intact. The
place you left survives a hot reload, and the composer's hint and ? name <C-h>.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/ctrlh_nav.py"""

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


def git(*args):
    subprocess.run(["git", *args], check=True, capture_output=True)


iso = Iso("ctrlh_nav", agent_delay=0.2)
iso.env["ISOVIM_SELF"] = "pilothost"


def run(*args, timeout=60):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


def lua(code, *args):
    return iso.lua(code, *args)


def list_lines():
    return lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(...), 0, -1, false)", iso.sidebar_win())


def row_of(name):
    """The list's line (1-based) whose row names the agent, or None."""
    for i, line in enumerate(list_lines(), 1):
        if line.rstrip().endswith(" " + name) or f" {name} " in line:
            return i
    return None


def where():
    """Where you are: the sidebar window's role (or the buffer's kind), the mode, and the line under
    the cursor."""
    return lua("""
      local b = vim.api.nvim_get_current_buf()
      local kind = vim.b[b].isovim_sidebar or (vim.b[b].isovim_composer and 'composer:' .. vim.b[b].isovim_agent)
        or (vim.b[b].isovim_acp and 'chat:' .. vim.b[b].isovim_agent) or (vim.b[b].isovim_surface_input and 'input')
        or (vim.b[b].isovim_surface and 'surface') or vim.bo[b].filetype
      return { kind = kind, mode = vim.api.nvim_get_mode().mode, line = vim.api.nvim_get_current_line(),
        lnum = vim.api.nvim_win_get_cursor(0)[1] }
    """)


def composer(agent):
    return lua("local c = require('isovim.acp.chat').get('acme/app', ...) return c and vim.api.nvim_buf_get_lines(c.composer, 0, -1, false) or vim.NIL", agent)


def soon(fn, timeout=3):
    try:
        return bool(iso.wait(fn, "a key's effect", timeout))
    except AssertionError:
        return False


def in_list_on(name):
    return lambda: (lambda w: w["kind"] == "list" and w["mode"] == "n" and name in w["line"])(where())


def cursor_to(name):
    """Puts the list's cursor on the agent's row, as j/k would."""
    lua("vim.api.nvim_win_set_cursor(0, { ..., 0 })", row_of(name))


try:
    iso.start()
    app = iso.tmp / "src" / "app"
    app.mkdir(parents=True)
    git("init", "-q", str(app))
    git("-C", str(app), "remote", "add", "origin", "git@github.com:Acme/app.git")
    # Agents spawned here list above app's: repos go by name.
    early = iso.tmp / "src" / "aardvark"
    early.mkdir(parents=True)
    git("init", "-q", str(early))
    git("-C", str(early), "remote", "add", "origin", "git@github.com:Acme/aardvark.git")
    for name in ("alpha", "beta"):
        rc, out, err = run("spawn", "--acp", "--repo", str(app), "--name", name)
        assert rc == 0, err
    iso.wait(lambda: row_of("alpha") and row_of("beta"), "alpha and beta listed")

    print("# from the composer, in insert mode")
    iso.focus_sidebar()
    cursor_to("beta")
    iso.keys("Enter")
    iso.wait(lambda: where()["kind"] == "composer:a1" and where()["mode"] == "i", "beta's composer, typing")
    iso.type("half a thought")
    iso.wait(lambda: composer("a1") == ["half a thought"], "the text typed")
    before = row_of("beta")
    rc, out, err = run("spawn", "--acp", "--repo", str(early), "--name", "gamma")
    iso.wait(lambda: row_of("gamma") and row_of("beta") != before, "gamma listed, beta's row moved")
    check(row_of("gamma") < row_of("beta"), "the refresh put gamma's row above beta's", list_lines())
    check(where()["kind"] == "composer:a1" and where()["mode"] == "i", "still typing in the composer", where())
    iso.screenshot("typing")
    iso.keys("C-h")
    check(soon(in_list_on("beta")), "<C-h> from insert mode: the sidebar's list, normal mode, on beta's row", (where(), list_lines()))
    iso.screenshot("sidebar")
    iso.keys("C-l")
    check(soon(lambda: where()["kind"] == "composer:a1" and where()["mode"] == "i"), "<C-l> back to the composer, typing", where())
    check(composer("a1") == ["half a thought"], "the text intact", composer("a1"))
    iso.type(" finished")
    check(soon(lambda: composer("a1") == ["half a thought finished"]), "typing goes on where it left off", composer("a1"))

    print("\n# the row you left, by identity")
    iso.keys("C-h")
    iso.wait(in_list_on("beta"), "the list on beta")
    cursor_to("alpha")
    iso.keys("C-l")
    iso.wait(lambda: where()["kind"] == "composer:a1", "back in the composer")
    iso.keys("Escape")
    iso.wait(lambda: where()["mode"] == "n", "normal mode in the composer")
    # Not LazyVim's <C-w>h, which took the column's window level with the composer: Terminals.
    iso.keys("C-h")
    check(soon(in_list_on("alpha")), "<C-h> from the composer in normal mode: the list (not Terminals or the footer), on alpha's row",
          (where(), list_lines()))
    iso.keys("C-l")
    check(soon(lambda: where()["kind"] == "composer:a1" and where()["mode"] == "n"), "<C-l> back to the composer, in normal mode", where())
    iso.keys("C-k")
    iso.wait(lambda: where()["kind"] == "chat:a1", "beta's chat")
    before = row_of("alpha")
    rc, out, err = run("spawn", "--acp", "--repo", str(early), "--name", "delta")
    iso.wait(lambda: row_of("delta") and row_of("alpha") != before, "delta listed, alpha's row moved")
    iso.keys("C-h")
    check(soon(in_list_on("alpha")), "<C-h> from the chat: on alpha's row, the one left, not the chat's agent", (where(), list_lines()))
    iso.keys("C-l")
    check(soon(lambda: where()["kind"] == "chat:a1" and where()["mode"] == "n"), "<C-l> back to the chat, in normal mode", where())

    print("\n# a row that's gone")
    iso.keys("C-h")
    iso.wait(in_list_on("alpha"), "the list on alpha")
    cursor_to("delta")
    iso.keys("C-l")
    iso.wait(lambda: where()["kind"] == "chat:a1", "back in the chat")
    rc, out, err = run("rm", "acme/aardvark/a1")
    check(rc == 0, "delta removed", err)
    iso.wait(lambda: not row_of("delta"), "delta's row gone")
    iso.keys("C-h")
    check(soon(in_list_on("beta")), "with its row gone, <C-h> lands on the agent you came from", (where(), list_lines()))

    print("\n# the sidebar window you were last in")
    iso.keys("C-j")
    iso.wait(lambda: where()["kind"] == "terminals", "Terminals")
    iso.keys("C-l")
    iso.wait(lambda: where()["kind"] == "chat:a1", "back in the chat")
    iso.keys("C-h")
    check(soon(lambda: where()["kind"] == "terminals"), "<C-h> goes to Terminals, where you left the column", where())
    iso.keys("C-k")
    iso.wait(lambda: where()["kind"] == "list", "the list again")
    cursor_to("beta")
    iso.keys("C-l")
    iso.wait(lambda: where()["kind"] == "chat:a1", "back in the chat")

    print("\n# a surface and its input box")
    iso_dir = iso.tmp / "work" / "acme" / "app" / "iso"
    (iso_dir / "notes.md").write_text("---\nname: Notes\n---\nThe plan.\n")
    iso.wait(lambda: lua("return vim.iter(require('isovim.surfaces').list('acme/app')):find(function(e) return e.name == 'notes' end) ~= nil"),
             "the watcher to see notes", 15)
    lua("""
      local entry = vim.iter(require('isovim.surfaces').list('acme/app')):find(function(e) return e.name == 'notes' end)
      local view = require('isovim.surface_view').open(entry)
      vim.api.nvim_set_current_win(vim.fn.bufwinid(view.input))
      vim.cmd.startinsert()
    """)
    iso.wait(lambda: where()["kind"] == "input" and where()["mode"] == "i", "the input box, typing")
    iso.type("for the router")
    iso.keys("C-h")
    check(soon(in_list_on("beta")), "<C-h> from a surface's input box in insert mode: the list, on the row left", where())
    iso.keys("C-l")
    check(soon(lambda: where()["kind"] == "input" and where()["mode"] == "i"), "<C-l> back to the input box, typing", where())
    iso.type(" now")
    check(soon(lambda: lua("return vim.api.nvim_get_current_line()") == "for the router now"), "its text intact, typing on",
          lua("return vim.api.nvim_get_current_line()"))
    iso.keys("Escape")
    iso.keys("C-k")
    iso.wait(lambda: where()["kind"] == "surface", "the surface view")
    iso.keys("C-h")
    check(soon(in_list_on("beta")), "<C-h> from the surface view", where())
    iso.keys("C-l")
    check(soon(lambda: where()["kind"] == "surface"), "<C-l> back to the surface view", where())

    print("\n# through a hot reload")
    lua("require('isovim.acp.chat').focus_composer('acme/app', 'a1')")
    iso.wait(lambda: where()["kind"] == "composer:a1" and where()["mode"] == "i", "beta's composer")
    iso.keys("C-h")
    iso.wait(in_list_on("beta"), "the list on beta")
    cursor_to("gamma")
    iso.keys("C-l")
    iso.wait(lambda: where()["kind"] == "composer:a1" and where()["mode"] == "i", "the composer")
    check(lua("return require('isovim.reload').reload()") is True, "the hot reload went through")
    iso.wait(lambda: where()["kind"] == "composer:a1", "still in the composer")
    lua("vim.cmd.startinsert({ bang = true })")
    iso.keys("C-h")
    check(soon(in_list_on("gamma")), "after a hot reload, <C-h> still lands on the row left (gamma)", where())
    iso.keys("C-l")
    check(soon(lambda: where()["kind"] == "composer:a1" and where()["mode"] == "i"), "and <C-l> still comes back typing", where())

    print("\n# the hint and the help")
    hint = lua("""
      local c = require('isovim.acp.chat').get('acme/app', 'a1')
      local ns = vim.api.nvim_get_namespaces().isovim_acp_composer
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(c.composer, ns, 0, -1, { details = true })) do
        for _, vl in ipairs(m[4].virt_lines or {}) do for _, chunk in ipairs(vl) do out[#out + 1] = chunk[1] end end
      end
      return table.concat(out, ' ')
    """)
    check("<C-h> the sidebar" in hint, "the composer's hint names <C-h>", hint)
    iso.keys("C-h")
    iso.wait(lambda: where()["kind"] == "list", "the list")
    iso.keys("?")
    help_lines = iso.wait(lambda: lua("""
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
        if (lines[1] or ''):match('^# Sidebar') then return lines end
      end
    """), "the help")
    at = next((i for i, line in enumerate(help_lines) if line.startswith("# Input box")), None)
    composer_keys = help_lines[at:at + 20] if at is not None else []
    check(at is not None and any(line.strip().startswith("<C-h>") and "sidebar" in line for line in composer_keys),
          "? lists <C-h> under the composer's keys", help_lines)
    iso.screenshot("help")
    iso.keys("q")
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
