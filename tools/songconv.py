#!/usr/bin/env python3
"""songconv.py — Radio Taiso 64 song converter (score.json -> SID sequencer data).

  python3 tools/songconv.py            regenerate src/gen_song1.asm and src/gen_song2.asm
  python3 tools/songconv.py --check    re-parse the emitted .asm files, simulate the player's
                                       data state machine and diff it against the classified
                                       score events (expects 0 mismatches)
  python3 tools/songconv.py --dump N   list the decoded events of song N (1/2): tick, voice,
                                       tones, gate ticks, expected PAL / NTSC seconds
  options: --score-dir DIR (default ~/taiso/score), --out-dir DIR (default <repo>/src)

Source material: ~/taiso/score/score.json + score2.json (see compose.mjs there). Python 3 stdlib.

Time base: tick = 1/8 beat, 3072 ticks per song = 24 blocks of 128 ticks (one 4-bar phrase).

Voice mapping
  pianoRH                          -> voice 1  NOTE, instrument MELODY
  pianoLH, >= 2 notes on one tick  -> voice 3  CHORD (stab on beats 2/4), instrument STAB
  pianoLH, single note < 2 beats   -> voice 2  NOTE (bass on beats 1/3), instrument BASS
  pianoLH, long rolled chords      -> lowest tone: voice 2 NOTE, CALM_BASS; upper tones plus
     (calm section)                   lowest+12 as one ascending CHORD on voice 3, CALM_ARP,
                                      one tick after the bass
  tick = round(beat*8); dq = max(2, round(dur*8)); slot = ticks to the voice's next event:
  dq >= slot-1 -> the note fills the slot, else NOTE(dq) + REST(slot-dq); dq > slot (overlap)
  -> the next note is marked LEGATO (a tie when the pitch is the same).

Pattern byte format (one pattern per voice per block, deduplicated per song)
  $00-$3F  NOTE  n, len        n = MIDI-43 (G2..F#6), gate for len ticks (1..255)
  $40-$7F  CHORD c, len        c = index into the song's chord table (3 ascending note indices)
  $80-$BF  REST                gate off for (low 6 bits)+1 ticks
  $C0-$CF  INSTRUMENT k        k = 0 MELODY, 1 BASS, 2 STAB, 3 CALM_BASS, 4 CALM_ARP
  $D0      LEGATO              the next NOTE/CHORD only changes the frequency (no retrigger)
  $FE      end of pattern      -> next order-list entry
  $FF      end of song         (order-list terminator; also accepted inside a pattern)
  Every pattern starts with its INSTRUMENT byte and covers exactly 128 ticks.

Song header (see also src/music.asm)
  +0  word x3  order lists, voices 1..3 (24 pattern indices + $FF)
  +6  word     pattern address table, low bytes    +8  word  high bytes
  +10 word     chord table                          +12 word  clock period table (20 words)
  +14 word     end tick (3072)
  followed by the tempo events (count, (tick, bpm) pairs; documentation for tools only).
The period table is the clock's: index = segment*10 + ntsc*5 + tempo_level (0..4 = 80..120 %),
value = round(256 * f_frame * 60 / (bpm * mult * 8)); segment 1 = the slow tempo from tick 2816.
The 48-entry SID frequency tables (PAL / NTSC, F = f * 2^24 / clock) are emitted once, into
gen_song1.asm (note_pal_lo/hi, note_ntsc_lo/hi); music_init copies the right one to RAM.
"""
import argparse
import json
import math
import os
import re
import sys
from dataclasses import dataclass

