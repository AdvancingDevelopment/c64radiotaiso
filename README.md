# Radio Taiso 64

A demo-grade Commodore 64 program for following along with Radio Taiso No. 1 and No. 2 —
the retro sibling of [radiotaiso.org](https://radiotaiso.org).

- Music: the original compositions "Asa no March" (No. 1) and "Hikari no March" (No. 2) from
  the website, arranged for the SID's three voices (the 1951/1952 NHK pieces are copyrighted
  and are not used).
- A 10-part articulated stick figure built from the 8 hardware sprites (shins multiplexed),
  with poses sampled from the website's animation rig at 1/8-beat resolution.
- Digitized Japanese counting (いち・に・さん…) and announcements over the music.
- Opened top/bottom borders, a kanji/kana sprite scroller in the bottom border (PAL), the
  ラジオ体操 logo in the top border, a sunrise backdrop whose rays light up as you progress.

## Build and run

```
make            # build/taiso.prg (ACME)
make run        # VICE x64sc
make run-ntsc
make d64        # build/taiso.d64
make test       # headless screenshots into build/test/
```

Requirements: `acme`, `vice` (x64sc, c1541), `python3`, `node` (regenerating pose data needs
`~/taiso/node_modules/gsap`), `ffmpeg` + macOS `say` (regenerating the voice).

Keys: `1`/`2` choose the routine (or joystick), `RETURN`/`SPACE`/fire start, `SPACE` pause,
`S` figure size, `L` Japanese/English emphasis, `V` voice on/off, `1`–`5` tempo 80/90/100/110/
120 %, `Q`/`RUN-STOP` back to the title. (Plain keys on purpose: function keys are awkward on
Mac keyboards in VICE.)

## Regenerating the data

```
node tools/sample_rig.mjs && python3 tools/puppet.py   # poses from ~/taiso rig -> sprites/poses
python3 tools/songconv.py && python3 tools/songconv.py --check   # music from ~/taiso/score
python3 tools/glyphs.py && python3 tools/backdrop.py   # Japanese glyphs (Shinonome), backdrop
python3 tools/digi.py                                   # voice (macOS `say -v Kyoko`, ffmpeg)
```

Drop your own recordings as `assets/voice/<word>.wav` (see `assets/voice/README.md`) to replace
the synthesized voice.

## Verification

`make test` builds the test variants and writes screenshots to `build/test/` (title, every
movement of both routines at its signature phase, boundary crossing, finish, NTSC). Audio:
capture with `x64sc ... -soundrecdev wav -soundrecarg out.wav` and run
`python3 tools/check_wav.py out.wav --song 1` (see the script's docstring). `-DDEBUG_HUD=1`
builds show frame/tick/beat/count/movement/period and the raster-timing counters on row 24.

## Notes

- PAL is the primary target (border logo and border scroller). On NTSC the borders are not
  visible, so the scroller runs inside the bottom rows and the title logo sits in the picture.
- The SID voice is 4-bit; 8580 SIDs need the "digi boost" fix (VICE: SID model 8580D).
- Memory is nearly full (see HANDOFF.md) — adding content means trimming something.

See `HANDOFF.md` for the architecture, module contracts and the raster-timing lessons.
