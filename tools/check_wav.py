#!/usr/bin/env python3
"""check_wav.py — verify a VICE audio capture of the Radio Taiso 64 music.

  python3 tools/check_wav.py build/s1.wav --song 1 [--ntsc] [--start-tick N] [-v]

Capture (real time, no warp; the recorder only gets what the playback device gets, so
the volume must be > 0 and VICE's display vsync should be off):
  acme -DTEST_PLAY=1 --format cbm --outfile build/auto1.prg src/main.asm
  x64sc -default +confirmonexit +VICIIvsync -autostartprgmode 1 -sounddev coreaudio \
        -soundvolume 3 -soundrecdev wav -soundrecarg build/s1.wav -soundoutput 1 \
        -soundrate 44100 -limitcycles 40000000 [-ntsc] build/auto1.prg
(exit code 1 at the cycle limit is normal). The WAV is analysed with Goertzel filters
(stdlib only):
  1. the first sound in the file locates the start of the music; the first "clean"
     melody note after --start-tick is the timing anchor (its measured onset defines
     the file time of tick 0);
  2. melody / bass probe notes spread over the capture (only notes no other voice masks
     with a tone or harmonic within 250 cents): the expected pitch (from the generated
     song data via tools/songconv.py) must be >= 12 dB above its +-1 semitone neighbours,
     and the measured onset within +-30 ms of the expected time. Expected times come from
     the clock's exact frame arithmetic (period words, tempo event, TEST_TICK jump), so
     this validates the tempo on PAL and NTSC to the frame;
  3. the long calm-section chords (voice 3 arpeggio): every chord tone present.
Exit status 1 on any failure. Capture on an otherwise idle machine: VICE's sound sync
stretches the sample stream when the host cannot keep real time (visible as "drift").
NTSC note: with the scaffold's irq.asm the bottom IRQ (line 251) overruns the 20-line gap
to the line-8 IRQ on heavy frames and a whole frame of IRQs is dropped (the clock slips
one frame per 128-tick block); the NTSC onset check only passes with the late-entry-0
fix in irq.asm (see the music module's report / HANDOFF).
"""
import argparse
import array
import math
import os
import sys
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import songconv  # noqa: E402

ONSET_TOL = 0.030          # s
PITCH_MARGIN_DB = 12.0
CHORD_MARGIN_DB = 6.0


