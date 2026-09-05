RADIO TAISO 64  v@VERSION@  (@DATE@)
====================================

A demo-grade Commodore 64 program for following along with Radio Taiso No.1
and No.2, the Japanese radio calisthenics - the retro sibling of the web
version at https://radiotaiso.org

FILES
  RadioTaiso64.d64   disk image: real C64 (SD2IEC, 1541 Ultimate, Pi1541,
                     a real 1541) or any emulator
  RadioTaiso64.prg   the program on its own, for emulators
  screenshots/       PNG screenshots (2x pixel size)

RUNNING
  Emulator (VICE x64sc, C64 Forever, ...): autostart the .d64 or the .prg.
  Real C64:      LOAD"*",8      then      RUN
  PAL and NTSC machines are both supported (detected at start-up).
  Joystick in port 2 or the keyboard.

KEYS
  1 / 2  (joystick up/down)     choose routine No.1 / No.2
  RETURN, SPACE or fire         start
  SPACE                         pause / resume
  1 .. 5                        tempo 80 / 90 / 100 / 110 / 120 %
  Q or RUN/STOP                 back to the title

WHAT IS IN IT
  * Both routines (13 movements each, about three minutes) led by an
    animated stick-figure coach built from the 8 hardware sprites (the
    shins are multiplexed); the poses were sampled from the website's
    animation rig at 1/8-beat resolution.
  * Original music, "Asa no March" (No.1) and "Hikari no March" (No.2),
    arranged for the SID's three voices. The 1951/1952 NHK pieces are
    copyrighted and are not used.
  * Counts in Japanese (kana and romaji) and English, movement names in
    both languages, a beat display, set counter and progress dots.
  * Opened top and bottom borders: a seamless English cue scroller in the
    bottom border (PAL) and the Radio Taiso logo in the top border on the
    title screen; a sunrise backdrop whose rays light up as you progress.

CREDITS
  Code, music and design: Advancing Development, 2026.
  Coded with assistance from Anthropic's Claude.
  Japanese glyphs: Shinonome font (public domain, /efont/, 2001).
  Built with the ACME cross-assembler; tested in VICE 3.10.

  Download page ....... https://advancing.itch.io/radio-taiso-64
  Web version ......... https://radiotaiso.org
  Support the project . https://ko-fi.com/advancing

(C) 2026 Advancing Development. Free to download and share.
Source code (MIT licence): https://github.com/AdvancingDevelopment/c64radiotaiso
