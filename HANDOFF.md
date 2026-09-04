# HANDOFF — Radio Taiso 64

Demo-grade C64 (6510/ACME) follow-along program for Radio Taiso No.1 / No.2 with the
user's own music ("Asa no March" / "Hikari no March" from ~/taiso/score). Plan:
`~/.claude/plans/let-s-make-a-c64-flickering-walrus.md`.

## Build / test

- `make` → `build/taiso.prg` (+ segment report). Variant builds MUST use
  `acme -D... --format cbm --outfile build/<name>.prg src/main.asm` (never plain `--outfile`,
  the PRG then lacks its load address).
- `./test/boot_test.sh out.png [cycles] [prg] [extra x64sc args]` — headless VICE screenshot
  (warp, dummy sound). ~19,656 cycles per PAL frame; VICE boot costs ~3.3 s before the PRG runs.
  Review PNGs after `sips --resampleWidth 768 in.png --out big.png`.
- Test defines: `TEST_PLAY=1|2` (start routine 1/2 directly), `TEST_TICK=n` (clock jumps so the
  next tick is n; movement slot resolved), `TEST_FREEZE=1` (hold the clock once tick n is shown),
  `DEBUG_HUD=1` (row 24: frame tick beat count mv period, hex), `RASTER_DEBUG=1` (border colour
  per IRQ entry), `TEST_BORDER=1` (red $D020 to see the opened vertical border).
- `-keybuf` cannot drive tests (no KERNAL keyscan) — use the defines.

## Memory map (constants.asm)

All-RAM configuration `$01 = $35`; own vectors at $FFFA-$FFFF; no KERNAL/BASIC calls anywhere.

| region | use |
|---|---|
| $0810-$35FF | code segment: every `src/*.asm` module + small tables (guard CODE_LIMIT) |
| $3600-$47FF | staging: `gen_digi.asm` assembled with `!pseudopc $E000`, copied to $E000 at boot |
| $4000-$43FF | screen (bank 1), sprite pointers $43F8 |
| $4400-$47FF | DYN_SLOTS: sprite slots 16..31 (scroller / logo double buffers, RAM) |
| $4800-$4FFF | charset (`src/charset.asm`) |
| $5000-$7FFF | FRAMES: sprite slots 64..255 (`src/gen_sprites.asm`); $7FFF must stay 0 |
| $8000-$CFFF | data segment: gen_song1/2, gen_poses, gen_glyphs, gen_backdrop, gen_digi2 |
| $E000-$FFF9 | runtime home of the staged block (digi part 1) |

Zero page: $02-$1F shared (see constants.asm), $20-$2F figure/choreo, $30-$3F music,
$40-$47 digi, $48-$4F scroller, $50-$5F ui, $60-$6F irq/clock, $70-$7F title.

## Raster-timing lessons (hard-won, keep them)

1. The VIC compares the raster every cycle: writing `$D012` with the *current* line raises the
   flag at once, so a late entry run by hand must ack `$D019` first (else it dispatches twice).
2. Never write a `$D011` value that carries the current raster bit 8 (it becomes the compare
   MSB): mask with `and #$7f`/`#$77` before `sta $d011`.
3. The 24-row switch that keeps the vertical border open has a 3-line window (lines 248-251).
   It is done in the scroller entry after its sprite writes, with a wait for line 248 — the
   entry itself is straight-line stores (~260 cycles, sprites 4/5 last because the shins may
   still be running) starting at line 235-239. With the digi NMI (25-30 % CPU) any loop-based
   version overran into line 251 in 2-8 % of the frames: the border closed and the scroller
   sprites vanished for a frame ("dropouts"). `DEBUG_HUD` shows the late-switch counter and the
   max raster at entry/after writes/after switch (must stay < 251).
4. The bottom entry (music/input/clock) can overrun the frame end on NTSC (only 20 lines left):
   entry 0's late check handles a raster that has already wrapped past line 8.
5. IRQ-side code must not use `zp_tmp` (main-loop scratch); use `zp_clock_tmp`/`zp_irq_tmp`.
6. Sprites re-used later in a frame: a Y write to a running sprite is ignored, a pointer write
   takes effect on the next fetched row — so re-point a running sprite only into rows that are
   blank in both slots (that is why sprites 4/5 can switch to the scroller 10 lines before the
   shin box ends).

## Frame skeleton

