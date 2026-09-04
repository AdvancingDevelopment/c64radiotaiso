#!/usr/bin/env python3
"""puppet.py — sprite puppet generator for Radio Taiso 64 (stdlib only).

Reads tools/out/poses.json (from tools/sample_rig.mjs), adds the hand-authored
bow timeline (id 19), quantizes every tick of every timeline to a set of
shared body-part sprite frames, rasterizes the frames (big pixels: every
sprite is X/Y-expanded 2x), delta-codes the per-tick pose records and writes

  src/gen_sprites.asm   sprite bitmaps at * = FRAMES (slots 64..), 64 B each
  src/gen_poses.asm     per-frame metadata tables + delta-coded pose streams
  build/frames.png      contact sheet of every frame (slot numbers)
  build/contact_<id>-<name>.png   8x8 sheet of the 64 ticks, composited with
                        the same integer arithmetic figure.asm uses

Coordinate conventions (shared with figure.asm):
  * big pixel (bp) = one sprite pixel = 2 screen px at 2x (1 at 1x)
  * angles: 0 = down, 90 = screen-left, 180 = up, 270 = screen-right
  * per-frame metadata, indexed by (pointer byte - 64), all signed bp:
      frm_ox/frm_oy  box top-left relative to the part's pivot joint
      frm_ex/frm_ey  distal joint relative to the pivot (elbow, hand, knee,
                     ankle, neck)
      torso_sx/sy    shoulder relative to the waist (torso frames only,
                     indexed by pointer - TORSO_BASE)
  * pose record (12 bytes): fig_y (signed screen px at 2x), torso, head,
    upperL, upperR, foreL, foreR, thighL, thighR, shinL, shinR pointer bytes,
    split offset (raster lines below the waist line, at 2x)

usage: puppet.py [--stats] [--no-png]
"""
import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pngw import Canvas, text  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
POSES_JSON = os.path.join(HERE, "out", "poses.json")
OUT_SPRITES = os.path.join(ROOT, "src", "gen_sprites.asm")
OUT_POSES = os.path.join(ROOT, "src", "gen_poses.asm")
BUILD = os.path.join(ROOT, "build")

# ---------------------------------------------------------------------------
# geometry (big pixels)
# ---------------------------------------------------------------------------
SCALE = 0.24                        # bp per SVG unit
L_UP = 35.44 * SCALE                # 8.51  shoulder -> elbow
L_FORE = 32.98 * SCALE              # 7.92  elbow -> wrist
L_THIGH = 65.62 * SCALE             # 15.75 hip -> knee
L_SHIN = 42.19 * SCALE              # 10.13 knee -> ankle
L_TORSO = 89.0 * SCALE              # 21.36 waist -> neck
R_HEAD = 19.0 * SCALE               # 4.56  head radius (centre 19 above the neck)
D_HEAD = 19.0 * SCALE
R_HEAD_IN = 2.6                     # ring hole radius (2-bp stroke)
SHOULDER_FRAC = 72.0 / 89.0         # shoulder is 72 of 89 units up the torso
FOOT_ANG = 80.0                     # foot direction relative to the shin
NECK_STUB = 2.0                     # head frame: capsule from the neck down the torso
LINE_R = 1.0                        # capsule radius (2-bp lines)
LEVELS = (0.6, 0.8, 1.0)            # torso length levels

# quantization: part -> (step, offset)
QUANT = {"up": (10, 5), "fore": (10, 5), "thigh": (5, 0), "shin": (5, 0),
         "torso": (10, 0), "head": (10, 0)}
FIRST_SLOT = 64
MAX_FRAMES = 154
SPRITE_OF = {"foreL": 0, "foreR": 1, "upL": 2, "upR": 3, "head": 4, "torso": 5,
             "thighL": 6, "thighR": 7, "shinL": 4, "shinR": 5}

WAIST_X = 184                       # sprite X of the waist
FLOOR_LINE = 218                    # last raster line of text row 20
FIELDS = ["y", "torso", "head", "upL", "upR", "foreL", "foreR",
          "thighL", "thighR", "shinL", "shinR", "split"]

