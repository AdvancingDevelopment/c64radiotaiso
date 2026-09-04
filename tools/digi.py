#!/usr/bin/env python3
"""digi.py -- build the digitised voice for Radio Taiso 64.

Every spoken word is synthesised with macOS `say` (voice Kyoko, ja_JP), or
taken from assets/voice/<name>.wav when such a file exists (a user recording
overrides the synthetic word), then converted with ffmpeg to mono unsigned
8-bit at the playback rate (default 5000 Hz) and processed here:

    trim leading/trailing silence  ->  shrink long internal gaps
    ->  pre-emphasis  ->  soft-clip drive + peak normalisation
    ->  4-bit quantisation with error-diffusion dithering
    ->  two samples per byte, low nibble first

The player (src/digi.asm) writes each nibble into the SID master volume
register from a CIA2 timer NMI, so a nibble is a volume level 0..15.

Outputs (all deterministic, `python3 tools/digi.py` regenerates everything):
    src/gen_digi.asm      staged part, assembled inside !pseudopc $E000 { }
                          (only !byte data + labels), <= 4608 bytes
    src/gen_digi2.asm     data-segment part: the word tables + remaining words
    build/voice/*.aiff    cached `say` output (with a .txt sidecar recording
                          voice / rate / text, so changed words regenerate)
    build/voice/preview.wav   the 4-bit signal, 22050 Hz, for human listening
    build/voice/words.json    per-word metadata (used by the tests)

Test helpers for a VICE run of the -DTEST_PLAY=1 -DTEST_DIGI=1 build
(see assets/voice/README.md):
    --check-dump build/d.dump   exact $d418 write stream vs the assembled data
    --check-wav  build/d.wav    bursts, durations, envelopes, clipping, level

Requires only the Python standard library plus the `say` and `ffmpeg` CLIs.
"""
import argparse
import json
import math
import os
import re
import struct
import subprocess
import sys
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VOICE_DIR = os.path.join(ROOT, "build", "voice")
ASSET_DIR = os.path.join(ROOT, "assets", "voice")

PAL_CLOCK = 985248
NTSC_CLOCK = 1022727
STAGE_LIMIT = 4608          # $3600-$47FF, copied to $E000 at boot
DATA_LIMIT_DEFAULT = 6144   # our share of the data segment (tables included)
COUNT_MAX_SEC = 0.42        # one beat at 120 % tempo

# ---------------------------------------------------------------------------
# word list
# ---------------------------------------------------------------------------
# Public word indices (digi_play argument, see src/digi.asm / play.asm):
#   0..7 ichi..hachi, 8 title1, 9 title2, 10 sutte, 11 haite, 12 otsukare.
# Sample slots 0..12 hold the first sample of each public word; slot 13/14
# hold the second half of the split titles (chained by the player).
#
# (name, text, say rate wpm, priority)   lower priority number = keep first
COUNTS = [
    ("ichi",   "いち", 280, 0),
    ("ni",     "に",   280, 0),
    ("san",    "さん", 280, 0),
    ("shi",    "し",   280, 0),
    ("go",     "ご",   280, 0),
    ("roku",   "ろく", 280, 0),
    ("shichi", "しち", 280, 0),
    ("hachi",  "はち", 280, 0),
]
RADIOTAISO = ("radiotaiso", "ラジオ体操", 300, 1)
DAIICHI = ("daiichi", "第一", 300, 1)
DAINI = ("daini", "第二", 300, 2)
TITLE1 = ("title1", "ラジオ体操第一", 300, 1)
TITLE2 = ("title2", "ラジオ体操第二", 300, 2)
SUTTE = ("sutte", "吸って", 300, 3)
HAITE = ("haite", "吐いて", 300, 3)
OTSUKARE = ("otsukare", "お疲れさまでした", 300, 4)

PUBLIC_NAMES = ["ichi", "ni", "san", "shi", "go", "roku", "shichi", "hachi",
                "title1", "title2", "sutte", "haite", "otsukare"]


