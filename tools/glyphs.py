#!/usr/bin/env python3
"""glyphs.py — Japanese glyph + string tables for Radio Taiso 64.

Reads tools/text.json and the Shinonome 16 sources (tools/fonts/*.bit —
BDF-style files whose bitmap rows are written with '.' and '@'; the
kanji/kana file is JIS X 0208, ENCODING = row/col code, mapped to Unicode
via EUC-JP), collects every glyph used by the names, cues, titles and count
words, and writes src/gen_glyphs.asm (data segment):

  glyph_data   N x 32 bytes, page aligned, glyph 0 = blank.
               Cell order TL,TR,BL,BR (8 bytes each) = 4 consecutive
               charset codes; the scroller converts to sprite rows.
  latin_data   M x 16 bytes, 8x16 half-width Latin glyphs (index 0 = space)
               for the English scroller cues (two per sprite cell).
  mv_jp_lo/hi[30]      routine*15+slot -> !byte n, glyph idx...   (n <= 16)
  mv_name_lo/hi[30]    English name, !scr, $ff terminated        (<= 29)
  mv_cue_lo/hi[30]     Japanese scroller cue, !byte n, idx...     (n <= 16)
  mv_cue_en_lo/hi[30]  English scroller cue: !byte cells, (a,b,c)... (3 half
                       glyphs = 24 sprite px per cell, <= 38 chars)
  kana_lo/hi[8], romaji_lo/hi[8], title_jp_lo/hi[2]

Also writes build/glyphs.png (a review sheet). Python 3 stdlib only.
Usage: python3 tools/glyphs.py [--quiet]
"""
import json, os, struct, sys, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEXT = os.path.join(ROOT, "tools", "text.json")
KANJI = os.path.join(ROOT, "tools", "fonts", "font_src.bit")
LATIN = os.path.join(ROOT, "tools", "fonts", "latin1_src.bit")
OUT = os.path.join(ROOT, "src", "gen_glyphs.asm")
PNG = os.path.join(ROOT, "build", "glyphs.png")

MAX_JP = 16          # glyphs per Japanese name / cue
MAX_NAME = 29        # English name characters
MAX_CUE_EN = 38      # English cue characters
MAX_DATA = 6144      # glyph + latin bitmap bytes
SLOTS = 15
# characters the 8x8 screen font (src/charset.asm) can show
SCR_OK = set("abcdefghijklmnopqrstuvwxyz0123456789 !()*,-./:?+%&<>'")


def fail(msg):
    sys.stderr.write("glyphs.py: " + msg + "\n")
    sys.exit(1)


def parse_bit(path, width, decode):
    """Return {char: [row bitmasks]} for a Shinonome font_src.bit file."""
    glyphs = {}
    code = None
    rows = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("STARTCHAR"):
                code = int(line.split()[1], 16)
                rows = None
            elif line.startswith("BITMAP"):
                rows = []
            elif line.startswith("ENDCHAR"):
                if rows is not None and len(rows) == 16:
                    ch = decode(code)
                    if ch is not None:
                        glyphs[ch] = rows
                rows = None
            elif rows is not None and len(line) >= width and \
                    all(c in ".@" for c in line[:width]):
                bits = 0
                for c in line[:width]:
                    bits = (bits << 1) | (1 if c == "@" else 0)
                rows.append(bits)
    return glyphs


def jis_to_char(code):
    try:
        return bytes([(code >> 8) | 0x80, (code & 0xFF) | 0x80]).decode("euc_jp")
    except UnicodeDecodeError:
        return None


def pack_cells(rows):
    """16x16 rows -> 32 bytes in cell order TL, TR, BL, BR."""
    out = []
    for cell in range(4):
        r0 = 0 if cell < 2 else 8
        shift = 8 if cell % 2 == 0 else 0
        for r in range(r0, r0 + 8):
            out.append((rows[r] >> shift) & 0xFF)
    return out