TIMELINE_NAMES = ["stretch-up", "arm-swings-leg-bends", "arm-circles", "chest-stretch",
                  "side-bends", "forward-back-bends", "body-twists", "up-down-stretch",
                  "diagonal-bend-chest", "body-rotation", "jumping", "cool-down-swings",
                  "deep-breathing", "whole-body-shake", "hop-steps", "curl-squats",
                  "deep-folds", "warmup", "idle", "bow"]


def dirv(a):
    """unit vector for angle a (deg): 0 = down, 90 = screen-left"""
    r = math.radians(a)
    return (-math.sin(r), math.cos(r))


def rnd(v):
    return int(math.floor(v + 0.5))


def quant(a, part):
    step, off = QUANT[part]
    return (rnd((a - off) / step) * step + off) % 360


def nearest_level(ratio):
    return min(range(len(LEVELS)), key=lambda i: abs(LEVELS[i] - ratio))


def s8(v):
    assert -128 <= v <= 127, v
    return v & 0xFF


# ---------------------------------------------------------------------------
# the bow (timeline 19): 16 hand-authored keyframes, 4 ticks apart, linearly
# interpolated. Profile (facing left), torso folds ~60 degrees forward and
# back, arms hanging plumb, head curling with the spine.
# ---------------------------------------------------------------------------
def bow_timeline():
    REST = dict(y=0, torso=180, torso_len=1.0, head_tilt=0, facing="F",
                upL=16.4, upR=343.6, foreL=14.0, foreR=346.0,
                thighL=7.9, thighR=352.1, shinL=5.4, shinR=354.6, footR_flip=False)
    PROF = dict(REST, facing="L", thighL=0, thighR=0, shinL=0, shinR=0, footR_flip=True,
                upL=8, upR=352, foreL=6, foreR=354)

    def bend(deg, tilt):                      # forward = toward screen-left
        return dict(PROF, torso=180 - deg, head_tilt=tilt,
                    upL=(180 - deg + 8) - 180 + 4, upR=(180 - deg - 8) - 180 - 4,
                    foreL=2, foreR=358)
    keys = [REST, PROF, bend(20, -4), bend(40, -8), bend(55, -12), bend(62, -14),
            bend(62, -14), bend(60, -14), bend(60, -14), bend(56, -12), bend(45, -10),
            bend(30, -6), bend(14, -3), PROF, PROF, REST]
    assert len(keys) == 16
    # arms: keep them hanging (absolute angle near 0), independent of the bend
    for k in keys:
        if k["facing"] == "L" and k["torso"] < 180:
            k["upL"], k["upR"], k["foreL"], k["foreR"] = 6, 354, 3, 357
    ticks = []

    def lerp_ang(a, b, t):
        d = ((b - a + 540) % 360) - 180
        return (a + d * t) % 360
    for k in range(64):
        i, f = divmod(k, 4)
        a, b = keys[i], keys[(i + 1) % 16]
        t = f / 4.0
        rec = {}
        for key in ("torso", "upL", "upR", "foreL", "foreR", "thighL", "thighR", "shinL", "shinR"):
            rec[key] = lerp_ang(a[key], b[key], t)
        rec["y"] = a["y"] + (b["y"] - a["y"]) * t
        rec["torso_len"] = a["torso_len"] + (b["torso_len"] - a["torso_len"]) * t
        rec["head_tilt"] = a["head_tilt"] + (b["head_tilt"] - a["head_tilt"]) * t
        rec["head"] = (rec["torso"] + rec["head_tilt"]) % 360
        rec["facing"] = a["facing"] if t < 0.5 else b["facing"]
        rec["footR_flip"] = a["footR_flip"] if t < 0.5 else b["footR_flip"]
        ticks.append(rec)
    return {"id": 19, "name": "bow", "duration": 8, "ticks": ticks}


# ---------------------------------------------------------------------------
# rasterizer
# ---------------------------------------------------------------------------
CANV = 64
PIV = 32.0                          # pivot at the pixel corner (32, 32)


def capsule(p0, p1, r=LINE_R):
    (x0, y0), (x1, y1) = p0, p1
    dx, dy = x1 - x0, y1 - y0
    l2 = dx * dx + dy * dy

    def f(cx, cy):
        t = 0.0 if l2 == 0 else max(0.0, min(1.0, ((cx - x0) * dx + (cy - y0) * dy) / l2))
        px, py = x0 + t * dx, y0 + t * dy
        return (cx - px) ** 2 + (cy - py) ** 2 <= r * r
    return f


