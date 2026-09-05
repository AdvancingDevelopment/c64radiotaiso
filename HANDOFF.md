# HANDOFF — Radio Taiso 64

Demo-grade C64 (6510/ACME) follow-along program for Radio Taiso No.1 / No.2 with the
user's own music ("Asa no March" / "Hikari no March" from ~/taiso/score). Plan:
`~/.claude/plans/let-s-make-a-c64-flickering-walrus.md`. Coded with assistance from
Anthropic's Claude, across several Claude Code sessions; this file is the hand-off between
them.

## Build / test

- `make` → `build/taiso.prg` (+ segment report). Variant builds MUST use
  `acme -D... --format cbm --outfile build/<name>.prg src/main.asm` (never plain `--outfile`,
  the PRG then lacks its load address).
- `./test/boot_test.sh out.png [cycles] [prg] [extra x64sc args]` — headless VICE screenshot
  (warp, dummy sound, NTSC unless `-pal` is among the extra args — NTSC is the default
  system everywhere: `make run`, `make test`; `make run-pal` for PAL). Every VICE invocation
  must carry `-default` or `+saveres`: the user's `~/.config/vice/vicerc` has
  SaveResourcesOnExit=1, and flags saved by a stray run (dummy sound, NTSC, an off-screen
  window position) silently change what `make run` does. ~19,656 cycles per PAL frame
  (~17,095 NTSC); VICE boot costs ~3.3 s before the PRG runs. Review PNGs after
  `sips --resampleWidth 768 in.png --out big.png`.
- Test defines: `TEST_PLAY=1|2` (start routine 1/2 directly), `TEST_TICK=n` (clock jumps so the
  next tick is n; movement slot resolved), `TEST_FREEZE=1` (hold the clock once tick n is shown),
  `DEBUG_HUD=1` (row 24, NTSC row 20: frame tick beat count mv period, late switches, max
  rasters, bad scroller-register frames, hex), `RASTER_DEBUG=1` (border colour
  per IRQ entry), `TEST_BORDER=1` (red $D020 to see the opened vertical border).
- `-keybuf` cannot drive tests (no KERNAL keyscan) — use the defines.

## Memory map (constants.asm)

All-RAM configuration `$01 = $35`; own vectors at $FFFA-$FFFF; no KERNAL/BASIC calls anywhere.

| region | use |
|---|---|
| $0810-$3FFF | code segment: every `src/*.asm` module + song 1 (guard CODE_LIMIT=$4000); ends ~$3169 |
| $4000-$43FF | screen (bank 1), sprite pointers $43F8 |
| $4400-$47FF | DYN_SLOTS: sprite slots 16..31 (scroller / logo double buffers, RAM) |
| $4800-$4FFF | charset (`src/charset.asm`) |
| $5000-$7FFF | FRAMES: sprite slots 64..255 (`src/gen_sprites.asm`); $7FFF must stay 0 |
| $8000-$CFFF | data segment: gen_song2, gen_poses, gen_glyphs, gen_backdrop (11.9 KB / 20 KB used) |
| $FFFA-$FFFF | IRQ/NMI/RESET vectors (written by hw_init; NMI is a bare `rti` stub) |

Zero page: $02-$1F shared (see constants.asm), $20-$2F figure/choreo, $30-$3F music,
$40-$47 free (was digi), $48-$4F scroller, $50-$5F ui, $60-$6F irq/clock, $70-$7F title.

## Raster-timing lessons (hard-won, keep them)

1. The VIC compares the raster every cycle: writing `$D012` with the *current* line raises the
   flag at once, so a late entry run by hand must ack `$D019` first (else it dispatches twice).
2. Never write a `$D011` value that carries the current raster bit 8 (it becomes the compare
   MSB): mask with `and #$7f`/`#$77` before `sta $d011`.