def write_png(path, width, height, pixels):
    """pixels: list of rows, each a list of (r,g,b)."""
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
    quiet = "--quiet" in sys.argv
    text = json.load(open(TEXT, encoding="utf-8"))
    kfont = parse_bit(KANJI, 16, jis_to_char)
    lfont = parse_bit(LATIN, 8, lambda c: chr(c))
    if not quiet:
        print(f"kanji font: {len(kfont)} glyphs, latin font: {len(lfont)} glyphs")

    # --- glyph set (index 0 = blank) ---
    order = []            # chars in index order
    index = {}

    def jp_string(s, what, limit=MAX_JP):
        idx = []
        for ch in s:
            if ch == " " or ch == "　":
                idx.append(0)
                continue
            if ch not in index:
                if ch not in kfont:
                    fail(f"{what}: glyph {ch!r} (U+{ord(ch):04X}) is not in the kanji font")
                index[ch] = len(order) + 1
                order.append(ch)
            idx.append(index[ch])
        if len(idx) > limit:
            fail(f"{what}: {s!r} is {len(idx)} glyphs (max {limit})")
        if len(idx) == 0:
            fail(f"{what}: empty string")
        return idx

    lorder = [" "]
    lindex = {" ": 0}

    def latin_string(s, what):
        if len(s) > MAX_CUE_EN:
            fail(f"{what}: {s!r} is {len(s)} chars (max {MAX_CUE_EN})")
        idx = []
        for ch in s:
            if ch not in lindex:
                if ch not in lfont:
                    fail(f"{what}: {ch!r} is not in the latin font")
                lindex[ch] = len(lorder)
                lorder.append(ch)
            idx.append(lindex[ch])
        while len(idx) % 3:
            idx.append(0)
        return idx

    def scr_string(s, what, limit):
        if len(s) > limit:
            fail(f"{what}: {s!r} is {len(s)} chars (max {limit})")
        bad = [c for c in s if c not in SCR_OK]
        if bad:
            fail(f"{what}: {s!r} uses characters missing from the screen font: {bad}")
        return s

    routines = text["routines"]
    if len(routines) != 2:
        fail("need exactly 2 routines")
    slots = []            # (jp idx list, name, cue idx list, cue_en idx list)
    for r, rt in enumerate(routines):
        if len(rt["slots"]) != SLOTS:
            fail(f"routine {r+1}: need {SLOTS} slots")
        for k, sl in enumerate(rt["slots"]):
            what = f"routine {r+1} slot {k} ({sl['id']})"
            slots.append((jp_string(sl["jp"], what + " jp"),
                          scr_string(sl["name"], what + " name", MAX_NAME),
                          jp_string(sl["cue_jp"], what + " cue_jp"),
                          latin_string(sl["cue_en"], what + " cue_en"),
                          sl))
    titles = [jp_string(rt["title_jp"], f"title {r+1}") for r, rt in enumerate(routines)]
    kana = [jp_string(w, f"kana {i}") for i, w in enumerate(text["kana"])]
    romaji = [scr_string(w, f"romaji {i}", 6) for i, w in enumerate(text["romaji"])]
    if len(kana) != 8 or len(romaji) != 8:
        fail("need 8 kana and 8 romaji count words")
    for i, w in enumerate(kana):
        if len(w) > 4:
            fail(f"kana word {i} longer than 4 glyphs (area C)")
    jp_string(text.get("title_chars", ""), "title_chars")

    nglyphs = len(order) + 1
    nlatin = len(lorder)
    data_bytes = nglyphs * 32 + nlatin * 16
    if data_bytes > MAX_DATA:
        fail(f"glyph bitmaps are {data_bytes} bytes (max {MAX_DATA}): "
             f"{nglyphs} glyphs + {nlatin} latin half glyphs")

    # --- emit ---
    lines = []
    w = lines.append
    w("; gen_glyphs.asm — generated by tools/glyphs.py from tools/text.json")
    w("; DO NOT EDIT. Glyphs from Shinonome 16 (public domain, tools/fonts/).")
    w(f"; {nglyphs} glyphs x 32 B + {nlatin} latin half glyphs x 16 B = {data_bytes} B")
    w(f"GLYPH_COUNT = {nglyphs}")
    w(f"LATIN_COUNT = {nlatin}")
    w("!align 255, 0")
    w("glyph_data:                    ; cell order TL,TR,BL,BR; index 0 = blank")
    w("!fill 32, 0                    ; 0: blank")
    for i, ch in enumerate(order):
        b = pack_cells(kfont[ch])
        w(f"!byte {','.join('$%02x' % v for v in b)}  ; {i+1}: {ch}")
    w("latin_data:                    ; 8x16 rows; index 0 = space")
    for i, ch in enumerate(lorder):
        rows = lfont.get(ch, [0] * 16)
        w(f"!byte {','.join('$%02x' % v for v in rows)}  ; {i}: {ch!r}")

    def emit_jp(label, idx, comment):
        w(f"{label}: !byte {len(idx)},{','.join(str(v) for v in idx)}  ; {comment}")

    def emit_latin(label, idx, comment):
        cells = len(idx) // 3
        w(f"{label}: !byte {cells},{','.join(str(v) for v in idx)}  ; {comment}")

    # dedupe identical strings between routines
    w("; --- strings ---")
    seen = {}
    labels_jp, labels_name, labels_cue, labels_cue_en = [], [], [], []

    def dedupe(kind, key, make):
        k = (kind, tuple(key))
        if k not in seen:
            seen[k] = f"{kind}_{len(seen)}"
            make(seen[k])
        return seen[k]

    for n, (jp, name, cue, cue_en, sl) in enumerate(slots):
        r, k = divmod(n, SLOTS)
        cm = f"r{r+1} s{k} {sl['id']}"
        labels_jp.append(dedupe("sjp", jp, lambda lb: emit_jp(lb, jp, cm + " " + sl["jp"])))
        labels_name.append(dedupe("snm", name, lambda lb: w(f'{lb}: !scr "{name}", $ff  ; {cm}')))
        labels_cue.append(dedupe("scj", cue, lambda lb: emit_jp(lb, cue, cm + " " + sl["cue_jp"])))
        labels_cue_en.append(dedupe("sce", cue_en, lambda lb: emit_latin(lb, cue_en, cm + " " + sl["cue_en"])))
    for i, t in enumerate(titles):
        emit_jp(f"stitle_{i}", t, routines[i]["title_jp"])
    # 第一 / 第二 for the title screen selection (last two glyphs of each title)
    w("title_sel_glyphs: !byte " + ",".join(str(v) for v in
      (titles[0][-2], titles[0][-1], titles[1][-2], titles[1][-1])))
    for i, kw in enumerate(kana):
        emit_jp(f"skana_{i}", kw, text["kana"][i])
    for i, rw in enumerate(romaji):
        w(f'sromaji_{i}: !scr "{rw}", $ff')

    def table(name, labels):
        w(f"{name}_lo: !byte " + ",".join("<" + l for l in labels))
        w(f"{name}_hi: !byte " + ",".join(">" + l for l in labels))

    w("; index = routine*15 + slot")
    table("mv_jp", labels_jp)
    table("mv_name", labels_name)
    table("mv_cue", labels_cue)
    table("mv_cue_en", labels_cue_en)
    table("title_jp", [f"stitle_{i}" for i in range(2)])
    table("kana", [f"skana_{i}" for i in range(8)])
    table("romaji", [f"sromaji_{i}" for i in range(8)])
    w("gen_glyphs_end:")
    src = "\n".join(lines) + "\n"
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(src)

    # --- review sheet ---
    BG, FG, SEP = (40, 40, 80), (255, 255, 255), (90, 90, 130)
    cell, per_row = 18, 16
    label_w = 32
    rows_k = (nglyphs + per_row - 1) // per_row
    rows_l = (nlatin + per_row * 2 - 1) // (per_row * 2)
    width = label_w + per_row * cell + 2
    height = (rows_k + rows_l) * cell + 4
    px = [[BG] * width for _ in range(height)]

    def blit16(x0, y0, rows, wid=16):
        for r in range(16):
            for c in range(wid):
                if rows[r] & (1 << (wid - 1 - c)):
                    px[y0 + r][x0 + c] = FG

    def label(x0, y0, n):
        for i, d in enumerate("%03d" % n):
            blit16(x0 + i * 8, y0, lfont.get(d, [0] * 16), 8)
    for i in range(nglyphs):
        gy, gx = divmod(i, per_row)
        x0, y0 = label_w + gx * cell + 1, gy * cell + 1
        if gx == 0:
            label(2, y0, i)
        for r in range(17):
            px[y0 - 1 + r][x0 - 1] = SEP
            px[y0 - 1][x0 - 1 + r] = SEP
        if i:
            blit16(x0, y0, kfont[order[i - 1]])
    base_y = rows_k * cell + 2
    for i in range(nlatin):
        gy, gx = divmod(i, per_row * 2)
        x0, y0 = label_w + gx * 9 + 1, base_y + gy * cell + 1
        if gx == 0:
            label(2, y0, i)
        blit16(x0, y0, lfont.get(lorder[i], [0] * 16), 8)
    write_png(PNG, width, height, px)

    if not quiet:
        print(f"glyphs: {nglyphs} (incl. blank) = {nglyphs*32} B; latin: {nlatin} = {nlatin*16} B; "
              f"total bitmaps {data_bytes} B; source {len(src)} chars -> {OUT}")
        print("glyph set: " + "".join(order))
        print("latin set: " + "".join(lorder))
        longest = max(len(s[0]) for s in slots)
        print(f"longest name {longest} glyphs, longest cue {max(len(s[2]) for s in slots)} glyphs, "
              f"longest en cue {max(len(s[3]) for s in slots)//3} cells")
        print(f"sheet: {PNG}")


if __name__ == "__main__":
    main()