def disc(c, r):
    return lambda cx, cy: (cx - c[0]) ** 2 + (cy - c[1]) ** 2 <= r * r


def ring(c, r_out, r_in):
    return lambda cx, cy: r_in * r_in <= (cx - c[0]) ** 2 + (cy - c[1]) ** 2 <= r_out * r_out


def obox(p, u_dir, u0, u1, v_half):
    """oriented rectangle: u along u_dir from p, v perpendicular"""
    ux, uy = u_dir
    vx, vy = -uy, ux

    def f(cx, cy):
        dx, dy = cx - p[0], cy - p[1]
        u, v = dx * ux + dy * uy, dx * vx + dy * vy
        return u0 <= u <= u1 and -v_half <= v <= v_half
    return f


def raster(shapes, clip=None):
    ink = set()
    for j in range(CANV):
        cy = j + 0.5
        for i in range(CANV):
            cx = i + 0.5
            if clip and not clip(cx, cy):
                continue
            for s in shapes:
                if s(cx, cy):
                    ink.add((i, j))
                    break
    return ink


def P(v):
    return (PIV + v[0], PIV + v[1])


class Frame:
    def __init__(self, key, kind, ink, distal, shoulder=None, align="centre"):
        self.key, self.kind, self.align = key, kind, align
        self.distal = distal                      # (ex, ey) bp, exact
        self.shoulder = shoulder
        self.place(ink)

    def place(self, ink):
        xs = [i for i, _ in ink]
        ys = [j for _, j in ink]
        c0, c1, r0, r1 = min(xs), max(xs), min(ys), max(ys)
        h = r1 - r0 + 1
        if self.align == "bottom":
            if h > 21:                            # torso too long: keep the waist end
                r1 = min(r1, int(PIV) - 1)        # drop the cap below the waist
            top = r1 - 20
        elif self.align == "top":
            top = r0
        else:
            top = r0 - (21 - h) // 2
        w = c1 - c0 + 1
        assert w <= 24, (self.key, w)
        left = c0 - (24 - w) // 2
        self.ox, self.oy = left - int(PIV), top - int(PIV)
        self.bits = [[0] * 24 for _ in range(21)]
        lost = 0
        for i, j in ink:
            x, y = i - left, j - top
            if 0 <= x < 24 and 0 <= y < 21:
                self.bits[y][x] = 1
            else:
                lost += 1
        assert lost == 0 or (self.kind == "torso" and h > 21), (self.key, lost)
        self.clipped = lost
        rows = [y for y in range(21) if any(self.bits[y])]
        self.ink_top, self.ink_bottom = rows[0], rows[-1]
        cols = [x for x in range(24) if any(self.bits[y][x] for y in range(21))]
        self.ink_left, self.ink_right = cols[0], cols[-1]

    def ex(self):
        return rnd(self.distal[0])

    def ey(self):
        return rnd(self.distal[1])

    def data(self):
        out = bytearray()
        for y in range(21):
            row = self.bits[y]
            for b in range(3):
                v = 0
                for k in range(8):
                    v = (v << 1) | row[b * 8 + k]
                out.append(v)
        out.append(0)
        assert len(out) == 64
        return bytes(out)