3. The 24-row switch that keeps the vertical border open has a 3-line window (lines 248-251).
   It is done in the scroller entry after its sprite writes, with a wait for line 248 — the
   entry itself is straight-line stores (sprites 4/5 last because the shins may still be
   running; since the commit was split it is only sprites 4/5 + the shared registers, from
   line >= 228 on PAL). A badline plus the 8 sprites' DMA can still
   push a loop-based version past 251 in a few percent of frames (the border closes and the
   scroller vanishes for a frame — "dropouts"); `DEBUG_HUD` shows the late-switch counter and
   the max raster at entry/after writes/after switch (must stay < 251).
   NTSC needs the same switch (the glyph rows 237-252 cross the 25-row bottom border at 251)
   and there it is the bottom entry's job: that entry fires at 244 (`LINE_BORDER_NTSC`) and
   waits for line 248 before the `$D011` write. Dispatched at 249 it landed after 251 in a
   few percent of frames — the bottom two glyph rows blinked. (Historically this was far
   worse — ~5 %, 158/3350 in a 56 s run — while the 5 kHz digi voice NMI stole 25-30 % CPU;
   the voice has since been removed, but the early-fire + wait is kept for the DMA margin.)
   The HUD counter (`irq_late_border`, NTSC) and `irq_max_d` (must stay <= 250) verify it.
4. The bottom entry (music/input/clock) can overrun the frame end on NTSC (only 20 lines left):
   entry 0's late check handles a raster that has already wrapped past line 8.
5. IRQ-side code must not use `zp_tmp` (main-loop scratch); use `zp_clock_tmp`/`zp_irq_tmp`.
6. Sprites re-used later in a frame: a Y write to a running sprite is ignored, a pointer write
   takes effect on the next fetched row — so re-point a running sprite only into rows that are
   blank in both slots (that is why sprites 4/5 can switch to the scroller 10 lines before the
   shin box ends).
7. Chain lines that the figure publishes per frame (`irq_lines+2..4`) must also be right when
   the figure is off: the table default for the scroller entry is the PAL line (228), which on
   NTSC delayed that entry's expansion switch to the sprite Y itself (line 237) on the title
   and in the first play frames. `detect_pal` and `figure_hide` now set the per-system line.
8. ACME anonymous labels: a `+`/`-` inside an `!ifdef` block is a target for branches outside
   it. The `DEBUG_HUD` build's `beq +` in `irq_scroll` jumped into the HUD block and skipped
   the whole PAL border switch — the HUD measured a different program. Use named `.labels`
   around conditional blocks.

## Frame skeleton

Raster IRQ chain (`irq.asm`, table `irq_lines`, 6 entries, ascending, all < 256):
0 line 8 `irq_top` (25-row mode, `logo_commit`) · 1 line 66 `irq_figure` (`figure_commit`) ·
2 split `irq_split` (`figure_split`) · 3 pre-commit line (≥ 196) `irq_scroll_pre`
(`scroller_commit_pre`: glyph sprites 0-3, 6, 7) · 4 scroller line (PAL ≥ 228, NTSC ≥ 218,
≤ 246) `irq_scroll` (`scroller_commit`: sprites 4/5 + shared registers; on PAL then wait for
line 248 and switch to 24-row mode → the vertical border never closes) · 5 bottom entry
(PAL 249; NTSC 244, waits for 248 and does the 24-row switch there) `irq_bottom`
(`inc zp_frame`, `clock_frame`, `music_frame`, `scroller_move`, `input_scan`).
Late entries are acked before being run by hand; `$D011` read-modify-writes mask bit 7.
`figure_render` rewrites `irq_lines+2` (split), `+3` (pre-commit) and `+4` (scroller line)
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
per beat `ui_beat`; per movement `choreo_set_anim` + `ui_movement`; every frame
`scroller_frame`, `ui_frame`. Movement grid: `movements.asm` (`mv_start_lo/hi`,
`mv_anim_r1/r2`, timeline ids 0..19 documented there).

