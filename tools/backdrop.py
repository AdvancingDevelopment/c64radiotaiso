#!/usr/bin/env python3
"""backdrop.py — sunrise backdrop for the PLAY screen (rows 4-20).

Generates src/gen_backdrop.asm (data segment):
  BD_TILE_COUNT          number of generated tiles (<= 32, codes $50+i)
  bd_tiles               8 bytes per tile (copied to CHARSET+$280 at run time)
  bd_tile_col            colour per tile (sun edge 8, ray dots 11)
  bd_sun                 8x4 char codes for the disc rect (cols 16-23, rows 17-20)
  bd_ray_lo/hi[13]       -> !byte n, (row, col, code) x n   (rows are screen rows)
and build/backdrop.png (preview, one ray lit).

Design: a hinomaru half-disc (radius 28 px, orange 8) centred on the horizon
at x=160 (between cols 19 and 20) behind the figure's feet, 13 dotted rays
(dark grey 11) fanning from 135 to 45 degrees (ray 0 = leftmost) up to row 4. Dotted rays keep the
tile count tiny (one tile per dot phase) so the whole backdrop fits in 32 tiles,
and they stay dim behind the white figure. Cells reserved for the count block
(cols 0-7, rows 8-17) and the set/pips block (cols 31-39, rows 11-14) never
receive ray dots. Python 3 stdlib only.
"""
import math, os, struct, sys, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "src", "gen_backdrop.asm")
PNG = os.path.join(ROOT, "build", "backdrop.png")

ROW0, ROWS = 4, 17               # rows 4..20
CX, CY, RADIUS = 160, 168, 28    # sun centre (px, bottom of row 20) and radius
RAY_R0 = RADIUS + 10             # rays start this far from the centre
NRAYS = 13
ANG0, ANG1 = 135.0, 45.0         # degrees from the +x axis; ray 0 = leftmost
DOT_ROWS = (1, 5)                # dot rows inside a cell (2 px tall each)
QX = 4                           # horizontal dot quantisation (px): 4 keeps the tile count small
MAX_TILES = 32
TILE_BASE = 0x50
BLOCK = 0x40                     # UI tile: full block (charset.asm)
FLOOR = 0x46                     # UI tile: horizon line
RESERVED = [(0, 7, 8, 17), (31, 39, 11, 14)]   # (col0, col1, row0, row1) inclusive
COL_SUN, COL_RAY, COL_LIT, COL_BG, COL_FLOOR = 8, 11, 7, 6, 11
C64 = {6: (53, 40, 121), 8: (111, 61, 0), 11: (68, 68, 68), 7: (191, 206, 114),
       1: (255, 255, 255), 14: (108, 94, 181), 10: (154, 103, 89)}


def reserved(col, row):
    return any(c0 <= col <= c1 and r0 <= row <= r1 for (c0, c1, r0, r1) in RESERVED)