def build_word_list(split_title):
    """Return (samples, first, chain): samples = list of (name, text, rate,
    prio); first[i] / chain[i] = sample slot indices for public word i."""
    if split_title:
        samples = COUNTS + [RADIOTAISO, RADIOTAISO, SUTTE, HAITE, OTSUKARE,
                            DAIICHI, DAINI]
        chain = [None] * 8 + [13, 14, None, None, None, None, None]
    else:
        samples = COUNTS + [TITLE1, TITLE2, SUTTE, HAITE, OTSUKARE]
        chain = [None] * 13
    return samples, chain


# ---------------------------------------------------------------------------
# audio helpers (pure python, floats in [-1, 1))
# ---------------------------------------------------------------------------
def run(cmd):
    return subprocess.run(cmd, check=True, capture_output=True)


def synthesize(name, text, rate, voice):
    """Return the path of the source audio for a word: the user's WAV in
    assets/voice if present, else a cached `say` rendering."""
    user = os.path.join(ASSET_DIR, name + ".wav")
    if os.path.exists(user):
        return user, "recorded"
    os.makedirs(VOICE_DIR, exist_ok=True)
    aiff = os.path.join(VOICE_DIR, name + ".aiff")
    stamp = aiff + ".txt"
    key = "%s|%d|%s\n" % (voice, rate, text)
    if not (os.path.exists(aiff) and os.path.exists(stamp)
            and open(stamp, encoding="utf-8").read() == key):
        run(["say", "-v", voice, "-r", str(rate), "-o", aiff, text])
        with open(stamp, "w", encoding="utf-8") as f:
            f.write(key)
    return aiff, "say"


def load_u8(path, sample_rate):
    """ffmpeg -> mono unsigned 8-bit at sample_rate, as floats."""
    out = run(["ffmpeg", "-v", "error", "-y", "-i", path, "-ar",
               str(sample_rate), "-ac", "1", "-f", "u8", "-"]).stdout
    return [(b - 128) / 128.0 for b in out]


def envelope(x, win):
    """Peak envelope over a centred window of `win` samples."""
    n = len(x)
    a = [abs(v) for v in x]
    env = [0.0] * n
    h = win // 2
    # running max via a simple deque-free approach (words are short)
    for i in range(n):
        lo = max(0, i - h)
        hi = min(n, i + h + 1)
        env[i] = max(a[lo:hi])
    return env


def trim_and_gaps(x, sr, trim_db, max_gap_s, pad_s):
    """Cut leading/trailing silence (relative threshold), keep `pad_s` of
    context, and shorten every internal silent run to `max_gap_s`."""
    peak = max(abs(v) for v in x) or 1.0
    thr = peak * (10 ** (trim_db / 20.0))
    env = envelope(x, max(1, int(sr * 0.005)))
    n = len(x)
    start = 0
    while start < n and env[start] < thr:
        start += 1
    end = n
    while end > start and env[end - 1] < thr:
        end -= 1
    if start >= end:
        return [], 0
    pad = int(sr * pad_s)
    start = max(0, start - pad)
    end = min(n, end + pad)
    x = x[start:end]
    env = env[start:end]
    # internal gaps
    max_gap = int(sr * max_gap_s)
    out = []
    removed = 0
    i = 0
    n = len(x)
    while i < n:
        if env[i] >= thr:
            out.append(x[i])
            i += 1
            continue
        j = i
        while j < n and env[j] < thr:
            j += 1
        run_len = j - i
        if run_len > max_gap:
            keep = max_gap // 2
            out.extend(x[i:i + keep])
            out.extend(x[j - (max_gap - keep):j])
            removed += run_len - max_gap
        else:
            out.extend(x[i:j])
        i = j
    return out, removed


