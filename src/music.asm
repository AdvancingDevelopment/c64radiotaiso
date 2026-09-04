!zone music
; music.asm — 3-voice SID sequencer (stub until phase 1). The stub
; already owns the clock start so the rest of the program can run.
music_init:       rts           ; boot: pick PAL/NTSC note table
music_frame:      rts           ; every frame from the bottom IRQ (after clock_frame)
music_play:                     ; X = song (0/1): start clock + sequencer at tick 0
        lda stub_periods_lo,x
        ldy stub_periods_hi,x
        pha
        tya
        tax
        pla
        jmp clock_start
music_stop:       rts
music_pause:      rts           ; gates off
music_resume:     rts
music_loop_title: rts           ; X = song: loop block 0 quietly (title screen)
music_seek:       rts           ; A = block (0..23)
stub_periods_lo: !byte <stub_p1, <stub_p2
stub_periods_hi: !byte >stub_p1, >stub_p2
; placeholder period tables (seg*10 + ntsc*5 + tempo): 126/96 and 138/104 bpm
stub_p1: !word $03bb,$0353,$02fc,$02b7,$027d, $047a,$03f8,$0390,$0340,$02fa
         !word $04e4,$0459,$03ea,$038f,$0341, $05d8,$0533,$04ad,$043d,$03e0
stub_p2: !word $0367,$0307,$02b9,$027a,$0244, $0410,$039c,$0340,$02f4,$02b5
         !word $0484,$0404,$039d,$0348,$0303, $0564,$04cb,$0450,$03ee,$0398