def make_frame(key):
    kind = key[0]
    if kind == "up":
        a = key[1]
        d = dirv(a)
        end = (L_UP * d[0], L_UP * d[1])
        return Frame(key, kind, raster([capsule(P((0, 0)), P(end))]), end)
    if kind == "fore":
        a = key[1]
        d = dirv(a)
        wrist = (L_FORE * d[0], L_FORE * d[1])
        hand = (wrist[0] + 0.9 * d[0], wrist[1] + 0.9 * d[1])
        ink = raster([capsule(P((0, 0)), P(wrist)), disc(P(hand), 1.75)])
        return Frame(key, kind, ink, wrist)
    if kind == "thigh":
        a = key[1]
        d = dirv(a)
        end = (L_THIGH * d[0], L_THIGH * d[1])
        return Frame(key, kind, raster([capsule(P((0, 0)), P(end))]), end)
    if kind == "shin":
        a, side = key[1], key[2]
        d = dirv(a)
        ankle = (L_SHIN * d[0], L_SHIN * d[1])
        fa = a + FOOT_ANG if side == "L" else a - FOOT_ANG
        fd = dirv(fa)
        ink = raster([capsule(P((0, 0)), P(ankle)), obox(P(ankle), fd, -0.5, 2.5, 1.0)])
        return Frame(key, kind, ink, ankle, align="top")
    if kind == "torso":
        a, lvl = key[1], key[2]
        d = dirv(a)
        L = L_TORSO * LEVELS[lvl]
        neck = (L * d[0], L * d[1])
        sh = (SHOULDER_FRAC * L * d[0], SHOULDER_FRAC * L * d[1])
        return Frame(key, kind, raster([capsule(P((0, 0)), P(neck))]), neck, sh, align="bottom")
    if kind == "head":
        a, face = key[1], key[2]
        d = dirv(a)
        c = (D_HEAD * d[0], D_HEAD * d[1])
        shapes = [ring(P(c), R_HEAD, R_HEAD_IN),
                  capsule(P((0, 0)), P((-NECK_STUB * d[0], -NECK_STUB * d[1])))]
        if face in "LR":
            nd = dirv(a - 90) if face == "L" else dirv(a + 90)
            nose = (c[0] + (R_HEAD + 0.9) * nd[0], c[1] + (R_HEAD + 0.9) * nd[1])
            shapes.append(disc(P(nose), 1.15))
        return Frame(key, kind, raster(shapes), c, align="bottom")
    raise ValueError(key)


# ---------------------------------------------------------------------------
# quantize every tick -> frame keys
# ---------------------------------------------------------------------------
def tick_keys(t):
    lvl = nearest_level(t["torso_len"])
    face = t["facing"]
    shinL_side = "L"
    shinR_side = "L" if t["footR_flip"] else "R"
    return {
        "torso": ("torso", quant(t["torso"], "torso"), lvl),
        "head": ("head", quant(t["head"], "head"), face),
        "upL": ("up", quant(t["upL"], "up")), "upR": ("up", quant(t["upR"], "up")),
        "foreL": ("fore", quant(t["foreL"], "fore")), "foreR": ("fore", quant(t["foreR"], "fore")),
        "thighL": ("thigh", quant(t["thighL"], "thigh")), "thighR": ("thigh", quant(t["thighR"], "thigh")),
        "shinL": ("shin", quant(t["shinL"], "shin"), shinL_side),
        "shinR": ("shin", quant(t["shinR"], "shin"), shinR_side),
    }


def build_frames(timelines):
    keys = {}
    for tl in timelines:
        for t in tl["ticks"]:
            for k in tick_keys(t).values():
                keys.setdefault(k, 0)
                keys[k] += 1
    order = ["up", "fore", "thigh", "shin", "torso", "head"]
    ordered = sorted(keys, key=lambda k: (order.index(k[0]), k[1:]))
    return ordered, keys


# ---------------------------------------------------------------------------
# 6502 integer chain (mirrors figure.asm exactly)
# ---------------------------------------------------------------------------
def chain(rec, frames, slot_of):
    """rec: field -> frame key (plus 'y'); returns joints and box positions in bp
    relative to the waist, exactly as figure.asm computes them."""
    f = {k: frames[slot_of[rec[k]]] for k in FIELDS[1:11]}
    torso = f["torso"]
    neck = (torso.ex(), torso.ey())
    sh = (rnd(torso.shoulder[0]), rnd(torso.shoulder[1]))
    elbowL = (sh[0] + f["upL"].ex(), sh[1] + f["upL"].ey())
    elbowR = (sh[0] + f["upR"].ex(), sh[1] + f["upR"].ey())
    kneeL = (f["thighL"].ex(), f["thighL"].ey())
    kneeR = (f["thighR"].ex(), f["thighR"].ey())
    joints = {"torso": (0, 0), "head": neck, "upL": sh, "upR": sh, "foreL": elbowL,
              "foreR": elbowR, "thighL": (0, 0), "thighR": (0, 0), "shinL": kneeL, "shinR": kneeR}
    boxes = {k: (joints[k][0] + f[k].ox, joints[k][1] + f[k].oy) for k in joints}
    return f, joints, boxes


