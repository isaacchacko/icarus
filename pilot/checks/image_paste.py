"""Images in what you send an agent, with pilot/fake-acp-agent as the adapter and a stand-in pngpaste
for the clipboard: <C-v> in the chat's composer pastes the clipboard's PNG as an [Image #1] chip (and
with no image there is vim's own <C-v>); a quoted or backslash-escaped path pasted into the box (as a
terminal types a dropped file) is a chip too, its file copied under iso/images/; a path typed in is
attached once sent; deleting a chip drops its image. Sent, the adapter gets a text block and an image
block with the file's bytes and mime type, and the chat draws the prompt with its chip. While a turn
runs the prompt is queued with its images, kept in aN.queue.json, and they survive the queue buffer's
edit and :w (a chip deleted there drops its image); they go once the turn ends. A surface's input
box takes images the same way and sends them with iso send --image into the router's queue. An
adapter that takes no images (promptCapabilities.image false) gets the files named in the text.
Run from pilot/: uv run --with pynvim --with pillow --with fonttools python checks/image_paste.py"""

import base64
import io
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image

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


def png(color, size=(8, 6)):
    out = io.BytesIO()
    Image.new("RGB", size, color).save(out, "PNG")
    return out.getvalue()


iso = Iso("image_paste", agent_delay=0.3)
iso.env["ISOVIM_SELF"] = "pilothost"
# The clipboard: a stand-in pngpaste that writes what's in $FAKE_CLIPBOARD, failing when it's gone
# (as pngpaste does with no image on the clipboard).
stubs = iso.tmp / "stubs"
stubs.mkdir()
(stubs / "pngpaste").write_text('#!/bin/sh\n[ -s "$FAKE_CLIPBOARD" ] || { echo "No PNG data found on the clipboard" >&2; exit 1; }\n'
                                'cp "$FAKE_CLIPBOARD" "$1"\n')
(stubs / "pngpaste").chmod(0o755)
clipboard = iso.tmp / "clipboard.png"
iso.env["FAKE_CLIPBOARD"] = str(clipboard)
iso.env["PATH"] = f"{stubs}:{iso.env['PATH']}"


def run(*args, timeout=60):
    r = subprocess.run([BIN, *args], env=iso.env, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr


IMAGES = None  # iso/images of acme/app


def journal(agent):
    path = iso.tmp / "work" / "acme" / "app" / "iso" / "journal" / f"{agent}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def queue_file(agent):
    path = iso.tmp / "work" / "acme" / "app" / "iso" / "journal" / f"{agent}.queue.json"
    return json.loads(path.read_text()) if path.exists() else []


def state(agent):
    path = iso.tmp / "home" / "run" / "acme+app" / f"{agent}.state"
    return path.read_text().strip() if path.exists() else None


def prompts_sent():
    """Every session/prompt the adapter got: (text, [(mimeType, bytes)])."""
    path = Path(iso.env["FAKE_ACP_LOG"])
    sent = []
    for line in path.read_text().splitlines() if path.exists() else []:
        frame = json.loads(line).get("frame") or {}
        if frame.get("method") == "session/prompt":
            blocks = frame["params"]["prompt"]
            sent.append(("".join(b.get("text", "") for b in blocks if b["type"] == "text"),
                         [(b["mimeType"], base64.b64decode(b["data"])) for b in blocks if b["type"] == "image"]))
    return sent


def sent_with(fragment):
    return next((p for p in prompts_sent() if fragment in p[0]), None)


def chat(agent):
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', ...)"
                   " return c and vim.api.nvim_buf_get_lines(c.buf, 0, -1, false) or vim.NIL", agent)


def composer(agent):
    return iso.lua("local c = require('isovim.acp.chat').get('acme/app', ...)"
                   " return c and vim.api.nvim_buf_get_lines(c.composer, 0, -1, false) or vim.NIL", agent)


