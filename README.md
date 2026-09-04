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

Keys: `1`/`2` choose the routine (or joystick), `SPACE` pause, `F1` figure size, `F3`
Japanese/English emphasis, `F5` voice on/off, `+`/`-` (or `F7`) tempo 80–120 %, `Q`/`RUN-STOP`
back to the title.

See `HANDOFF.md` for the architecture and module contracts.