def fade_edges(x, sr, ms):
    n = min(len(x) // 2, int(sr * ms / 1000.0))
    for i in range(n):
        g = i / float(n)
        x[i] *= g
        x[-1 - i] *= g
    return x


def preemphasis(x, a):
    if a <= 0:
        return x
    y = [x[0]]
    for i in range(1, len(x)):
        y.append(x[i] - a * x[i - 1])
    return y


def drive_normalise(x, drive):
    """Soft-clip (tanh) drive, then normalise the peak to 1.0."""
    peak = max(abs(v) for v in x) or 1.0
    x = [v / peak for v in x]
    if drive > 1.0:
        k = math.tanh(drive)
        x = [math.tanh(drive * v) / k for v in x]
    return x


def quantise(x, top_half):
    """4-bit error-diffusion quantisation -> list of nibbles 0..15.
    top_half: 3-bit levels mapped to 8..15 (music never fully ducks)."""
    levels = 7 if top_half else 15
    base = 8 if top_half else 0
    half = levels / 2.0
    out = []
    err = 0.0
    for v in x:
        q = (v + 1.0) * half + err
        n = int(math.floor(q + 0.5))
        if n < 0:
            n = 0
        elif n > levels:
            n = levels
        err = q - n
        # keep the diffused error bounded (silence limit cycles)
        if err > 1.0:
            err = 1.0
        elif err < -1.0:
            err = -1.0
        out.append(base + n)
    return out


def add_ramps(nibbles, sr, ramp_ms, top_half):
    """Prepend a ramp from volume 15 (the music's level) down to the word's
    mid level, and append the mirror image, so the DC step of the volume
    register does not click on a 6581."""
    mid = 12 if top_half else 8
    n = max(2, int(sr * ramp_ms / 1000.0))
    head = [int(round(15 - (15 - mid) * i / (n - 1))) for i in range(n)]
    tail = list(reversed(head))
    return head + nibbles + tail


def pack(nibbles):
    if len(nibbles) & 1:
        nibbles = nibbles + [nibbles[-1]]
    return bytes((nibbles[i] & 15) | ((nibbles[i + 1] & 15) << 4)
                 for i in range(0, len(nibbles), 2))


# ---------------------------------------------------------------------------
# placement
# ---------------------------------------------------------------------------
def best_stage_subset(items, cap):
    """Subset-sum: choose the items (index, size) whose sizes fill `cap`
    best. DP over bytes; 15 items x 4608 is nothing."""
    best = [None] * (cap + 1)   # best[s] = tuple of item indices reaching s
    best[0] = ()
    for idx, size in items:
        if size <= 0:
            continue
        for s in range(cap, size - 1, -1):
            if best[s] is None and best[s - size] is not None:
                best[s] = best[s - size] + (idx,)
    for s in range(cap, -1, -1):
        if best[s] is not None:
            return set(best[s]), s
    return set(), 0


def fit(sizes, prios, stage_cap, data_cap):
    """Greedily keep words by priority while the two bins can hold them.
    Returns (kept set, staged set)."""
    order = sorted(range(len(sizes)), key=lambda i: (prios[i], i))
    kept = set()
    staged = set()
    for i in order:
        trial = kept | {i}
        items = [(j, sizes[j]) for j in sorted(trial)]
        st, used = best_stage_subset(items, stage_cap)
        rest = sum(sizes[j] for j in trial if j not in st)
        if rest <= data_cap:
            kept, staged = trial, st
        elif prios[i] <= 2:
            sys.exit("digi.py: mandatory word %d does not fit (stage %d, "
                     "data %d)" % (i, stage_cap, data_cap))
        else:
            print("digi.py: dropping word slot %d (no room)" % i)
    return kept, staged


# ---------------------------------------------------------------------------
# emitters
# ---------------------------------------------------------------------------
def emit_bytes(f, label, data, comment):
    f.write("%s:%s\n" % (label, comment))
    for i in range(0, len(data), 24):
        chunk = data[i:i + 24]
        f.write("        !byte " + ",".join("$%02x" % b for b in chunk) + "\n")


def write_wav(path, samples, sr):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32000))
                               for v in samples))


def render_preview(nibbles_list, sr, out_sr, gap_s):
    """Zero-order-hold rendering of the nibble streams at out_sr (what the
    SID master volume does), words separated by silence at level 15."""
    out = []
    gap = [0.0] * int(out_sr * gap_s)

    def level(n):
        return (n - 7.5) / 7.5 * 0.8

    for nibs in nibbles_list:
        t = 0.0
        step = sr / float(out_sr)
        i = 0
        pos = 0.0
        while i < len(nibs):
            out.append(level(nibs[i]))
            pos += step
            i = int(pos)
        out.extend(gap)
    return out


