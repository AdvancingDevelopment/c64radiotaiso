#!/usr/bin/env python3
"""thumbnail.py — 1280x720 YouTube thumbnail from a VICE recording (stdlib + ffmpeg).

  python3 tools/thumbnail.py raw.mp4 out.png POSE_T [TITLE_T] [--line "TEXT:scale:colour" ...]

Left: the C64 picture around the coach (200x180 crop at 4x) from the frame at POSE_T.
Right: the title-screen logo (from the frame at TITLE_T, default 5 s) and text lines set
in the program's own 8x8 font (src/charset.asm), scale/colour per line
(colours: white, yellow, grey, red). Background = the recording's border colour.
"""
import os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pngw import write_png

W, H = 384, 272                      # VICE PAL recording
OUT_W, OUT_H = 1280, 720
COL = {"white": (255, 255, 255), "yellow": (238, 238, 119), "grey": (190, 190, 190),
       "red": (224, 128, 128), "black": (0, 0, 0)}

def frame(path, t):
    r = subprocess.run(["ffmpeg", "-loglevel", "error", "-ss", str(t), "-i", path, "-frames:v", "1",
                        "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True)
    assert len(r.stdout) == W * H * 3, "unexpected frame size %d" % len(r.stdout)
    return r.stdout

def font():
    """The text font of src/charset.asm: consecutive !byte lines in screen-code order
    ($01 = A ... $1a = Z, $20-$3f = ASCII punctuation and digits) up to the UI tiles."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    rows, a_index = [], None
    for line in open(os.path.join(root, "src", "charset.asm"), encoding="utf-8"):
        if "$40 block" in line:
            break
        m = re.match(r"!byte ((?:\$[0-9a-f]{2},){7}\$[0-9a-f]{2})(.*)$", line.strip())
        f = re.match(r"!fill\s+(\d+)(?:\s*\*\s*8)?\s*,\s*0", line.strip())
        if m:
            if a_index is None and re.search(r";\s*A\b", m.group(2)):
                a_index = len(rows)               # this row is screen code $01
            rows.append([int(v[1:], 16) for v in m.group(1).split(",")])
        elif f and a_index is not None:           # blank glyphs: !fill 8,0 / !fill n*8,0
            n = int(f.group(1)) // (1 if "*" in line else 8)
            rows.extend([[0] * 8] * n)
    assert a_index is not None, "glyph A not found in charset.asm"
    glyphs = {" ": [0] * 8}
    for i, g in enumerate(rows):
        code = 1 + i - a_index
        if 1 <= code <= 0x1a:
            glyphs[chr(0x40 + code)] = g          # A-Z
        elif 0x20 <= code <= 0x3f:
            glyphs[chr(code)] = g                 # space ! " # ... 0-9 : ; < = > ?
    return glyphs

class Canvas:
    def __init__(self, w, h, bg):
        self.w, self.h = w, h
        self.px = bytearray(bytes(bg) * (w * h))
    def put(self, x, y, rgb):
        if 0 <= x < self.w and 0 <= y < self.h:
            i = (y * self.w + x) * 3
            self.px[i:i + 3] = bytes(rgb)
    def blit(self, src, sx, sy, sw, sh, dx, dy, scale, key=None):
        for y in range(sh):
            for x in range(sw):
                i = ((sy + y) * W + sx + x) * 3
                rgb = src[i:i + 3]
                if key is not None and rgb == key:
                    continue
                for yy in range(scale):
                    for xx in range(scale):
                        self.put(dx + x * scale + xx, dy + y * scale + yy, rgb)
    def text(self, glyphs, x, y, s, scale, rgb, shadow=None):
        for n, ch in enumerate(s.upper()):
            g = glyphs.get(ch)
            if g is None:
                continue
            for row in range(8):
                for col in range(8):
                    if g[row] & (0x80 >> col):
                        px, py = x + (n * 8 + col) * scale, y + row * scale
                        for yy in range(scale):
                            for xx in range(scale):
                                if shadow is not None:
                                    self.put(px + xx + scale, py + yy + scale, shadow)
                                self.put(px + xx, py + yy, rgb)
    def rows(self):
        return [bytes(self.px[y * self.w * 3:(y + 1) * self.w * 3]) for y in range(self.h)]

def main():
    args = sys.argv[1:]
    lines = []
    while "--line" in args:
        i = args.index("--line"); lines.append(args[i + 1]); del args[i:i + 2]
    src, out, pose_t = args[0], args[1], float(args[2])
    title_t = float(args[3]) if len(args) > 3 else 5.0
    pose, title = frame(src, pose_t), frame(src, title_t)
    bg = tuple(pose[(2 * W + 2) * 3:(2 * W + 2) * 3 + 3])          # border colour
    c = Canvas(OUT_W, OUT_H, bg)
    c.blit(pose, 88, 52, 200, 180, 0, 0, 4)                         # rows 2-24: JP name, coach, sun, dots
    if not lines:
        lines = ["RADIO TAISO:4:yellow", "ON THE:2:grey", "COMMODORE 64:4:white",
                 " :2:white", "NO.1 - FULL ROUTINE:2:white", "ORIGINAL SID MUSIC:2:yellow",
                 " :2:white", "PAL & NTSC - FREE:2:grey"]
    glyphs = font()
    gaps = {4: 14, 3: 10, 2: 10, 1: 6}
    total = sum(8 * int(l.rsplit(":", 2)[1]) + gaps[int(l.rsplit(":", 2)[1])] for l in lines)
    y = (OUT_H - (88 + 40 + total)) // 2                            # logo + gap + text, centred
    c.blit(title, 84, 2, 216, 44, 824, y, 2)                        # logo from the top border
    y += 88 + 40
    for spec in lines:
        text, scale, colour = spec.rsplit(":", 2)
        scale = int(scale)
        width = len(text) * 8 * scale
        x = 800 + (480 - width) // 2
        c.text(glyphs, x, y, text, scale, COL[colour], shadow=COL["black"] if scale >= 2 else None)
        y += 8 * scale + gaps[scale]
    write_png(out, OUT_W, OUT_H, c.rows())
    print(out, "%dx%d" % (OUT_W, OUT_H), "font glyphs:", "".join(sorted(glyphs)))

if __name__ == "__main__":
    main()