# ---------------------------------------------------------------- constants
PAL_CLOCK, NTSC_CLOCK = 985248, 1022727
PAL_FRAME, NTSC_FRAME = PAL_CLOCK / 19656, NTSC_CLOCK / 17095   # frames per second
TICKS_PER_BEAT = 8
BLOCK_TICKS = 128
BLOCKS = 24
TOTAL_TICKS = BLOCKS * BLOCK_TICKS          # 3072 = 384 beats
NOTE_BASE = 43                              # MIDI G2 = note index 0
NOTE_COUNT = 48                             # G2..F#6
TEMPO_EVENT_TICK = 2816                     # beat 352 (clock.asm TEMPO_EVENT_TICK)
TEMPO_MULT = (0.8, 0.9, 1.0, 1.1, 1.2)      # tempo levels 0..4
I_MELODY, I_BASS, I_STAB, I_CALM_BASS, I_CALM_ARP = 0, 1, 2, 3, 4
INST_NAMES = ("MELODY", "BASS", "STAB", "CALM_BASS", "CALM_ARP")
# movement grid of movements.asm (slot starts in ticks, excluding warm-up 0 and finish 3072)
MV_START_TICKS = (128, 384, 640, 896, 1152, 1408, 1664, 1920, 2048, 2304, 2432, 2688, 2816)

SONGS = (
    # (json file, label prefix, title)
    ("score.json", "song1", "Asa no March"),
    ("score2.json", "song2", "Hikari no March"),
)
NOTE_NAMES = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def rnd(x):
    """round half up (Python's round() is banker's rounding)."""
    return int(math.floor(x + 0.5))


def pitch_to_midi(name):
    m = re.fullmatch(r"([A-G])(#?)(-?\d+)", name)
    if not m:
        raise ValueError(f"bad pitch {name!r}")
    semi = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}[m.group(1)]
    if m.group(2):
        semi += 1
    return 12 * (int(m.group(3)) + 1) + semi


def note_index(name):
    idx = pitch_to_midi(name) - NOTE_BASE
    if not 0 <= idx < NOTE_COUNT:
        raise ValueError(f"pitch {name} outside G2..F#6")
    return idx


def note_name(idx):
    midi = idx + NOTE_BASE
    return f"{NOTE_NAMES[midi % 12]}{midi // 12 - 1}"


def sid_freq(idx, clock):
    f = 440.0 * 2.0 ** ((idx + NOTE_BASE - 69) / 12.0)
    return rnd(f * 16777216.0 / clock)


def period_word(bpm, mult, ntsc):
    f_frame = NTSC_FRAME if ntsc else PAL_FRAME
    return rnd(256.0 * f_frame * 60.0 / (bpm * mult * TICKS_PER_BEAT))


def period_table(base_bpm, slow_bpm):
    """20 words: index = segment*10 + ntsc*5 + tempo_level."""
    out = []
    for bpm in (base_bpm, slow_bpm):
        for ntsc in (0, 1):
            for mult in TEMPO_MULT:
                out.append(period_word(bpm, mult, ntsc))
    return out


# ---------------------------------------------------------------- events
@dataclass
class Ev:
    tick: int
    voice: int                # 0 = SID voice 1 (melody), 1 = bass, 2 = stab/arp
    tones: tuple              # note indices: 1 for NOTE, 3 ascending for CHORD
    dq: int                   # quantized duration (ticks)
    inst: int
    gate: int = 0             # ticks actually gated (set by resolve_slots)
    legato: bool = False

    def key(self):
        return (self.tick, self.voice, self.tones, self.gate, self.inst, self.legato)


