"""Puts Claude Code's own screen and isovim's ACP chat side by side, one PNG per feature, in
docs/chat-compare/. The left side is a capture of the real claude TUI (in tmux, rendered by
screenshot.py); the right is a pilot screenshot from checks/acp_chat_real.py (the real adapter) or
checks/acp_chat_claude.py (the fake one, for what haiku doesn't do on demand), with isovim's
sidebar cropped off.
Run from pilot/: uv run --with pillow --with fonttools python chat_compare.py <claude shots dir>"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

import screenshot

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "docs" / "chat-compare"
SHOTS = HERE / "out"
# isovim's sidebar is 41 columns of the 150-column pilot screen.
SIDEBAR_COLS = 41

# feature: (claude's capture, isovim's screenshot, what to look at)
PAIRS = {
    "tools": ("12-bash-output", "acp_chat_real-tools",
              "Read, Edit (Update) with its diff, Bash with long output, the agent's text, the turn's summary"),
    "tools-expanded": ("13-transcript-tools", "acp_chat_real-tools",
                       "Claude's ctrl+o view: Read(path), Bash(cmd) with ⎿ output; isovim collapses to 3 lines + … +N lines"),
    "permission-edit": ("10-permission-edit", "acp_chat_real-permission-edit", "the Edit permission box"),
    "permission-bash": ("11-edit-diff-and-bash-permission", "acp_chat_real-permission-bash", "the Bash permission box"),
    "spinner": ("21-spinner2", "acp_chat_real-spinner", "the spinner line while a turn runs"),
    "question": ("30-ask", "acp_chat_real-question", "AskUserQuestion's numbered options"),
    "question-answered": ("31-asked", "acp_chat_real-answered", "the answer, as Claude puts it"),
    "light": ("41-light-done", "acp_chat_claude-light", "a light background"),
    "thinking-todos": (None, "acp_chat_claude-tools",
                       "thinking (collapsed), markdown, the todo list; Claude Code 2.1.310 on haiku showed neither"),
}


def font(size=16):
    for path in (screenshot.JETBRAINS.format("Bold"), "/System/Library/Fonts/Menlo.ttc"):
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def label(image, text, sub):
    head = 52
    out = Image.new("RGB", (image.width, image.height + head), (40, 40, 40))
    out.paste(image, (0, head))
    draw = ImageDraw.Draw(out)
    draw.text((10, 6), text, font=font(16), fill=(215, 119, 87))
    draw.text((10, 28), sub, font=font(12), fill=(170, 170, 170))
    return out


def main(claude_dir):
    OUT.mkdir(parents=True, exist_ok=True)
    cell_w = screenshot.Fonts().cell_w
    for feature, (left, right, what) in PAIRS.items():
        iso = Image.open(SHOTS / f"{right}.png").convert("RGB")
        iso = iso.crop((SIDEBAR_COLS * cell_w, 0, iso.width, iso.height))
        iso = label(iso, "isovim ACP chat", right + ".png")
        if left:
            ref = Image.open(Path(claude_dir) / f"{left}.png").convert("RGB")
            ref = label(ref, "Claude Code 2.1.310 (haiku)", left + ".png")
        else:
            ref = label(Image.new("RGB", (iso.width, iso.height - 52), (30, 30, 30)), "Claude Code 2.1.310 (haiku)",
                        "no capture: " + what.split("; ")[-1])
        height = max(ref.height, iso.height)
        sheet = Image.new("RGB", (ref.width + iso.width + 12, height + 30), (20, 20, 20))
        sheet.paste(ref, (0, 0))
        sheet.paste(iso, (ref.width + 12, 0))
        ImageDraw.Draw(sheet).text((10, height + 6), f"{feature}: {what}", font=font(13), fill=(220, 220, 220))
        path = OUT / f"{feature}.png"
        sheet.save(path, optimize=True)
        print(path)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else HERE / "out" / "ref" / "shots")