def load_wav(path):
    with wave.open(path) as w:
        ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    assert sw == 2, "16-bit WAV expected"
    a = array.array("h", raw)
    if ch > 1:
        a = array.array("h", [sum(a[i:i + ch]) // ch for i in range(0, len(a), ch)])
    # normalise: captures differ wildly in level (host volume, SID model),
    # so scale the peak to a fixed value before the absolute thresholds apply
    peak = max(1, max(abs(v) for v in a))
    if abs(peak - 1200) > 200:
        k = 1200.0 / peak
        a = array.array("h", [int(v * k) for v in a])
    return a, sr


def goertzel(samples, sr, freq, start, length):
    """Power of `freq` in samples[start:start+length] (rectangular window)."""
    k = 2.0 * math.cos(2.0 * math.pi * freq / sr)
    s1 = s2 = 0.0
    end = min(start + length, len(samples))
    for i in range(max(0, start), end):
        s0 = samples[i] + k * s1 - s2
        s2, s1 = s1, s0
    n = max(1, end - max(0, start))
    return (s1 * s1 + s2 * s2 - k * s1 * s2) / (n * n) + 1e-9


def db(a, b):
    return 10.0 * math.log10(a / b)


def note_hz(idx):
    return 440.0 * 2.0 ** ((idx + songconv.NOTE_BASE - 69) / 12.0)


def sid_hz(idx, ntsc):
    """The frequency the SID actually produces (16-bit register value)."""
    clock = songconv.NTSC_CLOCK if ntsc else songconv.PAL_CLOCK
    return songconv.sid_freq(idx, clock) * clock / 16777216.0


def first_sound(samples, sr, thresh=40, hold=4):
    """Start of the first run of `hold` consecutive 10 ms blocks whose RMS
    exceeds thresh (LSB) -> seconds. The run requirement skips the one-block
    click the SID makes when the player initialises, a frame before tick 0."""
    blk = sr // 100
    run = 0
    for i in range(0, len(samples) - blk, blk):
        seg = samples[i:i + blk]
        if math.sqrt(sum(v * v for v in seg) / blk) > thresh:
            run += 1
            if run == hold:
                return (i - (hold - 1) * blk) / sr
        else:
            run = 0
    return None


def find_onset(samples, sr, freq, t_lo, t_hi, win=0.020, hop=0.001):
    """Onset of `freq` with window starts in [t_lo, t_hi]: the first window whose power
    reaches 25 % of the peak of the following 100 ms, that local peak itself being at
    least 35 % of the range's peak (so leakage floors from other voices cannot trigger,
    and a louder tone joining later cannot delay the onset) -> start + win/2."""
    n = int(win * sr)
    starts = range(int(t_lo * sr), int(t_hi * sr), max(1, int(hop * sr)))
    powers = [goertzel(samples, sr, freq, s, n) for s in starts]
    if not powers:
        return None, 0.0
    peak = max(powers)
    ahead = int(0.1 / hop)
    for i, p in enumerate(powers):
        local = max(powers[i:i + ahead])
        if local >= 0.35 * peak and p >= 0.25 * local:
            return starts[i] / sr + win / 2.0, peak
    return None, peak


def best_window(samples, sr, freq, t_lo, t_hi, win, hop=0.005):
    """Max Goertzel power of `freq` over windows of `win` seconds starting in [t_lo, t_hi]."""
    n = int(win * sr)
    return max(goertzel(samples, sr, freq, s, n)
               for s in range(int(t_lo * sr), int(t_hi * sr), max(1, int(hop * sr))))


def sounding(events, voice_set, span, started_before=None):
    """Note indices of voices in voice_set sounding anywhere in tick span (a, b);
    with started_before = t only events that begin before tick t count."""
    out = set()
    for e in events:
        if e.voice in voice_set and e.tick < span[1] and e.tick + e.gate > span[0]:
            if started_before is None or e.tick < started_before:
                out.update(e.tones)
    return out


def masked(idx, others, win=0.020):
    """True if a harmonic (1..8) of another sounding tone lies within 250 cents, or within
    1.2 / win Hz (the analysis window's resolution), of note idx."""
    f = note_hz(idx)
    for o in others:
        fo = note_hz(o)
        for h in range(1, 9):
            if abs(1200.0 * math.log2(h * fo / f)) < 250.0 or abs(h * fo - f) < 1.2 / win:
                return True
    return False


def tick_frames(period_words, ntsc, start_tick, count, tempo_level=2):
    """Frame index (0 = the frame of start_tick) of every tick, simulating clock.asm's
    8.8 accumulator exactly: clock_start / clock_test_jump prime it with 0 so the start
    tick fires on the next frame, later ticks follow the countdown; the period switches
    to segment 1 right after tick 2816 fires."""
    p0 = period_words[ntsc * 5 + tempo_level]
    p1 = period_words[10 + ntsc * 5 + tempo_level]
    per = p1 if start_tick > songconv.TEMPO_EVENT_TICK else p0
    lo = hi = 0
    tick = start_tick - 1
    frames = {}
    f = 0
    while tick < start_tick + count:
        hi = (hi - 1) & 0xFF
        if hi < 0x80:
            f += 1
            continue
        tick += 1
        frames[tick] = f
        ssum = lo + (per & 0xFF)
        lo = ssum & 0xFF
        hi = (hi + (per >> 8) + (ssum >> 8)) & 0xFF
        if tick == songconv.TEMPO_EVENT_TICK:
            per = p1
        f += 1
    return frames


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wav")
    ap.add_argument("--song", type=int, choices=(1, 2), required=True)
    ap.add_argument("--ntsc", action="store_true")
    ap.add_argument("--start-tick", type=int, default=0, help="TEST_TICK of a jump build")
    ap.add_argument("--probes", type=int, default=10)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)

    samples, sr = load_wav(a.wav)
    duration = len(samples) / sr
    events, hdr = songconv.load_generated(a.song)
    pw = hdr["period_words"]
    ntsc = 1 if a.ntsc else 0
    secs = lambda tick: songconv.tick_seconds(tick, pw, ntsc)  # noqa: E731
    start = a.start_tick
    frame_s = 1.0 / (songconv.NTSC_FRAME if ntsc else songconv.PAL_FRAME)
    fr = tick_frames(pw, ntsc, start, songconv.TOTAL_TICKS - start)

    t_sound = first_sound(samples, sr)
    if t_sound is None:
        print("FAIL: no sound in the capture")
        return 1
    # The anchor is the first clean note after the start tick (a note at the start tick
    # of a jump build is re-triggered by music_seek, not a real onset).
    anchor = None
    for e in events:
        if e.voice == 2 or e.legato or e.gate < 4 or e.tick <= start:
            continue
        others = sounding(events, {0, 1, 2} - {e.voice}, (e.tick - 2, e.tick + 2))
        if not masked(e.tones[0], others):
            anchor = e
            break
    if anchor is None:
        print("FAIL: no clean anchor note")
        return 1
    offset = fr[anchor.tick] * frame_s
    f_anchor = sid_hz(anchor.tones[0], ntsc)
    onset, _ = find_onset(samples, sr, f_anchor, t_sound + offset - 0.10, t_sound + offset + 0.20)
    if onset is None:
        print(f"FAIL: anchor note {songconv.note_name(anchor.tones[0])} (tick {anchor.tick}) not found near {t_sound + offset:.3f}s")
        return 1
    t_start = onset - offset                # file time of the start tick's frame
    expected = lambda tick: t_start + fr[tick] * frame_s  # noqa: E731
    print(f"{a.wav}: {duration:.1f}s, first sound {t_sound:.3f}s, anchor tick {anchor.tick} v{anchor.voice + 1} "
          f"{songconv.note_name(anchor.tones[0])} at {onset:.3f}s -> tick {start} at {t_start:.3f}s "
          f"({'NTSC' if ntsc else 'PAL'}, expected onsets from the clock's exact frame arithmetic)")

    # ---- probe selection: clean melody notes (+ some bass notes) spread over the file
    usable_end = duration - 0.5
    cands = []
    prev = {}
    for e in events:
        if e.tick < (anchor.tick + 1):
            prev[e.voice] = e
            continue
        t = expected(e.tick)
        if t + 0.45 > usable_end:
            break
        p = prev.get(e.voice)
        prev[e.voice] = e
        if e.voice == 2 or e.legato:
            continue
        if p is not None and abs(p.tones[0] - e.tones[0]) < 2:
            continue                                     # repeated pitch: no clean onset
        others = sounding(events, {0, 1, 2} - {e.voice}, (e.tick - 2, e.tick + e.gate))
        if masked(e.tones[0], others):
            continue
        gate_s = secs(e.tick + e.gate) - secs(e.tick)
        win = min(0.40, gate_s - 0.05)
        cycles_off = win * abs(sid_hz(e.tones[0], ntsc) * (2 ** (1 / 12) - 1))
        if cycles_off < 1.8:
            continue                                     # window too short to separate a semitone
        cands.append((e, t, win))
    mel = [c for c in cands if c[0].voice == 0]
    bas = [c for c in cands if c[0].voice == 1]
    probes = []
    if mel:
        step = max(1, len(mel) // a.probes)
        probes += mel[::step][:a.probes]
    if bas:
        nb = 4 if mel else a.probes           # calm section: the melody doubles the harp
        step = max(1, len(bas) // nb)
        probes += bas[::step][:nb]
    if not probes:
        print("FAIL: no usable probes")
        return 1
    probes.sort(key=lambda c: c[1])
    errs = []

    fails = 0
    print("  tick  v note   expected   measured    err   +1st    -1st")
    for e, t_exp, win in probes:
        f0 = sid_hz(e.tones[0], ntsc)
        onset, _ = find_onset(samples, sr, f0, t_exp - 0.12, t_exp + 0.12)
        if onset is None:
            print(f"  {e.tick:5d} {e.voice + 1} {songconv.note_name(e.tones[0]):4s} {t_exp:9.3f}   (no onset)   FAIL")
            fails += 1
            continue
        err = onset - t_exp
        errs.append((t_exp - t_start, err))
        s = int((onset + 0.02) * sr)
        n = int(win * sr)
        p0 = goertzel(samples, sr, f0, s, n)
        up = db(p0, goertzel(samples, sr, f0 * 2 ** (1 / 12), s, n))
        dn = db(p0, goertzel(samples, sr, f0 / 2 ** (1 / 12), s, n))
        ok = abs(err) <= ONSET_TOL and up >= PITCH_MARGIN_DB and dn >= PITCH_MARGIN_DB
        fails += 0 if ok else 1
        print(f"  {e.tick:5d} {e.voice + 1} {songconv.note_name(e.tones[0]):4s} {t_exp:9.3f} {onset:9.3f} {err * 1000:+6.1f}ms "
              f"{up:6.1f} {dn:6.1f}  {'ok' if ok else 'FAIL'}")

    if len(errs) >= 4:                       # timing drift (VICE sound sync / tempo)
        n = len(errs)
        mx = sum(t for t, _ in errs) / n
        me = sum(e for _, e in errs) / n
        sxx = sum((t - mx) ** 2 for t, _ in errs)
        slope = sum((t - mx) * (e - me) for t, e in errs) / sxx if sxx else 0.0
        print(f"  onset error: mean {me * 1000:+.1f} ms, drift {slope * 1e6:+.0f} ppm over {errs[-1][0] - errs[0][0]:.1f} s")

    # ---- calm chords (voice 3 arpeggio, gate >= 24 ticks): every tone present
    chords = [e for e in events if e.voice == 2 and e.gate >= 24 and e.tick > anchor.tick
              and expected(e.tick + e.gate) < usable_end]
    # The arpeggio plays each tone for 4 frames, and every return restarts the SID
    # oscillator at an arbitrary phase, so a long window sees sidebands rather than the
    # carrier: measure with one-segment windows and keep the best-aligned one.
    seg = 4 * frame_s - 0.005
    for e in chords[:4]:
        t_lo = expected(e.tick) + 0.15
        t_hi = t_lo + 3 * 4 * frame_s + 0.05          # one full arpeggio cycle
        res = []
        ok = True
        for tone in e.tones:
            f = sid_hz(tone, ntsc)
            p0 = best_window(samples, sr, f, t_lo, t_hi, seg)
            m = min(db(p0, best_window(samples, sr, f * 2 ** (1 / 12), t_lo, t_hi, seg)),
                    db(p0, best_window(samples, sr, f / 2 ** (1 / 12), t_lo, t_hi, seg)))
            res.append(f"{songconv.note_name(tone)} {m:+.1f}dB")
            ok = ok and m >= CHORD_MARGIN_DB
        fails += 0 if ok else 1
        print(f"  chord tick {e.tick} ({songconv.INST_NAMES[e.inst]}): {', '.join(res)}  {'ok' if ok else 'FAIL'}")

    print(f"{'OK' if fails == 0 else 'FAIL'}: {len(probes)} probes, {min(4, len(chords))} chords, {fails} failures")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
