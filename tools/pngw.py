"""pngw.py — tiny dependency-free PNG writer (stdlib zlib only).

write_png(path, width, height, rows, palette=None)
  rows: list of bytes/bytearray, one per scanline.
    - with palette: 1 byte per pixel (palette index), palette = [(r,g,b), ...]
    - without: 3 bytes per pixel (RGB)
"""
import struct
import zlib


def _chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def write_png(path, width, height, rows, palette=None):
    if palette is not None:
        color_type, bpp = 3, 1
    else:
        color_type, bpp = 2, 3
    raw = bytearray()
    for r in rows:
        assert len(r) == width * bpp, (len(r), width * bpp)
        raw.append(0)          # filter type: none
        raw += r
    png = b"\x89PNG\r\n\x1a\n"
    png += _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0))
    if palette is not None:
        png += _chunk(b"PLTE", b"".join(bytes(c) for c in palette))
    png += _chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += _chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


class Canvas:
    """Indexed-colour canvas with a few drawing helpers."""

    def __init__(self, width, height, fill=0):
        self.w, self.h = width, height
        self.px = [bytearray([fill]) * width for _ in range(height)]

    def set(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y][x] = c

    def rect(self, x, y, w, h, c):
        for yy in range(max(0, y), min(self.h, y + h)):
            row = self.px[yy]
            for xx in range(max(0, x), min(self.w, x + w)):
                row[xx] = c

    def hline(self, x, y, w, c):
        self.rect(x, y, w, 1, c)

    def vline(self, x, y, h, c):
        self.rect(x, y, 1, h, c)

    def frame(self, x, y, w, h, c):
        self.hline(x, y, w, c)
        self.hline(x, y + h - 1, w, c)
        self.vline(x, y, h, c)
        self.vline(x + w - 1, y, h, c)

    def save(self, path, palette):
        write_png(path, self.w, self.h, self.px, palette)


# 3x5 digits for labels
_DIGITS = {
    "0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
    "2": ["111", "001", "111", "100", "111"], "3": ["111", "001", "111", "001", "111"],
    "4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "111", "001", "111"],
    "6": ["111", "100", "111", "101", "111"], "7": ["111", "001", "001", "001", "001"],
    "8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "111"],
    "-": ["000", "000", "111", "000", "000"], " ": ["000", "000", "000", "000", "000"],
}


def text(canvas, x, y, s, c, scale=1):
    for ch in str(s):
        g = _DIGITS.get(ch, _DIGITS[" "])
        for j, row in enumerate(g):
            for i, bit in enumerate(row):
                if bit == "1":
                    canvas.rect(x + i * scale, y + j * scale, scale, scale, c)
        x += 4 * scale