# ---------------------------------------------------------------------------
# verification of a VICE run of the -DTEST_PLAY=1 -DTEST_DIGI=1 build, which
# plays public words 0..12 once, one every 64 frames:
#   --check-dump build/d.dump   x64sc -sounddev dump -soundarg build/d.dump
#       exact check of the $d418 write stream against the assembled bytes
#       (nibble order, chaining, end-of-word restore, timer period)
#   --check-wav build/d.wav     x64sc -soundrecdev wav -soundrecarg build/d.wav
#       speech bursts at the expected times, durations, envelope match,
#       clipping and loudness
# ---------------------------------------------------------------------------
PAL_FRAME = 63 * 312
NTSC_FRAME = 65 * 263
TEST_INTERVAL = 64              # frames between words in the test build


def parse_asm_words():
    """Read the sample bytes back from src/gen_digi*.asm, per label."""
    words = {}
    for fn in ("gen_digi.asm", "gen_digi2.asm"):
        cur = None
        for line in open(os.path.join(ROOT, "src", fn), encoding="utf-8"):
            m = re.match(r"digi_smp_(\w+):", line)
            if m:
                cur = m.group(1)
                words[cur] = bytearray()
                continue
            if not line[:1].isspace():
                cur = None              # another label ends the block
            m = re.match(r"\s*!byte\s+(.*)", line)
            if m and cur is not None:
                words[cur].extend(int(t.strip()[1:], 16) for t in m.group(1).split(","))
    return words


def expected_sequence():
    """[(public word, name(s), bytes)] for the 13 public words, chains
    resolved, from words.json + the generated asm."""
    meta = json.load(open(os.path.join(VOICE_DIR, "words.json"), encoding="utf-8"))
    words = parse_asm_words()
    seq = []
    for k in range(13):
        names = [meta["slots"][k]]
        c = meta["chain"][k]
        if c is not None:
            names.append(meta["slots"][c])
        data = b"".join(bytes(words.get(n, b"")) for n in names)
        seq.append((k, "+".join(names), data))
    return meta, seq


def nibbles_of(data):
    out = []
    for b in data:
        out.append(b & 15)
        out.append(b >> 4)
    return out


def check_dump(path):
    clk = 0
    writes = []
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.split()
        if len(parts) < 3:
            continue
        clk += int(parts[0])
        if int(parts[1]) == 0x18:
            writes.append((clk, int(parts[2])))
    meta, seq = expected_sequence()
    rate = meta["rate"]
    i = 0
    while i < len(writes) and writes[i][1] == 0:
        i += 1                          # SID clear at boot
    if i >= len(writes):
        sys.exit("check-dump: no playback writes found")
    hi = writes[i][1] & 0xf0
    ok = True
    starts = []
    print("dump: %d writes to $d418, filter bits $%02x" % (len(writes), hi))
    period = None
    for k, name, data in seq:
        nibs = nibbles_of(data)
        if not nibs:
            print("word %2d %-20s dropped (no data)" % (k, name))
            continue
        if i + len(nibs) >= len(writes):
            print("word %2d %-20s MISSING (dump ends early)" % (k, name))
            ok = False
            break
        start = writes[i][0]
        starts.append(start)
        bad = 0
        deltas = []
        for j, n in enumerate(nibs):
            c, v = writes[i + j]
            if v != (n | hi):
                bad += 1
            if j:
                deltas.append(c - writes[i + j - 1][0])
        restore = writes[i + len(nibs)][1]
        i += len(nibs) + 1
        dmin, dmax = min(deltas), max(deltas)
        mean = sum(deltas) / len(deltas)
        if period is None:
            period = int(round(mean))
        # the write times jitter by up to a badline (the VIC halts the CPU
        # for ~43 cycles) plus the NMI latency; the timer itself is exact,
        # so the mean must be the nominal period and no gap may exceed it
        # by more than that
        line = ("word %2d %-20s %5d samples  period %6.2f (%3d..%3d) cycles  restore $%02x"
                % (k, name, len(nibs), mean, dmin, dmax, restore))
        if bad or abs(mean - period) > 0.5 or dmax - dmin > 110 or (restore & 0xf0) != hi:
            ok = False
            line += "  <-- %d wrong nibbles" % bad if bad else "  <-- timing"
        print(line)
    if period is not None:
        std = "PAL" if abs(PAL_CLOCK / rate - period) < 2 else \
              ("NTSC" if abs(NTSC_CLOCK / rate - period) < 2 else "??")
        if std == "??":
            ok = False
        frame = PAL_FRAME if std == "PAL" else NTSC_FRAME
        print("sample period %d cycles = %.1f Hz on %s (badline jitter tolerated)"
              % (period, (PAL_CLOCK if std == "PAL" else NTSC_CLOCK) / period, std))
        gaps = [(b - a) / frame for a, b in zip(starts, starts[1:])]
        if gaps:
            print("word spacing: %.2f..%.2f frames (expected %d)" % (min(gaps), max(gaps), TEST_INTERVAL))
            if any(abs(g - TEST_INTERVAL) > 1.0 for g in gaps):
                ok = False
    if i < len(writes):
        extra = writes[i:]
        print("%d further writes after the last word (first: $%02x)" % (len(extra), extra[0][1]))
    print("check-dump: " + ("OK" if ok else "FAILED"))
    return ok