def split_offset(boxes):
    """raster lines below the waist line (2x) for the shin re-trigger IRQ"""
    bottom = 2 * (max(boxes["head"][1], boxes["torso"][1]) + 21)   # last line of the 42-line box
    top = 2 * min(boxes["shinL"][1], boxes["shinR"][1])            # first line of the shin box
    gap = top - bottom
    return (bottom + top) // 2, gap, bottom, top


# ---------------------------------------------------------------------------
# delta coding
# ---------------------------------------------------------------------------
GROUPINGS = {
    "A": [["y"], ["torso"], ["head"], ["upL", "upR"], ["foreL", "foreR"],
          ["thighL", "thighR"], ["shinL", "shinR"], ["split"]],
    "B": [["y"], ["torso", "head"], ["upL"], ["upR"], ["foreL"], ["foreR"],
          ["thighL", "thighR", "shinL", "shinR"], ["split"]],
    "C": [["y"], ["torso"], ["head"], ["upL"], ["upR"], ["foreL", "foreR"],
          ["thighL", "thighR", "shinL", "shinR"], ["split"]],
    "D": [["y"], ["torso", "head"], ["upL", "upR"], ["foreL", "foreR"],
          ["thighL", "thighR"], ["shinL", "shinR"], ["split"], []],
    "E": [["y"], ["torso", "head", "split"], ["upL"], ["upR"], ["foreL"], ["foreR"],
          ["thighL", "thighR", "shinL", "shinR"], []],
    "F": [["y", "split"], ["torso", "head"], ["upL"], ["upR"], ["foreL"], ["foreR"],
          ["thighL", "thighR", "shinL", "shinR"], []],
}


def delta_code(records, groups):
    """records: list of 12-byte lists; returns the byte stream"""
    out = bytearray()
    prev = None
    for rec in records:
        mask = 0
        payload = bytearray()
        for bit, g in enumerate(groups):
            if not g:
                continue
            idx = [FIELDS.index(x) for x in g]
            if prev is None or any(rec[i] != prev[i] for i in idx):
                mask |= 1 << bit
                payload += bytes(rec[i] for i in idx)
        out.append(mask)
        out += payload
        prev = rec
    return bytes(out)


# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
def asm_bytes(label, data, per_line=16, comment=None):
    lines = []
    if comment:
        lines.append("; " + comment)
    if label:
        lines.append(label + ":")
    for i in range(0, len(data), per_line):
        chunk = data[i:i + per_line]
        lines.append("        !byte " + ",".join("$%02x" % b for b in chunk))
    return "\n".join(lines) + "\n"


PAL = [(0x35, 0x28, 0x79), (0xff, 0xff, 0xff), (0x80, 0x80, 0xa0), (0xc0, 0x40, 0x40),
       (0x40, 0xc0, 0x40), (0xd0, 0xa0, 0x40), (0x20, 0x18, 0x50), (0x60, 0x50, 0xa0)]
C_BG, C_INK, C_GRID, C_RED, C_GREEN, C_YELLOW, C_DARK, C_DIM = range(8)