def write_png(path, width, height, pixels):
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for (r, g, b) in row:
            raw += bytes((r, g, b))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def main():
    global DOT_ROWS, QX, RADIUS, PNG
    args = sys.argv[1:]
    for a in args:                       # experiments: --dots=1,5 --qx=2 --radius=28 --png=path
        k, _, v = a.partition("=")
        if k == "--dots":
            DOT_ROWS = tuple(int(x) for x in v.split(","))
        elif k == "--qx":
            QX = int(v)
        elif k == "--radius":
            RADIUS = int(v)
        elif k == "--png":
            PNG = v
    tiles = []            # list of 8-byte tuples
    tile_col = []
    tile_index = {}

    def tile(bits, col):
        key = tuple(bits)
        if key not in tile_index:
            tile_index[key] = len(tiles)
            tiles.append(key)
            tile_col.append(col)
        return tile_index[key]

    # --- sun disc: rasterise the filled half-disc into the 8x4 rect ---
    sun = {}              # (row, col) -> char code
    sun_pixels = set()
    for row in range(17, 21):
        for col in range(16, 24):
            bits = []
            for yy in range(8):
                y = row * 8 + yy + 0.5
                b = 0
                for xx in range(8):
                    x = col * 8 + xx + 0.5
                    if (x - CX) ** 2 + (y - CY) ** 2 < RADIUS ** 2:
                        b |= 0x80 >> xx
                        sun_pixels.add((col * 8 + xx, row * 8 + yy))
                bits.append(b)
            if all(b == 0xFF for b in bits):
                sun[(row, col)] = BLOCK
            elif any(bits):
                sun[(row, col)] = TILE_BASE + tile(bits, COL_SUN)
            else:
                sun[(row, col)] = 0x20
    n_sun_tiles = len(tiles)

    # --- rays: dots at DOT_ROWS of each cell row, x quantised to QX ---
    rays = []             # per ray: {(row, col): [dot x offsets per dot row]}
    for i in range(NRAYS):
        ang = math.radians(ANG0 + (ANG1 - ANG0) * i / (NRAYS - 1))
        dx, dy = math.cos(ang), -math.sin(ang)
        cells = {}
        for row in range(ROW0, 17):
            for di, dr in enumerate(DOT_ROWS):
                y = row * 8 + dr + 1.0            # centre of the 2-px dot
                t = (y - CY) / dy                 # distance along the ray
                if t < RAY_R0:
                    continue
                x = CX + t * dx
                if x < 1 or x > 318:
                    continue
                col = int(x // 8)
                if reserved(col, row):
                    continue
                off = int(round((x - col * 8 - 1) / QX)) * QX
                off = max(0, min(6, off))
                cells.setdefault((row, col), [None] * len(DOT_ROWS))[di] = off
        rays.append(cells)
    ray_lists = []
    for cells in rays:
        lst = []
        for (row, col) in sorted(cells):
            bits = [0] * 8
            for di, dr in enumerate(DOT_ROWS):
                off = cells[(row, col)][di]
                if off is None:
                    continue
                m = 0xC0 >> off
                bits[dr] |= m
                bits[dr + 1] |= m
            code = TILE_BASE + tile(bits, COL_RAY)
            lst.append((row, col, code))
        ray_lists.append(lst)
    if len(tiles) > MAX_TILES:
        sys.stderr.write(f"backdrop.py: {len(tiles)} tiles ({n_sun_tiles} sun) (max {MAX_TILES})\n")
        sys.exit(1)

    # --- emit ---
    L = []
    w = L.append
    w("; gen_backdrop.asm — generated by tools/backdrop.py. DO NOT EDIT.")
    w(f"; {len(tiles)} tiles ({n_sun_tiles} sun edge + {len(tiles)-n_sun_tiles} ray dot), "
      f"{sum(len(l) for l in ray_lists)} ray cells")
    w(f"BD_TILE_COUNT = {len(tiles)}")
    w("bd_tiles:")
    for i, t in enumerate(tiles):
        w(f"!byte {','.join('$%02x' % b for b in t)}  ; ${TILE_BASE+i:02x}")
    w("bd_tile_col: !byte " + ",".join(str(c) for c in tile_col))
    w("bd_sun:                        ; cols 16-23 x rows 17-20, char codes")
    for row in range(17, 21):
        w("!byte " + ",".join("$%02x" % sun[(row, col)] for col in range(16, 24)))
    for i, lst in enumerate(ray_lists):
        w(f"bd_ray_{i}: !byte {len(lst)}" +
          "".join(f",{r},{c},${code:02x}" for (r, c, code) in lst))
    w("bd_ray_lo: !byte " + ",".join(f"<bd_ray_{i}" for i in range(NRAYS)))
    w("bd_ray_hi: !byte " + ",".join(f">bd_ray_{i}" for i in range(NRAYS)))
    w("gen_backdrop_end:")
    src = "\n".join(L) + "\n"
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(src)

    # --- preview: rows 4-20, ray 3 lit, reserved rects outlined ---
    W, H = 320, ROWS * 8
    px = [[C64[COL_BG]] * W for _ in range(H)]

    def blit(row, col, bits, colour):
        for yy in range(8):
            for xx in range(8):
                if bits[yy] & (0x80 >> xx):
                    px[(row - ROW0) * 8 + yy][col * 8 + xx] = C64[colour]
    for (row, col), code in sun.items():
        if code == BLOCK:
            blit(row, col, [0xFF] * 8, COL_SUN)
        elif code != 0x20:
            blit(row, col, tiles[code - TILE_BASE], COL_SUN)
    for col in list(range(0, 16)) + list(range(24, 40)):
        blit(20, col, [0, 0, 0, 0, 0, 0, 0xFF, 0xFF], COL_FLOOR)
    for i, lst in enumerate(ray_lists):
        for (row, col, code) in lst:
            blit(row, col, tiles[code - TILE_BASE], COL_LIT if i == 3 else COL_RAY)
    for (c0, c1, r0, r1) in RESERVED:
        for x in range(c0 * 8, c1 * 8 + 8):
            for y in ((r0 - ROW0) * 8, (r1 - ROW0) * 8 + 7):
                if 0 <= y < H:
                    px[y][x] = C64[14]
    write_png(PNG, W, H, px)
    size = len(tiles) * 9 + 32 + sum(1 + 3 * len(l) for l in ray_lists) + 26
    print(f"tiles: {len(tiles)} ({n_sun_tiles} sun, {len(tiles)-n_sun_tiles} ray); "
          f"ray cells: {[len(l) for l in ray_lists]}; data ~{size} B -> {OUT}; preview {PNG}")


if __name__ == "__main__":
    main()