def chips_drawn(buf_expr):
    """The [Image #n] spans highlighted as chips in a buffer."""
    return iso.lua(f"""
      local buf = {buf_expr}
      local found = {{}}
      for _, ns in pairs(vim.api.nvim_get_namespaces()) do
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {{ details = true }})) do
          if m[4].hl_group == 'IsovimAcpImage' then
            found[#found + 1] = vim.api.nvim_buf_get_text(buf, m[2], m[3], m[4].end_row or m[2], m[4].end_col, {{}})[1]
          end
        end
      end
      return found
    """)


def paste(text):
    """Pastes text into the TUI as a terminal does a drop or Cmd-V: a bracketed paste."""
    iso._tmux_ui("set-buffer", "-b", "drop", text)
    iso._tmux_ui("paste-buffer", "-p", "-d", "-b", "drop", "-t", "=0:")


def copies():
    return sorted(IMAGES.glob("*")) if IMAGES.exists() else []


try:
    iso.start()
    app = iso.tmp / "src" / "app"
    app.mkdir(parents=True)
    git("init", "-q", str(app))
    git("-C", str(app), "remote", "add", "origin", "git@github.com:Acme/app.git")
    rc, a0, err = run("spawn", "--acp", "--repo", str(app), "--role", "router", "--name", "router", "hello")
    check(rc == 0 and a0 == "acme/app/a0", "an ACP router", (rc, a0, err))
    IMAGES = iso.tmp / "work" / "acme" / "app" / "iso" / "images"
    iso.wait(lambda: any(e["kind"] == "turn" and e["state"] == "end" for e in journal("a0")), "its first turn")
    iso.cli("open", a0)
    iso.wait(lambda: composer("a0") == [""] and iso.mode() == "i", "the composer, in insert mode")

    print("# <C-v> pastes the clipboard's image")
    red = png("red")
    clipboard.write_bytes(red)
    iso.type("what is this ")
    iso.keys("C-v")
    iso.wait(lambda: composer("a0") == ["what is this [Image #1] "], "the chip in the composer")
    check(True, "<C-v> puts an [Image #1] chip in the composer")
    check(chips_drawn("require('isovim.acp.chat').get('acme/app', 'a0').composer") == ["[Image #1]"],
          "drawn as a chip", chips_drawn("require('isovim.acp.chat').get('acme/app', 'a0').composer"))
    saved = copies()
    check(len(saved) == 1 and saved[0].suffix == ".png" and saved[0].read_bytes() == red,
          "the clipboard's PNG is saved under the repo's iso/images/", saved)
    iso.screenshot("composer-chip")
    iso.keys("Enter")
    got = iso.wait(lambda: sent_with("what is this"), "the prompt at the adapter")
    check(got[0] == "what is this [Image #1]" and got[1] == [("image/png", red)],
          "the adapter gets a text block and an image block with the PNG's bytes and mime type", got)
    iso.wait(lambda: "❯ what is this [Image #1]" in chat("a0"), "the chat to draw the prompt")
    check(True, "the chat draws the prompt with its chip")
    prompt = next(e for e in journal("a0") if e["kind"] == "prompt" and "what is this" in e["text"])
    check(prompt.get("images") == [{"path": str(saved[0]), "mimeType": "image/png"}], "the journal keeps the image's path", prompt)
    check(any("[Image #1]" in t for t in chips_drawn("require('isovim.acp.chat').get('acme/app', 'a0').buf")),
          "the chat's prompt draws [Image #1] as a chip")
    check(composer("a0") == [""], "the composer is empty again", composer("a0"))

    print("\n# <C-v> with no image on the clipboard is vim's own")
    clipboard.unlink()
    iso.type("a")
    iso.keys("C-v")
    iso.keys("Tab")
    iso.wait(lambda: composer("a0") == ["a\t"], "a literal tab")
    check(True, "<C-v> then <Tab> inserts a literal tab")
    check(len(copies()) == 1, "and saves nothing", copies())
    iso.lua("vim.api.nvim_buf_set_lines(require('isovim.acp.chat').get('acme/app', 'a0').composer, 0, -1, false, { '' })")

    print("\n# a dropped file's path")
    shots = iso.tmp / "Screen Shots"
    shots.mkdir()
    blue, green = png("blue", (5, 5)), png("green", (3, 9))
    (shots / "shot one.png").write_bytes(blue)
    (iso.tmp / "plain.png").write_bytes(green)
    iso.type("compare ")
    paste(f"'{shots / 'shot one.png'}'")
    iso.wait(lambda: composer("a0") == ["compare [Image #1] "], "the quoted path as a chip")
    check(True, "a quoted path pasted in is an [Image #1] chip")
    paste(str(shots / "shot one.png").replace(" ", "\\ "))
    iso.wait(lambda: composer("a0") == ["compare [Image #1] [Image #2] "], "the escaped path as a chip")
    check(True, "a backslash-escaped one is [Image #2]")
    check(len(copies()) == 3 and all(p.read_bytes() == blue for p in copies()[1:]), "each copied under iso/images/", copies())
    paste("not a path, just text")
    iso.wait(lambda: composer("a0") == ["compare [Image #1] [Image #2] not a path, just text"], "plain text pasted as text")
    check(True, "a paste that isn't image paths is text")
    # Deleting #1's chip drops it; the one left goes as #1.
    iso.lua("local c = require('isovim.acp.chat').get('acme/app', 'a0')"
            " vim.api.nvim_buf_set_lines(c.composer, 0, -1, false, { 'compare [Image #2] with ' .. ... })", str(iso.tmp / "plain.png"))
    iso.keys("Enter")
    got = iso.wait(lambda: sent_with("compare"), "the prompt at the adapter")
    check(got == ("compare [Image #1] with [Image #2]", [("image/png", blue), ("image/png", green)]),
          "a deleted chip drops its image, a typed path is attached, and they're numbered as sent", got)

    print("\n# queued while a turn runs, through the queue's edit and :w")
    run("send", a0, "slow 4")
    iso.wait(lambda: state("a0") == "working", "a0 working")
    clipboard.write_bytes(red)
    iso.lua("require('isovim.acp.chat').focus_composer('acme/app', 'a0')")
    iso.type("queued one ")
    iso.keys("C-v")
    iso.keys("Enter")
    iso.type("queued two ")
    iso.keys("C-v")
    iso.keys("Enter")
    iso.wait(lambda: len(queue_file("a0")) == 2, "two queued prompts on disk")
    q = queue_file("a0")
    check([i["text"] for i in q] == ["queued one [Image #1]", "queued two [Image #1]"] and all(len(i.get("images") or []) == 1 for i in q),
          "each queued with its image in aN.queue.json", q)
    check(not sent_with("queued one"), "not sent during the turn")
    iso.lua("require('isovim.acp.queue').focus('acme/app', 'a0')")
    iso.wait(lambda: iso.lua("return vim.bo.filetype") == "isovim_queue", "the queue buffer")
    lines = iso.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
    check(lines == ["#1 queued one [Image #1]", "#2 queued two [Image #1]"], "the queue buffer shows the chips", lines)
    iso.lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, { '#1 queued one, edited [Image #1]', '#2 queued two, no image' })")
    iso.lua("vim.cmd('write')")
    q = iso.wait(lambda: (lambda q: q if q and q[0]["text"].startswith("queued one, edited") else None)(queue_file("a0")),
                 "the queue rewritten")
    check(q[0]["text"] == "queued one, edited [Image #1]" and len(q[0].get("images") or []) == 1,
          "an edited queued prompt keeps its image through :w", q)
    check(q[1]["text"] == "queued two, no image" and not q[1].get("images"), "one whose chip was deleted there drops it", q)
    iso.lua("require('isovim.acp.chat').focus_composer('acme/app', 'a0')")
    got = iso.wait(lambda: sent_with("queued one, edited"), "the queued prompt sent after the turn", 20)
    check(got[1] == [("image/png", red)], "it goes with its image once the turn ends", got)
    got = iso.wait(lambda: sent_with("queued two, no image"), "the second queued prompt", 20)
    check(got[1] == [], "and the other without", got)
    iso.wait(lambda: state("a0") != "working", "the queue drained", 20)
    iso.screenshot("chat")

    print("\n# a surface's input box")
    iso_dir = iso.tmp / "work" / "acme" / "app" / "iso"
    (iso_dir / "notes.md").write_text("---\nname: Release notes\n---\n\nThe **plan** is set.\n")
    iso.wait(lambda: iso.lua("for _, e in ipairs(require('isovim.surfaces').list('acme/app')) do"
                             " if e.name == 'notes' then return true end end return false"), "the watcher to see the surface", 15)
    run("send", a0, "slow 6")
    iso.wait(lambda: state("a0") == "working", "the router working")
    yellow = png("yellow", (7, 7))
    clipboard.write_bytes(yellow)
    iso.lua("""
      local entry = vim.iter(require('isovim.surfaces').list('acme/app')):find(function(e) return e.name == 'notes' end)
      local view = require('isovim.surface_view').open(entry)
      vim.api.nvim_set_current_win(vim.fn.bufwinid(view.input))
      vim.cmd.startinsert()
    """)
    iso.wait(lambda: iso.lua("return vim.b.isovim_surface_input ~= nil") and iso.mode() == "i", "in the surface's input box")
    view_input = "require('isovim.surface_view').views['acme/app/notes'].input"
    iso.type("see ")
    iso.keys("C-v")
    # A path with a space, unquoted: the whole paste is one file.
    paste(str(shots / "shot one.png"))
    iso.wait(lambda: iso.lua(f"return vim.api.nvim_buf_get_lines({view_input}, 0, -1, false)") == ["see [Image #1] [Image #2] "],
             "two chips in the surface's input box")
    check(chips_drawn(view_input) == ["[Image #1]", "[Image #2]"], "the surface's input box draws both chips", chips_drawn(view_input))
    iso.screenshot("surface-chips")
    iso.keys("Enter")
    q = iso.wait(lambda: next((i for i in queue_file("a0") if "see [Image" in i["text"]), None), "queued at the router")
    check(q["text"] == "[on the acme/app surface notes] see [Image #1] [Image #2]" and len(q.get("images") or []) == 2,
          "iso send --image queues it with both images behind the router's turn", q)
    got = iso.wait(lambda: sent_with("surface notes] see"), "the surface's prompt at the adapter", 20)
    check(got[1] == [("image/png", yellow), ("image/png", blue)], "the adapter gets both image blocks", got)

    print("\n# an adapter that takes no images, and iso send --image")
    blocks = iso.lua("return require('isovim.acp.images').blocks('look [Image #1]', { { path = '/x/y.png', mimeType = 'image/png' } }, false)")
    check(blocks == [{"type": "text", "text": "look [Image #1]\n\n[Image #1]: /x/y.png"}], "the files are named in the text", blocks)
    rc, _, err = run("send", a0, "--image", str(shots / "shot one.png"), "from the cli")
    check(rc == 0, "iso send --image", err)
    got = iso.wait(lambda: sent_with("from the cli"), "the cli's prompt at the adapter", 20)
    check(got == ("from the cli [Image #1]", [("image/png", blue)]), "gets a chip and the image block", got)
    rc, _, err = run("send", a0, "--image", str(iso.tmp / "nope.txt"), "bad")
    check(rc != 0 and "not a png" in err, "a file that isn't an image is refused", (rc, err))
finally:
    iso.stop()

print("\nfailures:", len(fails))
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
