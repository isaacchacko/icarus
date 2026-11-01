"""Draws `tmux capture-pane -e` output (text plus SGR colors) to a PNG, cell by cell."""

import re
import unicodedata
from pathlib import Path

from fontTools.ttLib import TTCollection, TTFont
from PIL import Image, ImageDraw, ImageFont

SIZE = 14
MENLO = "/System/Library/Fonts/Menlo.ttc"
JETBRAINS = "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-{}.ttf"  # Linux; carries the Nerd Font symbols too
SYMBOLS = Path.home() / ".cache/isovim-test/nf351/SymbolsNerdFontMono-Regular.ttf"  # 3.5.1: has cod-claude
APPLE_SYMBOLS = "/System/Library/Fonts/Apple Symbols.ttf"
# Linux fallbacks for what JetBrains Mono lacks (⎿ ⏺ ⏸ ◐ and the like).
IOSEVKA = "/usr/share/fonts/TTF/IosevkaNerdFontMono-Regular.ttf"
FREEMONO = "/usr/share/fonts/gnu-free/FreeMono.otf"
FREESERIF = "/usr/share/fonts/gnu-free/FreeSerif.otf"

DEFAULT_FG = (192, 202, 245)
DEFAULT_BG = (26, 27, 38)
# A light terminal's defaults, for screens drawn with background=light.
LIGHT_FG = (52, 59, 88)
LIGHT_BG = (250, 250, 248)
BASE16 = [
    (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16), (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
    (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67), (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
]


def color256(n):
    if n < 16:
        return BASE16[n]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return (steps[n // 36], steps[n // 6 % 6], steps[n % 6])
    level = 8 + (n - 232) * 10
    return (level, level, level)


class Fonts:
    """Menlo (or JetBrains Mono on Linux) first, then Nerd Font symbols, then Apple Symbols: the first whose cmap has the glyph."""

    def __init__(self):
        if Path(MENLO).exists():
            menlo = TTCollection(MENLO)
            main = (ImageFont.truetype(MENLO, SIZE, index=0), ImageFont.truetype(MENLO, SIZE, index=1), menlo.fonts[0].getBestCmap())
        else:
            regular, bold = JETBRAINS.format("Regular"), JETBRAINS.format("Bold")
            main = (ImageFont.truetype(regular, SIZE), ImageFont.truetype(bold, SIZE), TTFont(regular).getBestCmap())
        self.chain = [main]
        for path in (SYMBOLS, APPLE_SYMBOLS, IOSEVKA, FREEMONO, FREESERIF):
            if Path(path).exists():
                font = ImageFont.truetype(str(path), SIZE)
                self.chain.append((font, font, TTFont(str(path), fontNumber=0).getBestCmap()))
        self.cell_w = round(self.chain[0][0].getlength("M"))
        ascent, descent = self.chain[0][0].getmetrics()
        self.cell_h = ascent + descent + 2

    def pick(self, char, bold):
        for regular, heavy, cmap in self.chain:
            if ord(char) in cmap:
                return heavy if bold else regular
        return self.chain[0][0]


SGR = re.compile(r"\x1b\[([0-9;:]*)m")
OTHER_ESCAPE = re.compile(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>]")


def parse(text, default_fg=DEFAULT_FG, default_bg=DEFAULT_BG):
    """Yields rows of (char, fg, bg, bold) cells; a dim cell's fg is halfway to the background."""
    text = OTHER_ESCAPE.sub("", text)
    fg, bg, bold, reverse, dim = None, None, False, False, False
    for line in text.split("\n"):
        row = []
        pos = 0
        for match in list(SGR.finditer(line)) + [None]:
            end = match.start() if match else len(line)
            for char in line[pos:end]:
                cell_fg, cell_bg = (bg, fg) if reverse else (fg, bg)
                if dim:
                    base, back = cell_fg or default_fg, cell_bg or default_bg
                    cell_fg = tuple((a + b) // 2 for a, b in zip(base, back))
                row.append((char, cell_fg, cell_bg, bold))
                if unicodedata.east_asian_width(char) in "WF":
                    row.append(("", cell_fg, cell_bg, bold))
            if not match:
                break
            pos = match.end()
            codes = [int(c) if c else 0 for c in re.split("[;:]", match.group(1) or "0")]
            i = 0
            while i < len(codes):
                code = codes[i]
                if code == 0:
                    fg, bg, bold, reverse, dim = None, None, False, False, False
                elif code == 1:
                    bold = True
                elif code == 2:
                    dim = True
                elif code == 22:
                    bold, dim = False, False
                elif code == 7:
                    reverse = True
                elif code == 27:
                    reverse = False
                elif 30 <= code <= 37:
                    fg = BASE16[code - 30]
                elif 90 <= code <= 97:
                    fg = BASE16[code - 90 + 8]
                elif 40 <= code <= 47:
                    bg = BASE16[code - 40]
                elif 100 <= code <= 107:
                    bg = BASE16[code - 100 + 8]
                elif code == 39:
                    fg = None
                elif code == 49:
                    bg = None
                elif code in (38, 48, 58) and i + 1 < len(codes):
                    if codes[i + 1] == 5 and i + 2 < len(codes):
                        value = color256(codes[i + 2])
                        i += 2
                    elif codes[i + 1] == 2 and i + 4 < len(codes):
                        value = tuple(codes[i + 2 : i + 5])
                        i += 4
                    else:
                        value = None
                    if code == 38:
                        fg = value
                    elif code == 48:
                        bg = value
                i += 1
        yield row


def render(ansi_text, out_path, cols, rows, light=False):
    """light: the terminal's own colors are a light theme's (dark text on white)."""
    fonts = Fonts()
    default_fg, default_bg = (LIGHT_FG, LIGHT_BG) if light else (DEFAULT_FG, DEFAULT_BG)
    image = Image.new("RGB", (cols * fonts.cell_w, rows * fonts.cell_h), default_bg)
    draw = ImageDraw.Draw(image)
    for y, row in enumerate(list(parse(ansi_text, default_fg, default_bg))[:rows]):
        for x, (char, fg, bg, bold) in enumerate(row[:cols]):
            left, top = x * fonts.cell_w, y * fonts.cell_h
            if bg:
                draw.rectangle([left, top, left + fonts.cell_w - 1, top + fonts.cell_h - 1], fill=bg)
            if char.strip():
                draw.text((left, top + 1), char, font=fonts.pick(char, bold), fill=fg or default_fg)
    image.save(out_path)
    return out_path
