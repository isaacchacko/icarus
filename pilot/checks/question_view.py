"""Question surfaces open as a buffer of their own in the main area (isovim.surface_view), not a
picker: <CR> on a question in the Inbox opens it, no float anywhere, read-only, wrapped, no number or
sign column, who asked and the question above the options. A single answer by its number and by j
and <CR> on it (j skipping descriptions); a multi question's toggles (a number, <Space>, a number
again to untick) and Submit; your own words through the input box under a question that takes them;
an agent's permission (asks to run) with its asker in the chip. Each answer reaches the blocking
iso router surface question caller as iso answer's would, and the buffer then shows it. A question
answered elsewhere (iso answer) while its buffer is open redraws as answered, its input box gone;
q closes the buffer.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/question_view.py"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from iso import REPO, Iso  # noqa: E402

BIN = str(REPO / "bin" / "iso")
SHOT = os.environ.get("QUESTION_VIEW_SHOT")
fails = []


def check(ok, what, detail=""):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail}"))
    if not ok:
        fails.append(what)


iso = Iso("question_view", cols=150, rows=44, agent_delay=0.3)
root_iso = iso.tmp / "work" / "root" / "iso"
root_iso.mkdir(parents=True)


def lua(code, *args):
    return iso.lua(code, *args)


class Asker:
    """A blocking iso router surface question in the root pseudo-repo, in the background."""

    def __init__(self, spec):
        self.proc = subprocess.Popen([BIN, "router", "surface", "question", json.dumps(spec), "--repo", "root"],
                                     env=iso.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def finish(self, timeout=15):
        out, err = self.proc.communicate(timeout=timeout)
        return self.proc.returncode, out.strip(), err


def sidebar_lines():
    return lua("return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(...), 0, -1, false)", iso.sidebar_win())


def open_from_inbox(title):
    """Enter on the question's row in the host Inbox, which lists the root's surfaces."""
    i = iso.wait(lambda: next((i for i, line in enumerate(sidebar_lines()) if title in line), None), f"the row {title!r}", 20)
    iso.focus_sidebar()
    lua("vim.cmd.stopinsert()")
    iso.keys("Escape")
    lua("vim.api.nvim_win_set_cursor(0, {..., 0})", i + 1)
    iso.keys("Enter")
    return iso.wait(view, "the question's buffer")


def view():
    """The current window's question buffer: its lines and how it's shown, or None."""
    return lua("""
      local buf = vim.api.nvim_get_current_buf()
      if vim.bo[buf].filetype ~= 'isovim_question' then return nil end
      local win = vim.api.nvim_get_current_win()
      local floats = {}
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local b = vim.api.nvim_win_get_buf(w)
        if vim.api.nvim_win_get_config(w).relative ~= '' and vim.bo[b].filetype ~= 'snacks_notif' then
          floats[#floats + 1] = vim.bo[b].filetype
        end
      end
      local input = vim.fn.bufnr(vim.api.nvim_buf_get_name(buf):gsub('^isovim%-question', 'isovim-surface') .. '/input')
      return { lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false), floats = floats,
        float = vim.api.nvim_win_get_config(win).relative ~= '', width = vim.api.nvim_win_get_width(win),
        number = vim.wo[win].number, signcolumn = vim.wo[win].signcolumn, wrap = vim.wo[win].wrap,
        modifiable = vim.bo[buf].modifiable, cursor = vim.api.nvim_win_get_cursor(win)[1],
        input = input ~= -1 and vim.fn.bufwinid(input) ~= -1, name = vim.api.nvim_buf_get_name(buf) }
    """)


def question_lines(name):
    return lua("local b = vim.fn.bufnr('isovim-question://root/' .. ...) return b ~= -1 and vim.api.nvim_buf_get_lines(b, 0, -1, false) or {}", name)


def has(lines, text):
    return any(text in line for line in lines)


try:
    iso.start()

    print("# a single answer by its number")
    asker = Asker({"question": "Ship it?", "options": [{"label": "yes"}, {"label": "no", "description": "not yet"}]})
    v = open_from_inbox("Ship it?")
    check(not v["float"] and v["floats"] == [] and v["width"] > 60, "Enter on the Inbox's question opens a buffer in the main area, no float", v)
    check(not v["number"] and v["signcolumn"] == "no" and v["wrap"] and not v["modifiable"],
          "read-only, wrapped, no number or sign column", v)
    lines = v["lines"]
    check(has(lines, "? the host root asks") and has(lines, "root/ship-it") and has(lines, "Ship it?")
          and has(lines, "1. yes") and has(lines, "2. no") and has(lines, "not yet") and has(lines, "<CR> or its number picks"),
          "who asked, the question, its numbered options and their descriptions", lines)
    check(lines[v["cursor"] - 1].strip() == "1. yes", "the cursor starts on the first option", (v["cursor"], lines))
    iso.keys("2")
    rc, out, err = asker.finish()
    check(rc == 0 and out == "no", "its number answers it, and the waiting caller gets the answer", (rc, out, err))
    lines = iso.wait(lambda: (v := view()) and has(v["lines"], "Answered by you") and v["lines"], "the answer in the buffer")
    check(has(lines, "Answered by you:") and lines[lines.index(next(l for l in lines if "Answered by" in l)) + 1].strip() == "no"
          and not has(lines, "1. yes"), "then the buffer shows the answer", lines)
    iso.wait(lambda: not (root_iso / "ship-it.surface").exists(), "the question collected")
    iso.wait(lambda: not any("Ship it?" in line for line in sidebar_lines()), "its row gone from the Inbox", 15)
    check(True, "and it leaves the Inbox")

    print("# a single answer by <CR> on it")
    asker = Asker({"question": "Which region?", "options": [{"label": "us", "description": "Virginia"},
                                                            {"label": "eu", "description": "Frankfurt"}, {"label": "ap"}]})
    open_from_inbox("Which region?")
    iso.keys("j")
    v = view()
    check(v["lines"][v["cursor"] - 1].strip() == "2. eu", "j moves to the next option, past a description", v)
    iso.keys("Enter")
    rc, out, err = asker.finish()
    check(rc == 0 and out == "eu", "<CR> on an option answers it", (rc, out, err))

    print("# a multi question: toggles and Submit")
    asker = Asker({"question": "Which checks should run before the release goes out?", "multi": True, "options": [
        {"label": "unit", "description": "the fast ones, a minute"},
        {"label": "pilot", "description": "the full TUI pilot, one check at a time"},
        {"label": "lint"}, {"label": "real adapter", "description": "acp_real against Claude, costs tokens"}]})
    v = open_from_inbox("Which checks")
    check(has(v["lines"], "1. [ ] unit") and has(v["lines"], "Submit") and has(v["lines"], "s or Submit sends"),
          "check boxes per option, a Submit row", v["lines"])
    iso.keys("1")
    iso.keys("3")
    iso.keys("j")
    iso.keys("Space")
    lines = view()["lines"]
    check(has(lines, "1. [x] unit") and has(lines, "2. [x] pilot") and has(lines, "3. [x] lint") and has(lines, "4. [ ] real adapter"),
          "a number and <Space> tick", lines)
    iso.keys("1")
    check(has(view()["lines"], "1. [ ] unit"), "its number again unticks it", view()["lines"])
    lua("vim.cmd.redraw()")
    path = iso.screenshot("multi")
    if SHOT:
        Path(SHOT).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(path, SHOT)
    lua("vim.api.nvim_win_set_cursor(0, {vim.fn.search('^   Submit$', 'nw'), 0})")
    iso.keys("Enter")
    rc, out, err = asker.finish()
    check(rc == 0 and sorted(out.split("\n")) == ["lint", "pilot"],
          "<CR> on Submit sends what's ticked", (rc, out, err))

    print("# your own words through the input box")
    asker = Asker({"question": "What should the branch be called?", "other": True, "options": [{"label": "main"}]})
    v = open_from_inbox("What should the branch")
    check(v["input"] and has(v["lines"], "2. Type something below."), "a question taking your words has the input box under it", v)
    iso.keys("2")
    iso.wait(lambda: lua("return vim.bo.filetype") == "isovim_surface_input" and iso.mode() == "i", "the input box, in insert mode")
    iso.type("release/v1")
    iso.keys("Enter")
    rc, out, err = asker.finish()
    check(rc == 0 and out == "release/v1", "<CR> in the input box sends your words as the other answer", (rc, out, err))
    v = iso.wait(lambda: (v := view()) and has(v["lines"], "Answered by you") and v, "the answer shown")
    check(not v["input"] and has(v["lines"], "release/v1"), "then the input box goes and the buffer shows the words", v)

    print("# an agent's permission")
    asker = Asker({"question": "builder (root/a4) asks to run: rm -rf build/", "options": [
        {"label": "Allow", "description": "this once"}, {"label": "Deny"}]})
    v = open_from_inbox("asks to run")
    check(has(v["lines"], "? builder (root/a4) asks to run") and any(l.strip() == "rm -rf build/" for l in v["lines"]),
          "the chip names the agent and what it asks", v["lines"])
    iso.keys("Enter")
    rc, out, err = asker.finish()
    check(rc == 0 and out == "Allow", "<CR> on Allow allows it", (rc, out, err))

    print("# answered elsewhere")
    asker = Asker({"question": "Merge now?", "other": True, "options": [{"label": "yes"}, {"label": "later"}]})
    v = open_from_inbox("Merge now?")
    check(v["input"], "its input box is open", v)
    r = subprocess.run([BIN, "answer", "root/merge-now", "later"], env=iso.env, capture_output=True, text=True)
    rc, out, err = asker.finish()
    check(r.returncode == 0 and rc == 0 and out == "later", "iso answer answers it and the caller gets it", (r.stderr, out, err))
    lines = iso.wait(lambda: has(question_lines("merge-now"), "Answered by") and question_lines("merge-now"), "the buffer to redraw", 15)
    check(has(lines, "Answered by you:") and has(lines, "later") and not has(lines, "1. yes"),
          "the open buffer redraws to show the answer from elsewhere", lines)
    check(not view()["input"], "and its input box goes", view())
    iso.keys("q")
    iso.wait(lambda: lua("return vim.fn.bufwinid(vim.fn.bufnr('isovim-question://root/merge-now'))") == -1, "q to close it")
    check(iso.sidebar_win() is not None, "q closes the buffer, the sidebar stays")
finally:
    iso.stop()

if fails:
    print(f"\n{len(fails)} failed:\n  " + "\n  ".join(fails))
    sys.exit(1)
print("\nall ok")