def load_score(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def classify(score):
    """Score notes -> per-voice event lists (unresolved gates) + statistics."""
    assert score["ppq"] == 4 and score["totalBeats"] * TICKS_PER_BEAT == TOTAL_TICKS
    tm = score["tempoMap"]
    assert len(tm) == 2 and tm[0]["beat"] == 0 and tm[1]["beat"] * TICKS_PER_BEAT == TEMPO_EVENT_TICK, \
        "tempo map must be {beat 0: base, beat 352: slow} (clock.asm TEMPO_EVENT_TICK)"
    starts = tuple(m["startBeat"] * TICKS_PER_BEAT for m in score["movements"])
    assert starts == MV_START_TICKS, f"movement grid differs from movements.asm: {starts}"

    voices = ([], [], [])
    stats = {"melody": 0, "bass": 0, "stab": 0, "calm": 0}
    lh_march = {}
    lh_calm = {}
    for n in score["notes"]:
        tick = rnd(n["beat"] * TICKS_PER_BEAT)
        dq = max(2, rnd(n["dur"] * TICKS_PER_BEAT))
        idx = note_index(n["pitch"])
        if n["voice"] == "pianoRH":
            voices[0].append(Ev(tick, 0, (idx,), dq, I_MELODY))
            stats["melody"] += 1
        elif n["voice"] == "pianoLH":
            if n["dur"] >= 2.0:
                lh_calm.setdefault(tick // (4 * TICKS_PER_BEAT), []).append((tick, idx, dq))
            else:
                lh_march.setdefault(tick, []).append((idx, dq))
        else:
            raise ValueError(f"unknown voice {n['voice']}")

    for tick in sorted(lh_march):
        grp = lh_march[tick]
        if len(grp) >= 2:
            assert len(grp) == 3, f"stab at tick {tick} has {len(grp)} notes"
            tones = tuple(sorted(i for i, _ in grp))
            voices[2].append(Ev(tick, 2, tones, max(d for _, d in grp), I_STAB))
            stats["stab"] += 1
        else:
            idx, dq = grp[0]
            voices[1].append(Ev(tick, 1, (idx,), dq, I_BASS))
            stats["bass"] += 1

    for bar in sorted(lh_calm):
        grp = sorted(lh_calm[bar])                      # by tick
        assert len(grp) == 3, f"calm bar {bar} has {len(grp)} notes"
        low_tick, low_idx, low_dq = min(grp, key=lambda t: t[1])
        assert low_tick % (4 * TICKS_PER_BEAT) == 0 and low_tick == grp[0][0], \
            f"calm bar {bar}: the lowest tone must start the roll"
        upper = [(i, d) for t, i, d in grp if i != low_idx]
        tones = tuple(sorted([i for i, _ in upper] + [low_idx + 12]))
        assert len(set(tones)) == 3 and max(tones) < NOTE_COUNT
        voices[1].append(Ev(low_tick, 1, (low_idx,), low_dq, I_CALM_BASS))
        voices[2].append(Ev(low_tick + 1, 2, tones, max(d for _, d in upper), I_CALM_ARP))
        stats["calm"] += 1

    for v in voices:
        v.sort(key=lambda e: e.tick)
        for a, b in zip(v, v[1:]):
            assert a.tick != b.tick, f"two events on voice {a.voice} at tick {a.tick}"
    return voices, stats


def resolve_slots(voices):
    """gate / rest / legato per event from the distance to the voice's next event."""
    for evs in voices:
        for i, ev in enumerate(evs):
            nxt = evs[i + 1].tick if i + 1 < len(evs) else TOTAL_TICKS
            slot = nxt - ev.tick
            assert 1 <= slot, ev
            if ev.dq > slot:                       # overlap: cut here, no retrigger next
                ev.gate = slot
                evs[i + 1].legato = True
            elif ev.dq >= slot - 1:
                ev.gate = slot
            else:
                ev.gate = ev.dq
            assert 1 <= ev.gate <= 255
    return voices


# ---------------------------------------------------------------- encoding
def encode_voice(evs, chord_index):
    """-> list of 24 byte strings (one pattern per block) for one voice."""
    items = [[] for _ in range(BLOCKS)]          # per block: ('N', idx, len) ('C', ci, len) ('R', n) ('L',)
    insts = [[] for _ in range(BLOCKS)]          # instrument per N/C item (parallel, None for others)

    def rest(start, n):
        t = start
        while n > 0:
            b = t // BLOCK_TICKS
            k = min(n, (b + 1) * BLOCK_TICKS - t, 64)
            items[b].append(("R", k))
            insts[b].append(None)
            t += k
            n -= k

    cur = 0
    for ev in evs:
        assert ev.tick >= cur, f"overlapping events at tick {ev.tick}"
        if ev.tick > cur:
            rest(cur, ev.tick - cur)
        b = ev.tick // BLOCK_TICKS
        assert (ev.tick + ev.gate - 1) // BLOCK_TICKS == b, f"note crosses a block boundary at tick {ev.tick}"
        if ev.legato:
            items[b].append(("L",))
            insts[b].append(None)
        if len(ev.tones) == 1:
            items[b].append(("N", ev.tones[0], ev.gate))
        else:
            items[b].append(("C", chord_index[ev.tones], ev.gate))
        insts[b].append(ev.inst)
        cur = ev.tick + ev.gate
    if cur < TOTAL_TICKS:
        rest(cur, TOTAL_TICKS - cur)

    patterns = []
    carried = I_MELODY
    for b in range(BLOCKS):
        first = next((k for k in insts[b] if k is not None), None)
        inst = carried if first is None else first
        out = bytearray([0xC0 | inst])
        ticks = 0
        for it, k in zip(items[b], insts[b]):
            if k is not None and k != inst:
                inst = k
                out.append(0xC0 | inst)
            if it[0] == "N":
                assert 0 <= it[1] < 0x40 and 1 <= it[2] <= 255
                out += bytes((it[1], it[2]))
                ticks += it[2]
            elif it[0] == "C":
                assert 0 <= it[1] < 0x40 and 1 <= it[2] <= 255
                out += bytes((0x40 | it[1], it[2]))
                ticks += it[2]
            elif it[0] == "R":
                assert 1 <= it[1] <= 64
                out.append(0x80 | (it[1] - 1))
                ticks += it[1]
            else:
                out.append(0xD0)
        assert ticks == BLOCK_TICKS, f"block {b} covers {ticks} ticks"
        out.append(0xFE)
        patterns.append(bytes(out))
        carried = inst
    return patterns


def build_song(score, prefix, title):
    voices, stats = classify(score)
    resolve_slots(voices)
    chords = sorted({ev.tones for evs in voices for ev in evs if len(ev.tones) == 3})
    assert len(chords) <= 64
    chord_index = {c: i for i, c in enumerate(chords)}
    pat_index = {}
    patterns = []
    orders = []
    usage = {}
    for v, evs in enumerate(voices):
        order = []
        for b, pat in enumerate(encode_voice(evs, chord_index)):
            if pat not in pat_index:
                pat_index[pat] = len(patterns)
                patterns.append(pat)
            order.append(pat_index[pat])
            usage.setdefault(pat_index[pat], []).append((v, b))
        orders.append(order)
    assert len(patterns) < 256
    tm = score["tempoMap"]
    return {
        "prefix": prefix, "title": title, "voices": voices, "stats": stats, "chords": chords,
        "patterns": patterns, "orders": orders, "usage": usage,
        "base_bpm": tm[0]["bpm"], "slow_bpm": tm[1]["bpm"],
        "periods": period_table(tm[0]["bpm"], tm[1]["bpm"]),
        "notes": len(score["notes"]),
    }


# ---------------------------------------------------------------- emission
def hexb(v):
    return f"${v:02x}"


def hexw(v):
    return f"${v:04x}"


def byte_lines(data, per_line=16):
    return "\n".join("        !byte " + ",".join(hexb(b) for b in data[i:i + per_line])
                     for i in range(0, len(data), per_line))


def emit_asm(song, src_name, with_note_tables):
    p = song["prefix"]
    st = song["stats"]
    pat_bytes = sum(len(x) for x in song["patterns"])
    total = 16 + 9 + 40 + 3 * (BLOCKS + 1) + 3 * len(song["chords"]) + 2 * len(song["patterns"]) + pat_bytes
    L = []
    L.append(f"; {p} — GENERATED by tools/songconv.py from {src_name}. Do not edit by hand.")
    L.append(f"; {song['title']}: {song['base_bpm']} -> {song['slow_bpm']} bpm at tick {TEMPO_EVENT_TICK}; "
             f"{song['notes']} score notes -> {st['melody']} melody, {st['bass']} bass, "
             f"{st['stab']} stabs, {st['calm']} calm bars")
    L.append(f"; {len(song['patterns'])} unique patterns ({pat_bytes} bytes), {len(song['chords'])} chords, "
             f"{total} bytes in total. Byte format: see src/music.asm.")
    L.append(f"{p}:")
    L.append(f"        !word {p}_ord0, {p}_ord1, {p}_ord2   ; order lists, voices 1..3")
    L.append(f"        !word {p}_pat_lo, {p}_pat_hi         ; pattern address tables")
    L.append(f"        !word {p}_chords                     ; chord table")
    L.append(f"        !word {p}_periods                    ; clock period table")
    L.append(f"        !word {TOTAL_TICKS}                          ; end tick")
    L.append(f"{p}_tempo:                            ; tempo events: count, (tick, bpm)*")
    L.append("        !byte 2")
    L.append(f"        !word 0, {song['base_bpm']}")
    L.append(f"        !word {TEMPO_EVENT_TICK}, {song['slow_bpm']}")
    L.append(f"{p}_periods:                          ; seg*10 + ntsc*5 + tempo level (80..120 %)")
    per = song["periods"]
    for i, tag in enumerate(("PAL base", "NTSC base", "PAL slow", "NTSC slow")):
        L.append("        !word " + ",".join(hexw(w) for w in per[i * 5:i * 5 + 5]) + f"   ; {tag}")
    for v, order in enumerate(song["orders"]):
        L.append(f"{p}_ord{v}:")
        L.append("        !byte " + ",".join(str(x) for x in order) + ",$ff")
    L.append(f"{p}_chords:                           ; ascending note-index triads")
    for i, c in enumerate(song["chords"]):
        L.append("        !byte " + ",".join(hexb(t) for t in c) + f"   ; {i:2d}: " +
                 " ".join(note_name(t) for t in c))
    n = len(song["patterns"])
    L.append(f"{p}_pat_lo:")
    for i in range(0, n, 8):
        L.append("        !byte " + ",".join(f"<{p}_p{j:02d}" for j in range(i, min(n, i + 8))))
    L.append(f"{p}_pat_hi:")
    for i in range(0, n, 8):
        L.append("        !byte " + ",".join(f">{p}_p{j:02d}" for j in range(i, min(n, i + 8))))
    for i, pat in enumerate(song["patterns"]):
        use = song["usage"][i]
        vs = sorted({v for v, _ in use})
        blocks = ",".join(str(b) for _, b in use)
        L.append(f"{p}_p{i:02d}:                              ; voice {'/'.join(str(v + 1) for v in vs)} "
                 f"blocks {blocks} ({len(pat)} bytes)")
        L.append(byte_lines(pat))
    if with_note_tables:
        L.append("")
        L.append("; SID frequency tables, note index = MIDI-43 (G2..F#6), F = f * 2^24 / clock.")
        L.append("; Shared by both songs; music_init copies the right pair to RAM note_lo/note_hi.")
        for tag, clock in (("pal", PAL_CLOCK), ("ntsc", NTSC_CLOCK)):
            freqs = [sid_freq(i, clock) for i in range(NOTE_COUNT)]
            L.append(f"note_{tag}_lo:")
            L.append(byte_lines([f & 0xFF for f in freqs]))
            L.append(f"note_{tag}_hi:")
            L.append(byte_lines([f >> 8 for f in freqs]))
    L.append("")
    return "\n".join(L), total


# ---------------------------------------------------------------- re-parser
def parse_asm(text, origin=0x8000):
    """Tiny interpreter for the generated subset: labels, !byte, !word, $hex, decimal,
    <label, >label, label. Returns (image bytes, {label: address})."""
    labels = {}
    lines = []
    for raw in text.splitlines():
        line = raw.split(";", 1)[0].rstrip()
        if not line.strip():
            continue
        m = re.match(r"^([A-Za-z_]\w*):\s*(.*)$", line)
        if m:
            lines.append(("label", m.group(1)))
            line = m.group(2)
            if not line.strip():
                continue
        m = re.match(r"^\s*!(byte|word)\s+(.*)$", line)
        if not m:
            raise ValueError(f"cannot parse line: {raw!r}")
        items = [x.strip() for x in m.group(2).split(",")]
        lines.append((m.group(1), items))
    # pass 1: addresses
    pc = origin
    for kind, val in lines:
        if kind == "label":
            assert val not in labels, f"duplicate label {val}"
            labels[val] = pc
        else:
            pc += len(val) * (1 if kind == "byte" else 2)
    image = bytearray(pc - origin)

    def value(tok):
        if tok.startswith("<"):
            return value(tok[1:]) & 0xFF
        if tok.startswith(">"):
            return (value(tok[1:]) >> 8) & 0xFF
        if tok.startswith("$"):
            return int(tok[1:], 16)
        if tok.isdigit():
            return int(tok)
        if tok in labels:
            return labels[tok]
        raise ValueError(f"unknown token {tok!r}")

    pc = origin
    for kind, val in lines:
        if kind == "label":
            continue
        for tok in val:
            v = value(tok)
            if kind == "byte":
                assert 0 <= v <= 0xFF, f"{tok} does not fit a byte"
                image[pc - origin] = v
                pc += 1
            else:
                assert 0 <= v <= 0xFFFF
                image[pc - origin] = v & 0xFF
                image[pc - origin + 1] = v >> 8
                pc += 2
    return bytes(image), labels, origin


class Image:
    def __init__(self, data, labels, origin):
        self.data, self.labels, self.origin = data, labels, origin

    def byte(self, addr):
        return self.data[addr - self.origin]

    def word(self, addr):
        return self.byte(addr) | (self.byte(addr + 1) << 8)

    def bytes(self, addr, n):
        return self.data[addr - self.origin:addr - self.origin + n]


def decode_song(img, prefix):
    """Simulate the player's data state machine -> (events, header dict)."""
    base = img.labels[prefix]
    hdr = {
        "orders": [img.word(base + 2 * v) for v in range(3)],
        "pat_lo": img.word(base + 6), "pat_hi": img.word(base + 8),
        "chords": img.word(base + 10), "periods": img.word(base + 12), "end": img.word(base + 14),
    }
    hdr["period_words"] = [img.word(hdr["periods"] + 2 * i) for i in range(20)]
    events = []
    pattern_ticks = {}
    for v in range(3):
        tick, inst, legato, o = 0, None, False, 0
        while True:
            pi = img.byte(hdr["orders"][v] + o)
            if pi == 0xFF:
                break
            p = img.byte(hdr["pat_lo"] + pi) | (img.byte(hdr["pat_hi"] + pi) << 8)
            start = tick
            assert img.byte(p) & 0xF0 == 0xC0, f"pattern {pi} does not start with INSTRUMENT"
            while True:
                b = img.byte(p)
                p += 1
                if b < 0x80:
                    ln = img.byte(p)
                    p += 1
                    if b < 0x40:
                        tones = (b,)
                    else:
                        tones = tuple(img.bytes(hdr["chords"] + 3 * (b & 0x3F), 3))
                    assert inst is not None
                    events.append(Ev(tick, v, tones, ln, inst, ln, legato))
                    legato = False
                    tick += ln
                elif b < 0xC0:
                    tick += (b & 0x3F) + 1
                elif b < 0xD0:
                    inst = b & 0x0F
                elif b == 0xD0:
                    legato = True
                elif b == 0xFE:
                    break
                else:
                    raise AssertionError(f"unexpected byte {b:02x} in pattern {pi}")
            pattern_ticks.setdefault(pi, tick - start)
            assert tick - start == BLOCK_TICKS, f"pattern {pi} covers {tick - start} ticks"
            o += 1
        assert o == BLOCKS, f"voice {v + 1}: {o} blocks"
        assert tick == hdr["end"] == TOTAL_TICKS
    events.sort(key=lambda e: (e.tick, e.voice))
    return events, hdr


def tick_seconds(tick, period_words, ntsc, tempo_level=2):
    """Emulated seconds from tick 0 to the given tick (100 % tempo by default)."""
    frame_s = 1.0 / (NTSC_FRAME if ntsc else PAL_FRAME)
    p0 = period_words[ntsc * 5 + tempo_level] / 256.0
    p1 = period_words[10 + ntsc * 5 + tempo_level] / 256.0
    t0 = min(tick, TEMPO_EVENT_TICK)
    t1 = max(0, tick - TEMPO_EVENT_TICK)
    return (t0 * p0 + t1 * p1) * frame_s


def load_generated(song_no, out_dir=None):
    """Parse the generated .asm of song 1/2 -> (events, header). Used by check_wav.py."""
    out_dir = out_dir or os.path.join(ROOT, "src")
    with open(os.path.join(out_dir, f"gen_song{song_no}.asm"), encoding="utf-8") as f:
        img = Image(*parse_asm(f.read()))
    return decode_song(img, SONGS[song_no - 1][1])


# ---------------------------------------------------------------- commands
def cmd_generate(score_dir, out_dir):
    for i, (fname, prefix, title) in enumerate(SONGS):
        song = build_song(load_score(os.path.join(score_dir, fname)), prefix, title)
        text, total = emit_asm(song, f"~/taiso/score/{fname}", with_note_tables=(i == 0))
        path = os.path.join(out_dir, f"gen_{prefix}.asm")
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        st = song["stats"]
        print(f"{path}: {total} bytes ({len(song['patterns'])} patterns, "
              f"{sum(len(p) for p in song['patterns'])} pattern bytes, {len(song['chords'])} chords); "
              f"melody {st['melody']} bass {st['bass']} stabs {st['stab']} calm {st['calm']}")


def cmd_check(score_dir, out_dir):
    ok = True
    expect_melody = (485, 544)
    for i, (fname, prefix, title) in enumerate(SONGS):
        score = load_score(os.path.join(score_dir, fname))
        voices, stats = classify(score)
        resolve_slots(voices)
        expected = sorted((ev for evs in voices for ev in evs), key=lambda e: (e.tick, e.voice))
        with open(os.path.join(out_dir, f"gen_{prefix}.asm"), encoding="utf-8") as f:
            img = Image(*parse_asm(f.read()))
        decoded, hdr = decode_song(img, prefix)
        exp_keys = [e.key() for e in expected]
        dec_keys = [e.key() for e in decoded]
        mism = 0
        for a, b in zip(exp_keys, dec_keys):
            if a != b:
                mism += 1
                if mism <= 10:
                    print(f"  mismatch: expected {a} decoded {b}")
        mism += abs(len(exp_keys) - len(dec_keys))
        # independent count checks on the decoded stream
        cnt = {}
        for e in decoded:
            cnt[(e.voice, e.inst, len(e.tones))] = cnt.get((e.voice, e.inst, len(e.tones)), 0) + 1
        checks = [
            (cnt.get((0, I_MELODY, 1), 0), expect_melody[i], "melody notes"),
            (cnt.get((1, I_BASS, 1), 0), 176, "bass notes"),
            (cnt.get((2, I_STAB, 3), 0), 176, "stab chords"),
            (cnt.get((1, I_CALM_BASS, 1), 0), 8, "calm bass"),
            (cnt.get((2, I_CALM_ARP, 3), 0), 8, "calm arps"),
            (sum(cnt.values()), len(decoded), "events"),
            (stats["melody"], expect_melody[i], "classified melody"),
            (stats["bass"], 176, "classified bass"), (stats["stab"], 176, "classified stabs"),
            (stats["calm"], 8, "classified calm bars"),
        ]
        for got, want, what in checks:
            if got != want:
                print(f"  {prefix}: {what}: {got} != {want}")
                ok = False
        tm = score["tempoMap"]
        if hdr["period_words"] != period_table(tm[0]["bpm"], tm[1]["bpm"]):
            print(f"  {prefix}: period table differs from the formula")
            ok = False
        if i == 0:
            for tag, clock in (("pal", PAL_CLOCK), ("ntsc", NTSC_CLOCK)):
                lo = img.bytes(img.labels[f"note_{tag}_lo"], NOTE_COUNT)
                hi = img.bytes(img.labels[f"note_{tag}_hi"], NOTE_COUNT)
                want = [sid_freq(k, clock) for k in range(NOTE_COUNT)]
                got = [lo[k] | (hi[k] << 8) for k in range(NOTE_COUNT)]
                if got != want:
                    print(f"  {tag} note table differs from the formula")
                    ok = False
        for ntsc, tag in ((0, "PAL"), (1, "NTSC")):
            secs = tick_seconds(TOTAL_TICKS, hdr["period_words"], ntsc)
            ideal = (TEMPO_EVENT_TICK / 8 * 60 / tm[0]["bpm"]) + ((TOTAL_TICKS - TEMPO_EVENT_TICK) / 8 * 60 / tm[1]["bpm"])
            if abs(secs - ideal) > 0.2:
                print(f"  {prefix}: {tag} song length {secs:.3f}s vs ideal {ideal:.3f}s")
                ok = False
        print(f"{prefix}: {mism} mismatches, {len(decoded)} events decoded ({len(expected)} expected), "
              f"3 x {BLOCKS} blocks of {BLOCK_TICKS} ticks, "
              f"PAL {tick_seconds(TOTAL_TICKS, hdr['period_words'], 0):.2f}s / "
              f"NTSC {tick_seconds(TOTAL_TICKS, hdr['period_words'], 1):.2f}s")
        ok = ok and mism == 0
    print("CHECK OK" if ok else "CHECK FAILED")
    return 0 if ok else 1


def cmd_dump(song_no, out_dir):
    events, hdr = load_generated(song_no, out_dir)
    pw = hdr["period_words"]
    print("# tick  v inst       tones            gate   PAL_s     NTSC_s")
    for e in events:
        names = " ".join(note_name(t) for t in e.tones)
        leg = " legato" if e.legato else ""
        print(f"{e.tick:5d}  {e.voice + 1} {INST_NAMES[e.inst]:10s} {names:16s} {e.gate:4d}  "
              f"{tick_seconds(e.tick, pw, 0):8.3f}  {tick_seconds(e.tick, pw, 1):8.3f}{leg}")
    print(f"# end tick {TOTAL_TICKS}: PAL {tick_seconds(TOTAL_TICKS, pw, 0):.3f}s, "
          f"NTSC {tick_seconds(TOTAL_TICKS, pw, 1):.3f}s")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--dump", type=int, choices=(1, 2))
    ap.add_argument("--score-dir", default=os.path.expanduser("~/taiso/score"))
    ap.add_argument("--out-dir", default=os.path.join(ROOT, "src"))
    a = ap.parse_args(argv)
    if a.check:
        return cmd_check(a.score_dir, a.out_dir)
    if a.dump:
        cmd_dump(a.dump, a.out_dir)
        return 0
    cmd_generate(a.score_dir, a.out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