Keys (`input.asm`): `keys_new` (16-bit press edges, consumed by the state code), `keys_stable`.
Bindings: 1/2 routine (title) or tempo 80/90 % (play), 3/4/5 tempo 100/110/120 %, SPACE pause,
Q / RUN-STOP title, RETURN start — no function keys. Removed at the user's request: the 1x
size toggle (`figure_set_scale` still exists), the V voice toggle, and the L language toggle
(both the English name on row 1 and the Japanese name on rows 2-3 are now always white).

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
  only in init/play/stop/pause/resume/seek (nothing else touches it now the voice is gone).
- Song data lives in the data segment (`gen_song*.asm`, included at $8000+); player code in the
  code segment. Period tables `song1_periods` / `song2_periods` (20 words as above) are part of
  the generated files.

### Puppet — `src/figure.asm`, `src/choreo.asm`, `src/gen_sprites.asm`, `src/gen_poses.asm`, `tools/sample_rig.mjs`, `tools/puppet.py`, `tools/pngw.py`
- `choreo_set_anim` (A = timeline id 0..19 per `movements.asm`): restart that timeline at
  cycle tick 0. `choreo_tick`: advance the decoder to `zp_local_tick` (sequential; on a jump
  replay from 0) → current pose record `pose_cur`.
- `figure_render` (main loop, per tick): pose → shadow block (8 × X/Y, MSB, pointers, plus the
  shin set), and update `irq_lines+2/+3/+4`. `figure_commit` (IRQ line 66): write ALL sprite 0-7
  registers the figure needs (positions, MSB, pointers, `$D017/$D01D`, colours) — other modules
  reuse the same sprites later in the frame. `figure_split` (IRQ): sprites 4/5 → shins.
  `figure_init` (PLAY start), `figure_hide`, `figure_set_scale` (A = `fig_scale`, 1 = 2×).
- Anchor: waist at sprite X 184, feet on text row 20 (sprite Y ≈ 210-217). Keep everything
  below sprite Y 84 clear of rows 2-3 (Japanese name) and finish the shins by Y 224.
- Frames at `* = FRAMES` via `gen_sprites.asm` (slots 64+, ≤ 154 frames; slots 16-31 belong to
  the scroller/logo); pose tables in the data segment; metadata tables wherever they fit.

### UI + text + border sprites — `src/text.asm` (hooks below), `src/charset.asm`, `src/title.asm`, `src/scroller.asm`, `src/gen_glyphs.asm`, `src/gen_backdrop.asm`, `tools/glyphs.py`, `tools/backdrop.py`, `tools/text.json`
- Hooks called by `play.asm`: `ui_play_init`, `ui_movement`, `ui_beat`, `ui_frame`, `ui_tempo`,
  `ui_pause_show`, `ui_pause_hide`; by `title.asm`'s `enter_finish`: `ui_finish`; by
  `main.asm`: `enter_title`, `step_title` (must set `zp_routine` and `jmp enter_play`),
  `enter_finish`, `step_finish` (→ `enter_title`). The elapsed clock (`ui_sec`/`ui_min`,
  advanced in `ui_frame`) holds while paused and stops in ST_FINISH.
- Scroller/logo: `scroller_init`, `scroller_set_text`, `scroller_frame`, `scroller_commit_pre` /
  `scroller_commit` (IRQ, lines from `irq_lines+3/+4`), `scroller_move` (bottom IRQ),
  `scroller_hide`, `scroller_show`, `logo_commit` (IRQ line 8), `logo_show`, `logo_hide`.
  Sprite slots 16..31 at DYN_SLOTS are theirs: slots 16+i / 24+i are the two buffers of
  scroller sprite i during play; the logo uses 24-30 on the title only. The scroller is
  English only: 8 X-expanded sprites, 3 half-width Latin glyphs (16 px per character) each,
  48 px apart = one seamless 384 px train; the cue text (`mv_cue_en`) loops with a blank
  cell between repeats. All position/pointer changes happen in `scroller_move` (bottom IRQ):
  a sprite wraps +384 px only once the main loop has loaded its next cell into the spare
  slot, so glyphs never change on screen and positions/pointers always agree with the
  frame's commit. Sprites 0-7 registers may be rewritten at the scroller lines and at
  line 8 (the figure rewrites them at line 66).
