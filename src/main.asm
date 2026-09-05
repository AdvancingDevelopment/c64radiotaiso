; ---------------------------------------------------------------
; RADIO TAISO 64 — demo-grade radio calisthenics for the C64
; (C) 2026 Advancing Development — original music, original code.
; Build: acme src/main.asm  ->  build/taiso.prg
; Test builds: -DTEST_PLAY=1|2 (start routine directly), -DDEBUG_HUD=1,
;   -DRASTER_DEBUG=1, -DTEST_TICK=n (jump the clock to tick n at start),
;   -DTEST_FREEZE=1 (hold the clock after the jump), -DTEST_BORDER=1
; ---------------------------------------------------------------
!cpu 6510
!to "build/taiso.prg", cbm

!src "src/constants.asm"

* = $0801
; BASIC stub: 2026 SYS2064
!byte $0b, $08
!byte $ea, $07
!byte $9e
!text "2064"
!byte $00, $00, $00

* = CODE_START
code_start:
start:
        sei
        cld
        ldx #$ff
        txs
        jsr hw_init
        jsr detect_pal
        jsr music_init
        lda #0
        sta zp_frame
        sta zp_tick
        sta zp_tick+1
        sta zp_tick_hold
        sta zp_routine
        sta keys_new
        sta keys_new+1
!ifdef TEST_BORDER {
        lda #2              ; red border: the opened areas must show blue
        sta BORDER
}
        jsr irq_init
        cli
!ifdef TEST_PLAY {
        lda #TEST_PLAY-1
        sta zp_routine
        jsr enter_play
} else {
        jsr enter_title
}

; ---------------------------------------------------------------
; main loop: one state step per frame (frame-synced on zp_frame)
; ---------------------------------------------------------------
main_loop:
        lda zp_frame
        cmp last_frame
        beq main_loop
        sta last_frame
        lda zp_state
        cmp #ST_PLAY
        bne +
        jsr step_play
        jmp main_loop
+       cmp #ST_TITLE
        bne +
        jsr step_title
        jmp main_loop
+       cmp #ST_PAUSED
        bne +
        jsr step_paused
        jmp main_loop
+       jsr finish_tick
        jsr step_finish
        jmp main_loop

last_frame: !byte 0

!src "src/init.asm"
!src "src/irq.asm"
!src "src/clock.asm"
!src "src/input.asm"
!src "src/ui.asm"
!src "src/movements.asm"
!src "src/play.asm"
!src "src/title.asm"
!src "src/music.asm"
!src "src/instruments.asm"
!src "src/choreo.asm"
!src "src/figure.asm"
!src "src/scroller.asm"
!src "src/text.asm"
!src "src/gen_song1.asm"        ; song 1 data lives here: the data segment is full
code_end:
!if * > CODE_LIMIT { !error "code segment overflow" }

!src "src/charset.asm"

* = FRAMES
frames_start:
!src "src/gen_sprites.asm"
frames_end:
; spare VIC-bank RAM behind the sprite frames holds plain data
!src "src/gen_backdrop.asm"
bankdata_end:
!if * > FRAMES_LIMIT-16 { !error "sprite frames + bank data overflow the VIC bank" }
* = FRAMES_LIMIT-1
!byte 0                         ; $7fff: idle-state graphics byte must be 0

* = DATA_START
data_start:
!src "src/gen_song2.asm"
!src "src/gen_poses.asm"
!src "src/gen_glyphs.asm"
data_end:
!if * > DATA_LIMIT { !error "data overflows $d000" }