def frames_png(frames, path):
    cols = 16
    cw, ch = 52, 56
    rows = (len(frames) + cols - 1) // cols
    cv = Canvas(cols * cw, rows * ch, C_BG)
    for n, fr in enumerate(frames):
        x0, y0 = (n % cols) * cw + 2, (n // cols) * ch + 8
        cv.frame(x0 - 1, y0 - 1, 50, 44, C_GRID)
        for y in range(21):
            for x in range(24):
                if fr.bits[y][x]:
                    cv.rect(x0 + 2 * x, y0 + 2 * y, 2, 2, C_INK)
        # pivot (red) and distal joint (green) markers
        px, py = -fr.ox, -fr.oy
        cv.rect(x0 + 2 * px - 1, y0 + 2 * py - 1, 2, 2, C_RED)
        dx, dy = px + fr.ex(), py + fr.ey()
        cv.rect(x0 + 2 * dx - 1, y0 + 2 * dy - 1, 2, 2, C_GREEN)
        text(cv, x0, y0 - 7, str(FIRST_SLOT + n), C_YELLOW)
    cv.save(path, PAL)


def contact_png(tl, records, frames, slot_of, waist_y, path):
    # screen window in sprite coordinates
    X0, X1, Y0, Y1 = 64, 312, 78, 250
    cw, ch = X1 - X0 + 4, Y1 - Y0 + 12
    cv = Canvas(8 * cw, 8 * ch, C_DARK)
    for k, (t, rec) in enumerate(zip(tl["ticks"], records)):
        ox, oy = (k % 8) * cw + 2, (k // 8) * ch + 10
        cv.rect(ox, oy, X1 - X0, Y1 - Y0, C_BG)
        wy = waist_y + rec["y"]
        # floor (row 20 bottom) and the name rows limit (sprite Y 84)
        cv.hline(ox, oy + FLOOR_LINE - Y0, X1 - X0, C_DIM)
        cv.hline(ox, oy + 84 - Y0, X1 - X0, C_DIM)
        f, joints, boxes = chain(rec, frames, slot_of)
        # split + scroller lines
        split, gap, bottom, top = split_offset(boxes)
        cv.hline(ox, oy + wy + split - Y0, X1 - X0, C_RED)
        scroll = max(wy + 2 * max(boxes["shinL"][1], boxes["shinR"][1]) + 43, 219)
        cv.hline(ox, oy + min(scroll, 246) - Y0, X1 - X0, C_GREEN)
        # composite, back to front (higher sprite number first)
        order = sorted(boxes, key=lambda p: -SPRITE_OF[p])
        for part in order:
            fr = f[part]
            bx, by = boxes[part]
            sx, sy = WAIST_X + 2 * bx, wy + 2 * by
            for y in range(21):
                for x in range(24):
                    if fr.bits[y][x]:
                        cv.rect(ox + sx + 2 * x - X0, oy + sy + 2 * y + 1 - Y0, 2, 2, C_INK)
        text(cv, ox, oy - 8, "%d %d" % (tl["id"], k), C_YELLOW)
    cv.save(path, PAL)


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stats", action="store_true", help="only print the frame budget")
    ap.add_argument("--no-png", action="store_true")
    args = ap.parse_args()

    data = json.load(open(POSES_JSON))
    timelines = data["timelines"]
    assert [tl["id"] for tl in timelines] == list(range(19))
    timelines.append(bow_timeline())
    for tl in timelines:
        assert tl["name"] == TIMELINE_NAMES[tl["id"]], (tl["name"], tl["id"])
        assert len(tl["ticks"]) == 64

    keys, usage = build_frames(timelines)
    per_kind = {}
    for k in keys:
        per_kind[k[0]] = per_kind.get(k[0], 0) + 1
    print("frame budget: %d frames (%s)" % (len(keys), ", ".join("%s %d" % kv for kv in per_kind.items())))
    if args.stats:
        for k in keys:
            print("  ", k, usage[k])
        return
    assert len(keys) <= MAX_FRAMES, "over budget: %d > %d" % (len(keys), MAX_FRAMES)

    frames = [make_frame(k) for k in keys]
    slot_of = {fr.key: n for n, fr in enumerate(frames)}    # index (pointer - 64)
    kinds = [fr.kind for fr in frames]
    torso_base = kinds.index("torso")
    torso_count = kinds.count("torso")
    assert kinds[torso_base:torso_base + torso_count] == ["torso"] * torso_count

    # rest geometry -> waist line so the feet stand on row 20
    rest = tick_keys(timelines[18]["ticks"][0])
    rest_rec = dict(rest, y=0)
    f, joints, boxes = chain(rest_rec, frames, slot_of)
    foot_bottom = max(boxes["shinL"][1] + f["shinL"].ink_bottom, boxes["shinR"][1] + f["shinR"].ink_bottom)
    # sprite row r of a sprite at Y shows on rasters Y+2r+1, Y+2r+2 (2x)
    waist_y2 = FLOOR_LINE - 2 * foot_bottom - 2
    waist_y1 = FLOOR_LINE - foot_bottom - 1
    print("rest foot bottom row %d bp below the waist -> WAIST_Y 2x = %d, 1x = %d" % (foot_bottom, waist_y2, waist_y1))

    # per-tick records
    all_records = []
    stats = {"gap_min": 999, "gap_tick": None, "x_min": 999, "x_max": -999, "y_min": 999,
             "y_max": -999, "scroll_min": 999, "scroll_max": 0, "split_min": 999, "split_max": 0,
             "ink_top_min": 999, "shin_bottom_max": 0, "bx_min": 999, "bx_max": -999,
             "by_min": 999, "by_max": -999}
    for tl in timelines:
        recs = []
        for k, t in enumerate(tl["ticks"]):
            kk = tick_keys(t)
            y_px = rnd(t["y"] * SCALE * 2)
            rec = dict(kk, y=y_px)
            f, joints, boxes = chain(rec, frames, slot_of)
            split, gap, bottom, top = split_offset(boxes)
            assert -128 <= split <= 127
            if gap < stats["gap_min"]:
                stats["gap_min"], stats["gap_tick"] = gap, (tl["name"], k)
            wy = waist_y2 + y_px
            for part, (bx, by) in boxes.items():
                stats["bx_min"], stats["bx_max"] = min(stats["bx_min"], bx), max(stats["bx_max"], bx)
                stats["by_min"], stats["by_max"] = min(stats["by_min"], by), max(stats["by_max"], by)
                sx, sy = WAIST_X + 2 * bx, wy + 2 * by
                fr = f[part]
                stats["x_min"] = min(stats["x_min"], sx + 2 * fr.ink_left)
                stats["x_max"] = max(stats["x_max"], sx + 2 * fr.ink_right + 1)
                stats["ink_top_min"] = min(stats["ink_top_min"], sy + 2 * fr.ink_top + 1)
                if part.startswith("shin"):
                    stats["shin_bottom_max"] = max(stats["shin_bottom_max"], sy + 2 * fr.ink_bottom + 2)
            scroll = max(wy + 2 * max(boxes["shinL"][1], boxes["shinR"][1]) + 43, 219)
            stats["scroll_min"], stats["scroll_max"] = min(stats["scroll_min"], scroll), max(stats["scroll_max"], scroll)
            stats["split_min"], stats["split_max"] = min(stats["split_min"], wy + split), max(stats["split_max"], wy + split)
            rec_bytes = [s8(y_px)] + [FIRST_SLOT + slot_of[kk[fld]] for fld in FIELDS[1:11]] + [split]
            recs.append((rec, rec_bytes))
        all_records.append(recs)
    print("multiplex gap min %d lines at %s; split lines %d..%d; scroller line %d..%d" % (
        stats["gap_min"], stats["gap_tick"], stats["split_min"], stats["split_max"],
        stats["scroll_min"], stats["scroll_max"]))
    print("ink X %d..%d, top ink Y %d, shin ink bottom max %d; box bp x %d..%d y %d..%d" % (
        stats["x_min"], stats["x_max"], stats["ink_top_min"], stats["shin_bottom_max"],
        stats["bx_min"], stats["bx_max"], stats["by_min"], stats["by_max"]))
    assert stats["gap_min"] >= 8, "multiplex gap too small"
    assert stats["ink_top_min"] >= 84, "figure reaches into the name rows"
    assert stats["shin_bottom_max"] <= 224, "shins below Y 224"
    assert stats["scroll_max"] <= 246
    assert stats["x_min"] >= 24 and stats["x_max"] <= 343

    # delta coding: pick the smallest grouping
    sizes = {}
    streams = {}
    for name, groups in GROUPINGS.items():
        total = 0
        st = []
        for recs in all_records:
            s = delta_code([rb for _, rb in recs], groups)
            st.append(s)
            total += len(s)
        sizes[name] = total
        streams[name] = st
    best = min(sizes, key=sizes.get)
    print("pose data: " + ", ".join("%s=%d" % (n, sizes[n]) for n in sorted(sizes)) + " -> grouping %s" % best)
    groups = GROUPINGS[best]
    stream = streams[best]
    pose_bytes = sum(len(s) for s in stream)

    # ---- gen_sprites.asm ----
    with open(OUT_SPRITES, "w") as out:
        out.write("; gen_sprites.asm — GENERATED by tools/puppet.py, do not edit\n")
        out.write("; %d puppet frames, sprite slots %d..%d (64 bytes each, byte 63 = 0)\n" % (
            len(frames), FIRST_SLOT, FIRST_SLOT + len(frames) - 1))
        out.write("; sprites are X/Y-expanded; 1 bp = 2 screen px\n")
        for n, fr in enumerate(frames):
            out.write("; slot %d: %s  ox %d oy %d ex %d ey %d\n" % (
                FIRST_SLOT + n, fr.key, fr.ox, fr.oy, fr.ex(), fr.ey()))
            d = fr.data()
            for i in range(0, 64, 16):
                out.write("        !byte " + ",".join("$%02x" % b for b in d[i:i + 16]) + "\n")
        out.write("PUPPET_FRAMES = %d\n" % len(frames))

    # ---- gen_poses.asm ----
    with open(OUT_POSES, "w") as out:
        out.write("; gen_poses.asm — GENERATED by tools/puppet.py, do not edit\n")
        out.write("; per-frame metadata (index = sprite pointer - %d, signed big pixels)\n" % FIRST_SLOT)
        out.write("FRM_FIRST     = %d\n" % FIRST_SLOT)
        out.write("FRM_COUNT     = %d\n" % len(frames))
        out.write("TORSO_BASE    = %d\n" % (FIRST_SLOT + torso_base))
        out.write("FIG_WAIST_Y2  = %d          ; waist sprite Y at 2x (feet on row 20)\n" % waist_y2)
        out.write("FIG_WAIST_Y1  = %d          ; waist sprite Y at 1x\n" % waist_y1)
        out.write("FIG_WAIST_X   = %d\n" % WAIST_X)
        out.write(asm_bytes("frm_ox", bytes(s8(fr.ox) for fr in frames), comment="box left relative to the pivot"))
        out.write(asm_bytes("frm_oy", bytes(s8(fr.oy) for fr in frames), comment="box top relative to the pivot"))
        out.write(asm_bytes("frm_ex", bytes(s8(fr.ex()) for fr in frames), comment="distal joint x"))
        out.write(asm_bytes("frm_ey", bytes(s8(fr.ey()) for fr in frames), comment="distal joint y"))
        tf = frames[torso_base:torso_base + torso_count]
        out.write(asm_bytes("torso_sx", bytes(s8(rnd(fr.shoulder[0])) for fr in tf), comment="shoulder x (torso frames)"))
        out.write(asm_bytes("torso_sy", bytes(s8(rnd(fr.shoulder[1])) for fr in tf), comment="shoulder y (torso frames)"))
        out.write("; delta stream groups: bit n of the mask -> pose_cur+grp_off[n], grp_len[n] bytes\n")
        goff = [FIELDS.index(g[0]) if g else 0 for g in groups]
        glen = [len(g) for g in groups]
        for g in groups:
            if g:
                assert [FIELDS.index(x) for x in g] == list(range(FIELDS.index(g[0]), FIELDS.index(g[0]) + len(g)))
        out.write("grp_off:  !byte " + ",".join(str(v) for v in goff) + "\n")
        out.write("grp_len:  !byte " + ",".join(str(v) for v in glen) + "\n")
        out.write("; timeline streams (%d timelines, %d bytes): mask byte + changed groups per tick\n" % (
            len(stream), pose_bytes))
        out.write("anim_lo:  !byte " + ",".join("<anim_%02d" % i for i in range(len(stream))) + "\n")
        out.write("anim_hi:  !byte " + ",".join(">anim_%02d" % i for i in range(len(stream))) + "\n")
        for i, s in enumerate(stream):
            out.write(asm_bytes("anim_%02d" % i, s, comment="%d %s (%d bytes)" % (i, TIMELINE_NAMES[i], len(s))))
        out.write("POSE_BYTES = %d\n" % pose_bytes)

    meta_bytes = 4 * len(frames) + 2 * torso_count + 16 + 2 * len(stream)
    print("wrote %s (%d frames = %d bytes) and %s (metadata %d bytes, poses %d bytes)" % (
        os.path.relpath(OUT_SPRITES, ROOT), len(frames), 64 * len(frames),
        os.path.relpath(OUT_POSES, ROOT), meta_bytes, pose_bytes))

    if args.no_png:
        return
    os.makedirs(BUILD, exist_ok=True)
    frames_png(frames, os.path.join(BUILD, "frames.png"))
    for tl, recs in zip(timelines, all_records):
        path = os.path.join(BUILD, "contact_%02d-%s.png" % (tl["id"], tl["name"]))
        contact_png(tl, [r for r, _ in recs], frames, slot_of, waist_y2, path)
    print("contact sheets in %s" % os.path.relpath(BUILD, ROOT))


if __name__ == "__main__":
    main()