def read_wav_mono(path):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        n = w.getnframes()
        raw = w.readframes(n)
    if w.getsampwidth() != 2:
        sys.exit("check-wav: 16-bit WAV expected")
    s = struct.unpack("<%dh" % (n * ch), raw)[::ch]
    return sr, s


def rms_env(x, win):
    return [math.sqrt(sum(v * v for v in x[i:i + win]) / max(1, len(x[i:i + win])))
            for i in range(0, len(x), win)]


def pearson(a, b):
    n = min(len(a), len(b))
    if n < 4:
        return 0.0
    a, b = a[:n], b[:n]
    ma, mb = sum(a) / n, sum(b) / n
    sa = math.sqrt(sum((v - ma) ** 2 for v in a)) or 1e-9
    sb = math.sqrt(sum((v - mb) ** 2 for v in b)) or 1e-9
    return sum((p - ma) * (q - mb) for p, q in zip(a, b)) / (sa * sb)


def check_wav(path):
    sr, s = read_wav_mono(path)
    meta, seq = expected_sequence()
    rate = meta["rate"]
    peak = max(abs(v) for v in s) or 1
    clipped = sum(1 for v in s if abs(v) >= 32000)
    win = sr // 200                                 # 5 ms
    env = rms_env(s, win)
    thr = max(env) * 10 ** (-40 / 20.0)
    active = [e >= thr for e in env]
    print("wav: %s  %.1f s  peak %d (%.1f dBFS)  clipped samples %d"
          % (os.path.basename(path), len(s) / sr, peak,
             20 * math.log10(peak / 32768.0), clipped))
    ok = clipped == 0
    try:
        first = active.index(True)
    except ValueError:
        print("check-wav: FAILED (silent file)")
        return False
    t0 = first * win / sr
    # PAL or NTSC: the second word must start one test interval later
    pal = TEST_INTERVAL * PAL_FRAME / PAL_CLOCK
    ntsc = TEST_INTERVAL * NTSC_FRAME / NTSC_CLOCK

    def onset(t_from, t_to):
        a = int(t_from * sr / win)
        b = int(t_to * sr / win)
        for w in range(max(0, a), min(len(active), b)):
            if active[w]:
                return w * win / sr
        return None

    first_len = len(seq[0][2]) * 2 / rate
    cands = [(std, step) for std, step in (("PAL", pal), ("NTSC", ntsc))
             if onset(t0 + step - 0.03, t0 + step + 0.06) is not None]
    if not cands:
        print("check-wav: FAILED (second word not found at a PAL or NTSC interval)")
        return False
    std, step = cands[0]
    print("first word at %.3f s, second at the %s interval (%.3f s)" % (t0, std, step))
    win10 = sr // 100                               # 10 ms windows for envelopes
    # every word is judged at its scheduled slot: onset near t_exp, energy
    # until roughly t_exp + duration, silence before the next slot
    for k, name, data in seq:
        if not data:
            continue
        t_exp = t0 + k * step
        exp_dur = len(data) * 2 / rate
        # (search from just before the slot: on NTSC the previous word's
        # decaying tail can still be above threshold 30 ms earlier)
        on = onset(t_exp - 0.01, t_exp + 0.08)
        if on is None:
            print("word %2d %-20s MISSING near %.3f s  <--" % (k, name, t_exp))
            ok = False
            continue
        # last active window before the next slot (minus a little headroom)
        limit = min(len(active), int((t_exp + step - 0.02) * sr / win))
        w_on = int(on * sr / win)
        last = w_on
        for w in range(w_on, limit):
            if active[w]:
                last = w
        dur = (last + 1 - w_on) * win / sr
        # silence between this word and the next slot
        tail_from = int((on + exp_dur + 0.12) * sr / win)
        gap_env = env[tail_from:limit]
        gap_db = None
        if gap_env:
            gap_db = 20 * math.log10(max(max(gap_env), 1e-3) / max(env))
        # envelope of the first-difference (high-passed) signal, capture vs
        # reference, best alignment within +-40 ms
        a = int(on * sr)
        b = min(len(s), int((on + exp_dur + 0.05) * sr))
        cap = [s[n] - s[n - 1] for n in range(a + 1, b)]
        cap_env = rms_env(cap, win10)
        ref_sig = nibbles_of(data)
        ref = [ref_sig[n] - ref_sig[n - 1] for n in range(1, len(ref_sig))]
        ref_env = rms_env(ref, rate // 100)
        corr = max(pearson(cap_env[lag:], ref_env) for lag in range(0, 5))
        seg_peak = max(abs(v) for v in s[a:b]) or 1
        flag = ""
        if (abs(on - t_exp) > 0.06 or abs(dur - exp_dur) > 0.12 or corr < 0.6
                or (gap_db is not None and gap_db > -40)):
            flag = "  <--"
            ok = False
        print("word %2d %-20s at %6.3f s (exp %6.3f)  %.3f s (exp %.3f)  peak %5.1f dBFS  "
              "env corr %.2f  gap %s%s"
              % (k, name, on, t_exp, dur, exp_dur, 20 * math.log10(seg_peak / 32768.0),
                 corr, ("%.0f dB" % gap_db) if gap_db is not None else "n/a", flag))
    print("check-wav: " + ("OK" if ok else "FAILED"))
    return ok


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check-dump", metavar="FILE",
                    help="verify a VICE SID register dump of the TEST_DIGI build")
    ap.add_argument("--check-wav", metavar="FILE",
                    help="verify a VICE WAV capture of the TEST_DIGI build")
    ap.add_argument("--rate", type=int, default=5000, help="sample rate (Hz)")
    ap.add_argument("--voice", default="Kyoko", help="`say` voice")
    ap.add_argument("--say-rate", type=int, default=0,
                    help="override every word's speaking rate (wpm)")
    ap.add_argument("--trim-db", type=float, default=-36.0,
                    help="silence threshold relative to the peak")
    ap.add_argument("--max-gap", type=float, default=0.08,
                    help="longest internal silence kept (s)")
    ap.add_argument("--pad", type=float, default=0.004,
                    help="context kept around the trimmed word (s)")
    ap.add_argument("--preemph", type=float, default=0.5,
                    help="pre-emphasis coefficient (0 = off)")
    ap.add_argument("--drive", type=float, default=2.0,
                    help="tanh soft-clip drive before normalising (1 = off)")
    ap.add_argument("--ramp-ms", type=float, default=3.0,
                    help="volume ramp 15->mid at both ends (ms)")
    ap.add_argument("--top-half", action="store_true",
                    help="3-bit samples in nibbles 8..15 (music never fully ducks)")
    ap.add_argument("--no-split-title", action="store_true",
                    help="store the full title phrases instead of sharing ラジオ体操")
    ap.add_argument("--data-limit", type=int, default=DATA_LIMIT_DEFAULT,
                    help="bytes allowed in gen_digi2.asm (tables included)")
    ap.add_argument("--no-count-check", action="store_true",
                    help="do not fail when a count is longer than 0.42 s")
    args = ap.parse_args()

    if args.check_dump or args.check_wav:
        good = True
        if args.check_dump:
            good &= check_dump(args.check_dump)
        if args.check_wav:
            good &= check_wav(args.check_wav)
        sys.exit(0 if good else 1)

    sr = args.rate
    samples, chain = build_word_list(not args.no_split_title)
    names = [s[0] for s in samples]

    # --- render every distinct sample once -------------------------------
    rendered = {}
    for name, text, say_rate, prio in samples:
        if name in rendered:
            continue
        if args.say_rate:
            say_rate = args.say_rate
        src, origin = synthesize(name, text, say_rate, args.voice)
        x = load_u8(src, sr)
        dc = sum(x) / max(1, len(x))
        x = [v - dc for v in x]
        raw_len = len(x)
        x, removed = trim_and_gaps(x, sr, args.trim_db, args.max_gap, args.pad)
        if not x:
            sys.exit("digi.py: %s is silent" % name)
        x = fade_edges(x, sr, 2.0)
        x = preemphasis(x, args.preemph)
        x = drive_normalise(x, args.drive)
        nib = quantise(x, args.top_half)
        nib = add_ramps(nib, sr, args.ramp_ms, args.top_half)
        data = pack(nib)
        rendered[name] = {
            "name": name, "text": text, "origin": origin, "say_rate": say_rate,
            "raw_sec": raw_len / sr, "sec": len(nib) / sr,
            "gap_removed_sec": removed / sr, "bytes": len(data),
            "data": data, "nibbles": nib,
        }

    # --- count-length check ----------------------------------------------
    for name, _, _, _ in COUNTS:
        d = rendered[name]["sec"]
        if d > COUNT_MAX_SEC and not args.no_count_check:
            sys.exit("digi.py: count %s is %.3f s > %.2f s (raise its say "
                     "rate or record a shorter word)" % (name, d, COUNT_MAX_SEC))

    # --- placement -------------------------------------------------------
    distinct = list(rendered.keys())
    sizes = [rendered[n]["bytes"] for n in distinct]
    prio = {}
    for name, _, _, p in samples:
        prio[name] = min(p, prio.get(name, 99))
    prios = [prio[n] for n in distinct]
    nslots = len(samples)
    table_bytes = 5 * nslots + 4 + 2       # word/len/chain tables, periods, count
    kept_idx, staged_idx = fit(sizes, prios, STAGE_LIMIT,
                               args.data_limit - table_bytes)
    kept = {distinct[i] for i in kept_idx}
    staged = {distinct[i] for i in staged_idx}

    # deterministic order: staged words by slot order, then data words
    def slot_order(name):
        return names.index(name)
    stage_list = sorted(staged, key=slot_order)
    data_list = sorted(kept - staged, key=slot_order)

    # --- gen_digi.asm (staged, !pseudopc $E000) --------------------------
    stage_used = sum(rendered[n]["bytes"] for n in stage_list)
    data_used = sum(rendered[n]["bytes"] for n in data_list) + table_bytes
    with open(os.path.join(ROOT, "src", "gen_digi.asm"), "w", encoding="utf-8") as f:
        f.write("; gen_digi.asm -- GENERATED by tools/digi.py, do not edit.\n")
        f.write("; Digitised voice, part 1 (staged: assembled inside !pseudopc "
                "$e000, copied there at boot).\n")
        f.write("; 4-bit PCM at %d Hz, two samples per byte, low nibble first.\n"
                % sr)
        f.write("; %d of %d bytes used.\n" % (stage_used, STAGE_LIMIT))
        for n in stage_list:
            r = rendered[n]
            emit_bytes(f, "digi_smp_" + n, r["data"],
                       "        ; %s %d bytes, %.3f s" % (r["text"], r["bytes"], r["sec"]))
        f.write("digi_stage_end:\n")

    # --- gen_digi2.asm (data segment: tables + the rest) ------------------
    pal = int(round(PAL_CLOCK / sr)) - 1
    ntsc = int(round(NTSC_CLOCK / sr)) - 1
    with open(os.path.join(ROOT, "src", "gen_digi2.asm"), "w", encoding="utf-8") as f:
        f.write("; gen_digi2.asm -- GENERATED by tools/digi.py, do not edit.\n")
        f.write("; Digitised voice, part 2: word tables + the words that did not "
                "fit the staged block.\n")
        f.write("; %d bytes (limit %d). Sample rate %d Hz -> CIA timer latch "
                "PAL %d, NTSC %d.\n" % (data_used, args.data_limit, sr, pal, ntsc))
        f.write("DIGI_RATE = %d\n" % sr)
        f.write("DIGI_SLOTS = %d\n" % nslots)
        f.write("digi_period_lo: !byte <%d, <%d      ; PAL, NTSC\n" % (pal, ntsc))
        f.write("digi_period_hi: !byte >%d, >%d\n" % (pal, ntsc))
        f.write("digi_slots:     !byte %d\n" % nslots)
        f.write("digi_top_half:  !byte %d\n" % (1 if args.top_half else 0))

        def ref(name):
            return ("digi_smp_" + name) if name in kept else "digi_stage_end"

        def length(name):
            return rendered[name]["bytes"] if name in kept else 0

        f.write("; slot: 0-7 ichi..hachi, 8 title1, 9 title2, 10 sutte, 11 haite,"
                " 12 otsukare" + (", 13/14 title tails" if nslots > 13 else "") + "\n")
        f.write("digi_word_lo:   !byte " + ",".join("<" + ref(n) for n in names) + "\n")
        f.write("digi_word_hi:   !byte " + ",".join(">" + ref(n) for n in names) + "\n")
        f.write("digi_len_lo:    !byte " + ",".join("<%d" % length(n) for n in names) + "\n")
        f.write("digi_len_hi:    !byte " + ",".join(">%d" % length(n) for n in names) + "\n")
        f.write("digi_chain:     !byte " + ",".join(
            "$ff" if c is None or names[c] not in kept else "%d" % c for c in chain) + "\n")
        for n in data_list:
            r = rendered[n]
            emit_bytes(f, "digi_smp_" + n, r["data"],
                       "        ; %s %d bytes, %.3f s" % (r["text"], r["bytes"], r["sec"]))
        f.write("digi_data_end:\n")

    # --- preview + metadata ----------------------------------------------
    os.makedirs(VOICE_DIR, exist_ok=True)
    order = [n for n in distinct if n in kept]
    write_wav(os.path.join(VOICE_DIR, "preview.wav"),
              render_preview([rendered[n]["nibbles"] for n in order], sr, 22050, 0.3),
              22050)
    meta = {"rate": sr, "top_half": args.top_half, "slots": names,
            "chain": chain, "stage_bytes": stage_used, "data_bytes": data_used,
            "words": []}
    for n in distinct:
        r = rendered[n]
        meta["words"].append({k: r[k] for k in ("name", "text", "origin", "say_rate",
                                                 "raw_sec", "sec", "gap_removed_sec",
                                                 "bytes")}
                             | {"kept": n in kept,
                                "where": "stage" if n in staged else
                                ("data" if n in kept else "dropped")})
    with open(os.path.join(VOICE_DIR, "words.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=1, ensure_ascii=False)
    with open(os.path.join(VOICE_DIR, "preview_order.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(order) + "\n")

    # --- report ----------------------------------------------------------
    print("%-11s %-16s %-8s %5s %7s %7s %6s  %s" %
          ("word", "text", "source", "wpm", "raw s", "kept s", "bytes", "where"))
    for w in meta["words"]:
        print("%-11s %-16s %-8s %5d %7.3f %7.3f %6d  %s" %
              (w["name"], w["text"], w["origin"], w["say_rate"], w["raw_sec"],
               w["sec"], w["bytes"], w["where"]))
    print("staged: %d / %d bytes   data: %d / %d bytes (tables %d)   total %d"
          % (stage_used, STAGE_LIMIT, data_used, args.data_limit, table_bytes,
             stage_used + data_used))


if __name__ == "__main__":
    main()