Raster IRQ chain (`irq.asm`, table `irq_lines`, ascending, all < 256):
0 line 8 `irq_top` (25-row mode, `logo_commit`) · 1 line 50 `irq_figure` (`figure_commit`) ·
2 split `irq_split` (`figure_split`) · 3 scroller line 235-239 `irq_scroll` (`scroller_commit`,
then wait for line 248 and switch to 24-row mode → the vertical border never closes) ·
4 line 249 `irq_bottom` (`clock_frame`, `music_frame`, `input_scan`, `inc zp_frame`).
Late entries are acked before being run by hand; `$D011` read-modify-writes mask bit 7.
`figure_render` rewrites `irq_lines+2` (split) and `irq_lines+3` (scroller line, ≥ 219, ≤ 246)
each tick; they must stay ascending. Handlers run with A/X/Y saved by the dispatcher.

Clock (`clock.asm`): tick = 1/8 beat, `zp_tick` 16-bit, `zp_beat` (low byte), `zp_count8`
1..8. Flags set by the IRQ: `zp_tick_flag` and `zp_beat_flag` (consumed by the main loop,
`play.asm`), `zp_tick_music` (consumed by `music_frame`). `clock_acc+1` = frames until the next
tick (for hard restart). `zp_tick_hold` freezes everything (pause). Period table format: 20 words,
index = segment*10 + ntsc*5 + tempo_level (0..4 = 80..120 %); segment 1 starts at tick 2816.
`clock_start` (A/X = table lo/hi) primes tick = -1 so tick 0 fires on the next frame.

Main loop (`main.asm` / `play.asm`): frame-synced on `zp_frame`; states ST_TITLE / ST_PLAY /
ST_PAUSED / ST_FINISH. In PLAY, per tick: `play_track_movement` → `zp_cur_mv` (0 warm-up,
1..13, 14 finish) + `zp_mv_flag`; `zp_local_tick = tick & 63`; `choreo_tick`; `figure_render`;
per beat `ui_beat` + spoken count; per movement `choreo_set_anim` + `ui_movement`; every frame
`scroller_frame`, `ui_frame`, `digi_frame`. Movement grid: `movements.asm` (`mv_start_lo/hi`,
`mv_anim_r1/r2`, timeline ids 0..19 documented there).