- Screen rows: 0 routine title + elapsed clock, 1 English name (white), 2-3 Japanese name
  (white, 16 glyphs max), 4-20 figure band (+ sun/rays backdrop, count block cols 1-6,
  set/pips cols 32-39), 20 horizon, 21 empty, 22 `TEMPO: 12345` bar (current level in
  brass), 23 stations (progress dots), 24 free (the PAL scroller sprites hang in the border
  from line 247); on NTSC the horizon, tempo bar and dots sit one row higher (`ui_dy`: 19,
  21, 22) with the scroller in rows 23-24. The pause overlay hides the figure and centres
  PAUSED on row 12. The finish screen drops the tempo bar, moves the dots up into its row and
  prints "space or fire:  main menu" on row 24 (cols 8-32). Palette in constants.asm.

## Play-state extras (play.asm)

- `play_sec` / `play_min` (binary) = elapsed time, advanced per frame with `zp_ntsc`-aware fps
  (currently unread: the displayed clock is text.asm's `ui_sec`/`ui_min`).
- `play_finish` (end of slot 13): sets `ANIM_BOW`, hides the scroller, jumps to `enter_finish`;
  the main loop keeps calling `finish_tick` (choreo/figure/ui housekeeping) in ST_FINISH.

## Memory budget (2026-09-04, integrated)

code 10.3 KB / 14.3 KB (song 1 data lives here), frames 9.9 KB + backdrop in the VIC-bank
spare, data 11.9 KB / 20 KB (the Japanese scroller cues and their glyphs were dropped on
2026-09-04). The digi voice (staging block + `gen_digi2`, ~11 KB) was removed at the user's
request, freeing the $E000 block and ~6 KB of the data segment. Keep `$7FFF` = 0.

## Verification status (2026-09-04, after the feedback rounds)

- `make test`: 35 screenshots OK (NTSC: title, HUD, raster, 26 movement screens, boundary,
  finish; PAL: title, open border, HUD, one movement). Full-length runs reach the finish
  screen on PAL (3:08) and NTSC.
- 40-60 s HUD runs (English scroller, IRQ-side wraps and cuts): NTSC and PAL 0 late border
  switches, switch max line 248, 0 bad register frames.
- Audio (`check_wav.py`): song 1 PAL 8/8, song 2 PAL 8/10 (two repeated-pitch bass probes
  report +40 ms — a detector limitation), song 1 NTSC within ±32 ms.
- The user runs it in real time (`make run`, 2026-09-04); the feedback rounds are in the log.

## Release kit

`make release VERSION=x.y` (tools/release.sh) builds `build/release/`: `RadioTaiso64.prg`,
`RadioTaiso64.d64`, `README.txt` (from `release/README.txt`, version/date substituted),
`screenshots/` (2x nearest-neighbour PNGs via ffmpeg: title NTSC/PAL, natural play runs of
No.1/No.2/PAL, the finish screen after a full run), `screenshots-native/` (384 px, for CSDb),
`cover-itch-630x500.png`, `RELEASE_NOTES.md` (GitHub release body, from `release/NOTES.md`)
and `RadioTaiso64_v<x.y>.zip`. GitHub: https://github.com/AdvancingDevelopment/c64radiotaiso
(public; releases carry the zip, d64 and prg). The per-platform checklist (GitHub
release, itch.io, CSDb, Lemon64, Internet Archive, Demozoo/Pouet, announcements) is
`release/RELEASING.md`. Releases are tagged `v<x.y>`; v1.0 = 2026-09-04.

## Status log

- 2026-09-04 (v1.0 release kit): `make release`, `release/README.txt` (release notes),
  `release/RELEASING.md` (distribution checklist), tag `v1.0`.
- 2026-09-04 (feedback round 4): tempo bar and progress dots one row lower (PAL rows 22/23,
  NTSC 21/22 via `ui_dy`; the NTSC HUD row is 20); the finish hint moved to row 24 and reads
  "space or fire:  main menu"; the set indicator is "set  n/m" (cols 32-39). Later the hint
  moved one column right (col 8) at the user's request; row 24 is the last text row, so a
  further move down would need sprites in the border (not done); instead the finish screen's
  dots moved up one row into the cleared tempo row (`stations_draw` checks ST_FINISH).
- 2026-09-04 (feedback round 3): NTSC is the default system (`make run` = NTSC, `make run-pal`;
  `boot_test.sh` adds `-ntsc` unless `-pal` is passed; the test suite runs NTSC with PAL
  variants title_pal/border/hud_pal/pal_m5). The progress dots moved below the tempo bar
  (rows 21 tempo / 22 dots on PAL, 20 / 21 on NTSC via `ui_dy`; the NTSC HUD row is 22).
  The elapsed clock stops when the finish screen is reached (`ui_frame` skips the count in
  ST_FINISH). Title: "radiotaiso.org" centred on row 22 (white) above the copyright line.
  Finish: "space or fire: main menu" on row 23 (any key or fire still returns to the title).
- 2026-09-04 (sun flash): the 3-frame brass flash of the sun on every count 1 (`sun_t`) is
  gone — at 60 ms it read as a flicker. The sun stays orange during play and turns brass on
  the finish screen only; the per-beat station pulse (6 frames, white) remains.
- 2026-09-04 (make run fix): `make run` showed nothing and printed sound-buffer overflow
  warnings — `~/.config/vice/vicerc` had SoundDeviceName=dummy, MachineVideoStandard=NTSC and
  Window0Xpos=2431 saved (SaveResourcesOnExit=1) by an earlier VICE run. The config was
  cleaned (backup `vicerc.bak-20260904`), `run`/`run-ntsc` pass `-pal`/`-ntsc` and `+saveres`,
  `boot_test.sh` passes `+saveres` too.
- 2026-09-04 (scroller pass): the bottom scroller is English only and seamless. Sprites are
  X-expanded and 48 px apart (was 36 px with unexpanded 24 px English cells, which read as
  3-character chunks with 12 px gaps and left the right third of the picture empty); the
  eight sprites form one 384 px train of 24 characters that covers the 320 px picture, and
  the side borders (still closed) hide the wrap. Each sprite double-buffers slots 16+i /
  24+i; `scroller_frame` loads the next 3 characters into the spare slot when the IRQ asks
  (flag 1 -> 2) and `scroller_move` (bottom IRQ) does the wrap + pointer flip, the cut at a
  movement change (`scr_cut` 1 = loading, 2 = apply) and the un-hide (`scr_unhide`) — so no
  scroller register changes between a frame's commits and the HUD check at line 249/244.
  A hidden scroller (pause) stands still. The Japanese cue strings and their glyphs were
  dropped from `gen_glyphs.asm` (data segment 12.9 -> 11.9 KB; `cue_jp` removed from
  text.json). Verified: PAL/NTSC 40 s HUD runs from the start and a 60 s NTSC run through
  the finish: 0 late switches, 0 bad register frames (before the IRQ-side flip the NTSC
  runs counted 1-3, one per cut); screenshots of routine 1 movements 2/5 on PAL/NTSC and
  the boundary run show continuous text.
- 2026-09-04 (UI pass 2): row 1 shows the English name centred (the n/13 counter is dropped —
  the progress dots already show it); elapsed clock moved to col 36 (flush right); the Japanese
  name on rows 2-3 gets a 1-cell gap between glyphs when it fits (n<=13; the 14/16-glyph names
  stay tight); the sunrise rays render 2px lower (backdrop.py RAY_RENDER_DY) so they clear the
  name; resume repaints the rays the centred PAUSED overwrote (ui_pause_hide -> rays_redraw).
  Scroller pitch 48->36 with per-sprite X-expansion (scr_exp): Japanese glyphs expand (32px, a
  slight 4px gap); English cells do not (24px, so they never overlap) — English now reads in
  3-char groups with small gaps instead of running on. NTSC/PAL 40s HUD: 0 late, 0 bad frames.
- 2026-09-04 (UI pass): default SID back to 8580 (`make run`); removed the on-title PAL/NTSC
  tag and the `asa no march / hikari no march` subtitle; recentred the title and moved its
  key hint clear of the sun; tempo moved off row 0 to a bottom `TEMPO: 12345` bar (row 22,
  current level highlighted, default 3); PAUSED now centres on row 12 with the figure hidden
  and no resume/language help lines; the L language toggle is gone and both name rows are
  always white. NTSC 40 s HUD after: 0 late border switches, switch max 248, 0 bad frames.
- 2026-09-04 (voice removed): at the user's request the digitised Japanese voice was
  deleted entirely — it was not clear enough at 4-bit/5 kHz to be worth it. Removed
  `src/digi.asm`, `src/gen_digi.asm`, `src/gen_digi2.asm`, `tools/digi.py`, `assets/voice/`,
  the CIA2-timer NMI player, the load-time staging block ($3600-$47FF → $E000), the V key,
  and every `digi_*` hook in play/title. The NMI vector is now a bare `rti` stub (RESTORE is
  self-clearing). The music keeps `$D418` to itself (no more ducking). This also removes the
  only source of the earlier NTSC scroller flicker; the border-switch timing margin is kept.
  PRG 49.6 KB → 43.6 KB; data segment 18.9 KB → 12.9 KB. Also: no logo during play (the
  top-border ラジオ体操第一 is gone while exercising; the title still shows it).
- 2026-09-04 (NTSC round 7, fixed): the voice-on flicker of the NTSC scroller was the 24-row
  border switch, still dispatched at line 249 on NTSC, landing after line 251 in ~5 % of the
  frames (HUD: 158 late switches in 56 s with the voice, 1 without). The bottom entry now
  fires at 244 on NTSC and waits for 248 (lesson 3); the scroller entry's default line is set
  per system (lesson 7); the HUD build's label bug fixed (lesson 8). Verified: NTSC 60 s voice
  on: 0 late switches, switch max line 250, scroller entry 220/224/230, 0 bad register frames;
  PAL 50 s voice on: 0 late, switch max 250, entry 231/234. The "emulator side" diagnosis
  below was wrong.
- 2026-09-04 (diagnosis, superseded): `DEBUG_HUD` now also counts frames in which any scroller register
  ($D001/$D009 Y, $D000/$D008 X, pointers 0/4, $D015, $D017, $D010) differs from the committed
  value at line 249 (`irq_bad_regs`). NTSC, voice on, 65 s: 1 bad frame in ~3900 (the movement
  cut). So the VIC state is right; the flicker the user still sees in VICE with the voice on is
  on the emulator side (reSID "resampling" mode + 5 kHz $D418 writes). `make run` tries
  `-residsamp 1`. Title logo is now ラジオ体操 (5 glyphs) — 第一/第二 only during play.
- 2026-09-04 (NTSC round 6): NTSC counters with the voice on showed the scroller commit
  starting as late as 234 and ending at 245 (> glyph Y 237) — the eight register sets take
  up to 10 lines under NMI + badlines + sprite DMA, and the line itself moves with the knees.
  The commit is now split: `scroller_commit_pre` (sprites 0-3,6,7) at `irq_lines+3`, the line
  after the lowest of those figure boxes ended (figure computes it, ≥ LINE_PRE_MIN 196), and
  `scroller_commit` (sprites 4/5 + shared regs) at `irq_lines+4`. Worst case now: start 229,
  writes 231, switch 232 (NTSC), 233 (PAL). IRQ chain has 6 entries.
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