Keys (`input.asm`): `keys_new` (16-bit press edges, consumed by the state code), `keys_stable`.
Bindings: 1/2 routine (title) or tempo 80/90 % (play), 3/4/5 tempo 100/110/120 %, L language,
V voice, SPACE pause, Q / RUN-STOP title, RETURN start — no function keys (the 1x size toggle
was removed at the user's request; `figure_set_scale` still exists).

## Module contracts (each module owns its files; do not edit others' files)

### Music — `src/music.asm`, `src/instruments.asm`, `src/gen_song1.asm`, `src/gen_song2.asm`, `tools/songconv.py`, `tools/check_wav.py`
- `music_init` (boot, after `detect_pal`): choose the PAL/NTSC note table (copy to RAM).
- `music_play` (X = song 0/1): load the sequencer at block 0 and call `clock_start` with that
  song's period table (A = lo, X = hi). `music_seek` (A = block 0..23): reposition all voices at
  block A (caller sets the clock). `music_stop`, `music_pause` (gates off, keep position),
  `music_resume`, `music_loop_title` (X = song: loop block 0 for the title, quieter).
- `music_frame`: called every frame from the bottom IRQ after `clock_frame`; act on
  `zp_tick_music` (clear it), never on `zp_tick_flag`.
- Keep `mus_d418` = the byte the music wants in `$D418` (volume | filter mode); write `$D418`
  only in init/stop/pause/resume — the digi NMI owns `$D418` while a word plays and restores
  `mus_d418` afterwards.
- Song data lives in the data segment (`gen_song*.asm`, included at $8000+); player code in the
  code segment. Period tables `song1_periods` / `song2_periods` (20 words as above) are part of
  the generated files.

### Puppet — `src/figure.asm`, `src/choreo.asm`, `src/gen_sprites.asm`, `src/gen_poses.asm`, `tools/sample_rig.mjs`, `tools/puppet.py`, `tools/pngw.py`
- `choreo_set_anim` (A = timeline id 0..19 per `movements.asm`): restart that timeline at
  cycle tick 0. `choreo_tick`: advance the decoder to `zp_local_tick` (sequential; on a jump
  replay from 0) → current pose record `pose_cur`.
- `figure_render` (main loop, per tick): pose → shadow block (8 × X/Y, MSB, pointers, plus the
  shin set), and update `irq_lines+2/+3`. `figure_commit` (IRQ line 50): write ALL sprite 0-7
  registers the figure needs (positions, MSB, pointers, `$D017/$D01D`, colours) — other modules
  reuse the same sprites later in the frame. `figure_split` (IRQ): sprites 4/5 → shins.
  `figure_init` (PLAY start), `figure_hide`, `figure_set_scale` (A = `fig_scale`, 1 = 2×).
- Anchor: waist at sprite X 184, feet on text row 20 (sprite Y ≈ 210-217). Keep everything
  below sprite Y 84 clear of rows 2-3 (Japanese name) and finish the shins by Y 224.
- Frames at `* = FRAMES` via `gen_sprites.asm` (slots 64+, ≤ 154 frames; slots 16-31 belong to
  the scroller/logo); pose tables in the data segment; metadata tables wherever they fit.

### UI + text + border sprites — `src/text.asm` (hooks below), `src/charset.asm`, `src/title.asm`, `src/scroller.asm`, `src/gen_glyphs.asm`, `src/gen_backdrop.asm`, `tools/glyphs.py`, `tools/backdrop.py`, `tools/text.json`
- Hooks called by `play.asm`: `ui_play_init`, `ui_movement`, `ui_beat`, `ui_frame`, `ui_tempo`,
  `ui_toggle_lang`, `ui_pause_show`, `ui_pause_hide`; by `main.asm`: `enter_title`, `step_title`
  (must set `zp_routine` and `jmp enter_play`), `enter_finish`, `step_finish` (→ `enter_title`).
- Scroller/logo: `scroller_init`, `scroller_set_text`, `scroller_frame`, `scroller_commit` (IRQ,
  line from `irq_lines+3`), `scroller_hide`, `logo_commit` (IRQ line 8), `logo_show`, `logo_hide`.
  Sprite slots 16..31 at DYN_SLOTS are theirs. Sprites 0-7 registers may be rewritten at the
  scroller line and at line 8 (the figure rewrites them at line 50).
- Screen rows: 0 title/tempo/clock, 1 English name, 2-3 Japanese name (16 glyphs max), 4-20
  figure band (+ sun/rays backdrop, count block cols 1-6, set/pips cols 32-38), 20 horizon,
  21 stations, 22-24 scroller zone. Palette in constants.asm.

### Voice — `src/digi.asm`, `src/gen_digi.asm` (staged, `!pseudopc $E000`), `src/gen_digi2.asm` (data segment), `tools/digi.py`
- `digi_play` (A = word: 0-7 ichi..hachi, 8 title1, 9 title2, 10 sutte, 11 haite, 12 otsukare),
  `digi_stop`, `digi_frame`, `digi_toggle`, `digi_enabled`, `nmi_handler` (CIA2 timer A NMI;
  must ack `$DD0D`; RESTORE key NMIs are ignored).
- `$D418` = sample | (`mus_d418` & $F0) while playing; restore `mus_d418` at the end.
- Staged part ≤ 4608 bytes (STAGE_LIMIT), rest in `gen_digi2.asm`.

## Play-state extras (play.asm)

- `play_sec` / `play_min` (binary) = elapsed time, advanced per frame with `zp_ntsc`-aware fps.
- `play_finish` (end of slot 13): sets `ANIM_BOW`, hides the scroller, jumps to `enter_finish`;
  the main loop keeps calling `finish_tick` (choreo/figure/ui/digi housekeeping) in ST_FINISH.

## Memory budget (2026-09-04, integrated)

code 10.6 KB / 11.7 KB (song 1 data lives here), stage 4.6 KB (digi part 1), frames 9.9 KB +
backdrop in the VIC-bank spare, data 18.9 KB / 20 KB. Adding anything sizeable now means
trimming: the 8×16 Latin scroller glyphs (704 B), the finish phrase sample (2 KB), pose head
tilt frames. Keep `$7FFF` = 0.

## Verification status (2026-09-04, final integration)

- `make test`: 34 screenshots OK (title PAL/NTSC, border, HUD, raster, 26 movement screens,
  boundary, finish, NTSC movement). Full-length runs reach the finish screen on PAL (3:08)
  and NTSC.
- Voice-on 100 s runs of both routines: 0 late border switches (DEBUG_HUD counter).
- Audio (`check_wav.py`): song 1 PAL 8/8, song 1 with voice 7/7, song 2 PAL 8/10 (two
  repeated-pitch bass probes report +40 ms — a detector limitation), song 1 NTSC within
  ±32 ms (some probes 2 NTSC frames early; not investigated further, inaudible for the use).
- Not yet verified by a human: how it sounds and feels in real time (`make run`).

## Status log

- 2026-09-04 (voice balance): the music is filter-ducked under each word — `digi_start`
  routes all three voices through the low-pass at cutoff 0 (`digi_ducked`), `digi_unduck`
  (from `digi_stop` and `digi_frame` once the word ends) restores `FILT_RES` and `flt_cut`.
  Captured envelope: the music's mid/high band falls to ~1/10 during a word.
- 2026-09-04 (NTSC round 5): user test: flicker only with the voice on, and the voice was
  inaudible — VICE here defaults to reSID 8580 (4-bit $D418 digi ≈ -32 dBFS); `make run`
  now passes `-sidmodel 0`. The NMI stretched the scroller commit to the line where the
  glyphs start (NTSC): scroller IRQ moved to 218 (NTSC) / 228 (PAL), SHIN_END_NTSC 228.
- 2026-09-04 (NTSC round 4): the scroll step (move/wrap/build) now runs in the bottom IRQ
  (`scroller_move`); the main loop only loads glyphs for wrapped (off-screen) sprites. On NTSC
  the main loop's frame work could spill past the scroller IRQ (line 229) once the voice NMI
  and the figure were active, and the commit then mixed moved/unmoved positions. Note: VICE
  screenshots in `-warp` (and even real time) do not show consecutive emulated frames, so
  motion cannot be judged from `-exitscreenshot` sequences; use the HUD counters. `make run`
  now passes `-soundsync 2` (exact) so VICE's flexible audio sync cannot stutter the display.
- 2026-09-04 (NTSC round 3): the NTSC scroller flicker was the shin sprites (4/5) being
  crunched: their expansion bit had to flip in a 3-line window between the shin box ending
  (~233) and the scroller starting (237), which NMI latency missed. Fix in the generator: shin
  ink now starts at row 3 of its sprite box (`align="top3"` in puppet.py), so the box ends 6
  lines earlier (multiplex gap min 10 lines, still safe for the split IRQ) — verified: NTSC
  consecutive frames identical in the scroller zone, 0 late frames PAL/NTSC.
- 2026-09-04 (NTSC round 2): NTSC horizon/sun/rays/stations one row higher (`ui_dy`) so the
  raised figure stands on the horizon; size key removed; finish screen clears the NTSC hint.
- 2026-09-04 (NTSC round): PAL/NTSC layout values are chosen at boot (`scroll_min_line`,
  `scr_y_min` in init.asm): NTSC scroller line 229 / glyph Y 235 (rows 23-24, inside the
  200-line picture, unexpanded), no border wait on NTSC, key hint on row 22 (`ui_ntsc_help`).
  PAL logo lowered to Y 26 (wobble 22-30): at Y 18 the wobble carried the glyph tops above
  the visible area, seen as flicker at the top of the logo. Verified: NTSC title/play
  screenshots, 55-100 s NTSC HUD runs with 0 late frames.
- 2026-09-04 (feedback round): (c) glyph ($1b) + ko-fi line on the title; F-keys replaced by
  S/L/V and 1-5 tempo; figure commit moved to line 66 (the logo's last rows were being
  re-pointed to figure frames at line 50 → fragments in rows 0-1); hidden scroller sprites now
  park at Y 250 (parking at Y 60 made the figure commit re-point running sprites → ghost in
  rows 2-5 while paused); `scroller_set_text` cuts to the new cue immediately, English first.
- 2026-09-04 (later): all four subsystems merged (music, puppet + shin multiplex, UI/text/
  scroller/logo/backdrop, digi voice). IRQ chain fixed (ack late dispatches, mask raster MSB,
  border+bottom merged into one entry at 249). Verified in VICE: title with border logo, all 26
  movement poses, free-running play screens (count block, kana/romaji, pips, sun flash,
  scroller in the bottom border), pause overlay, NTSC play, finish screen after a full run
  (3:08). Audio captures: songconv --check 0 mismatches; check_wav probes pass except for
  repeated-pitch/masked probes (checker limitation); voice writes verified sample-exact by the
  digi tool. Known nits: the elapsed clock keeps counting on the finish screen; the exit
  screenshot is mid-frame (rows below the raster show the previous frame — not a tear).
- 2026-09-04: scaffold done — all-RAM init, vectors, IRQ chain with the border trick (verified:
  side borders red, top/bottom zones blue), clock with PAL/NTSC period tables, play state
  skeleton, TEST_TICK/TEST_FREEZE/DEBUG_HUD builds verified (tick 456 → beat 57 count 2 mv 2;
  jump to 2820 → beat 352, slow period $03EA).
