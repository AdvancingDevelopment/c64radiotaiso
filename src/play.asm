!zone play
; ---------------------------------------------------------------
; play.asm — the PLAY / PAUSED states: clock flags -> movement slot,
; counts, hooks into figure/ui/scroller. Everything here is
; driven by zp_tick (owned by clock.asm); this file never touches
; the VIC directly except through the ui/figure modules.
; ---------------------------------------------------------------

enter_play:
        lda #ST_PLAY
        sta zp_state
        lda #COL_TEXT
        jsr screen_clear
        lda #0
        sta zp_cur_mv
        sta zp_mv_flag
        sta zp_local_tick
        sta play_done
        sta play_subsec
        sta play_sec
        sta play_min
        jsr ui_play_init        ; static layout + backdrop (ui/text modules)
        jsr figure_init
        jsr scroller_init
        ; start the clock on this song's period table and the music
        ldx zp_routine
        jsr music_play          ; sets clock table + calls clock_start
!ifdef TEST_TICK {
        jsr clock_test_jump
        lda #(TEST_TICK-1)>>7   ; block = tick/128
        jsr music_seek
        jsr play_track_movement ; find the slot for the jump target
        lda #0
        sta zp_mv_flag
        jsr play_anim_for_slot
        jsr ui_movement
        rts
}
        lda #ANIM_WARMUP
        jsr choreo_set_anim
        jsr ui_movement         ; draw slot 0 (warm-up) texts
        rts

; ---------------------------------------------------------------
step_play:
        ; --- keys ---
        lda keys_new
        and #(KEY_Q|KEY_STOP)
        beq +
        jmp play_quit
+       lda keys_new
        and #KEY_SPACE
        beq +
        lda #0
        sta keys_new
        jmp enter_pause
+       lda keys_new+1
        and #KEY_L              ; L: language emphasis
        beq +
        jsr ui_toggle_lang
+       ; 1..5: tempo 80 / 90 / 100 / 110 / 120 %
        ldx #0
        lda keys_new
        and #KEY_1
        bne .tempo
        inx
        lda keys_new
        and #KEY_2
        bne .tempo
        inx
        lda keys_new
        and #KEY_3
        bne .tempo
        inx
        lda keys_new
        and #KEY_4
        bne .tempo
        inx
        lda keys_new+1
        and #KEY_5
        beq +
.tempo: txa
        jsr clock_set_tempo
        jsr ui_tempo
+       lda #0
        sta keys_new
        sta keys_new+1

        ; --- clock events ---
        lda zp_tick_flag
        beq .no_tick
        lda #0
        sta zp_tick_flag
        jsr play_track_movement
        lda zp_tick
        and #63
        sta zp_local_tick
        jsr choreo_tick         ; decode pose for zp_local_tick
        jsr figure_render       ; -> sprite shadow block
!ifdef TEST_FREEZE {
        lda zp_tick+1           ; hold the clock once tick >= TEST_TICK is shown
        cmp #>TEST_TICK
        bcc +
        bne .hold
        lda zp_tick
        cmp #<TEST_TICK
        bcc +
.hold:  lda #1
        sta zp_tick_hold
+
}
        lda zp_beat_flag
        beq .no_beat
        lda #0
        sta zp_beat_flag
        jsr ui_beat             ; digit, words, pips, sun pulse
.no_beat:
        lda zp_mv_flag
        beq .no_mv
        lda #0
        sta zp_mv_flag
        lda zp_cur_mv
        cmp #MV_SLOTS-1
        bcc +
        jmp play_finish
+       jsr play_anim_for_slot
        jsr ui_movement         ; names, cue, stations, ray
.no_mv:
.no_tick:
        jsr play_clock_frame
        jsr scroller_frame
        jsr ui_frame            ; prefetch step, pulses, clock display
!ifdef DEBUG_HUD {
        jsr debug_hud
}
!ifdef TEST_SLOTDUMP {
        jsr slot_dump
}
        rts

; advance zp_cur_mv while tick >= start of the next slot
play_track_movement:
        ldx zp_cur_mv
        cpx #MV_SLOTS-1
        bcs .done
        inx
        lda zp_tick+1
        cmp mv_start_hi,x
        bcc .done
        bne .adv
        lda zp_tick
        cmp mv_start_lo,x
        bcc .done
.adv:   stx zp_cur_mv
        lda #1
        sta zp_mv_flag
        jmp play_track_movement
.done:  rts

; A = timeline id for (routine, zp_cur_mv) -> choreo
play_anim_for_slot:
        ldx zp_cur_mv
        lda zp_routine
        bne +
        lda mv_anim_r1,x
        jmp choreo_set_anim
+       lda mv_anim_r2,x
        jmp choreo_set_anim

; end of the routine: bow, then the finish screen (title.asm)
play_finish:
        lda #ANIM_BOW
        jsr choreo_set_anim
        jsr scroller_hide
        jmp enter_finish

; called every frame from the main loop in ST_FINISH before step_finish:
; keeps the figure animating (bow) and the ui housekeeping alive
finish_tick:
        lda zp_tick_flag
        beq +
        lda #0
        sta zp_tick_flag
        sta zp_beat_flag
        lda zp_tick
        and #63
        sta zp_local_tick
        jsr choreo_tick
        jsr figure_render
+       jmp ui_frame

; elapsed time: play_sec/play_min (binary), advanced once per frame
play_clock_frame:
        inc play_subsec
        lda play_subsec
        ldx zp_ntsc
        cmp play_fps,x
        bcc +
        lda #0
        sta play_subsec
        inc play_sec
        lda play_sec
        cmp #60
        bcc +
        lda #0
        sta play_sec
        inc play_min
+       rts
play_fps:    !byte 50, 60
play_subsec: !byte 0
play_sec:    !byte 0
play_min:    !byte 0

play_quit:
        lda #0
        sta keys_new
        sta keys_new+1
        jsr music_stop
        jsr figure_hide
        jsr scroller_hide
        jmp enter_title

; ---------------------------------------------------------------
enter_pause:
        lda #ST_PAUSED
        sta zp_state
        lda #1
        sta zp_tick_hold
        jsr music_pause
        jsr ui_pause_show
        rts

step_paused:
        lda keys_new
        and #KEY_SPACE
        beq +
        lda #0
        sta keys_new
        sta keys_new+1
        sta zp_tick_hold
        jsr music_resume
        jsr ui_pause_hide
        lda #ST_PLAY
        sta zp_state
        rts
+       lda keys_new
        and #(KEY_Q|KEY_STOP)
        beq +
        lda #0
        sta zp_tick_hold
        jmp play_quit
+       jsr ui_frame
        rts

fig_scale:    !byte 1           ; 1 = 2x expanded
play_done:    !byte 0

!ifdef DEBUG_HUD {
; row 24: frame tick beat count mv  (hex)
debug_hud:
        lda #0
        sta zp_x
        lda #24
        ldx zp_ntsc
        beq +
        lda #21                 ; NTSC: row 24 is under the scroller
+       sta zp_y
        jsr cell_ptr
        ldy #0
        lda zp_frame
        jsr put_hex
        iny
        lda zp_tick+1
        jsr put_hex
        lda zp_tick
        jsr put_hex
        iny
        lda zp_beat
        jsr put_hex
        iny
        lda zp_count8
        jsr put_hex
        iny
        lda zp_cur_mv
        jsr put_hex
        iny
        lda clock_period+1
        jsr put_hex
        lda clock_period
        jsr put_hex
        iny
        lda irq_late_border     ; late 24-row switches (frames with a closed border)
        jsr put_hex
        iny
        lda irq_max_a           ; max raster: scroller entry start / after writes / after switch
        jsr put_hex
        lda irq_max_b
        jsr put_hex
        lda irq_max_c
        jsr put_hex
        lda irq_max_d           ; NTSC: max raster after the bottom entry's 24-row switch
        jsr put_hex
        iny
        lda irq_bad_regs        ; frames with a wrong scroller register at line 249
        jsr put_hex
        rts
!ifdef TEST_SLOTDUMP {
; row 22: for scroller slots 16..23, bytes 0 of rows 4 and 8 (hex)
slot_dump:
        lda #0
        sta zp_x
        lda #22
        sta zp_y
        jsr cell_ptr
        ldy #0
        ldx #0
-       lda DYN_SLOTS+4*3,x     ; row 4 byte 0 of slot 16 + x/64
        jsr put_hex
        lda DYN_SLOTS+8*3,x
        jsr put_hex
        iny
        txa
        clc
        adc #64
        tax
        bne -
        ; row 21 (over the stations): sprite pointers 0-7, split, scroller line, y
        lda #0
        sta zp_x
        lda #21
        sta zp_y
        jsr cell_ptr
        ldy #0
        ldx #0
-       lda SPR_PTRS,x
        jsr put_hex
        inx
        cpx #8
        bne -
        iny
        lda irq_lines+2
        jsr put_hex
        lda irq_lines+3
        jsr put_hex
        iny
        lda scr_y_now
        jsr put_hex
        lda VIC_SPR0_X+1
        jsr put_hex
        lda VIC_SPR0_X+3
        jsr put_hex
        rts
}
put_hex:
        pha
        lsr
        lsr
        lsr
        lsr
        jsr .nib
        pla
        and #$0f
.nib:   cmp #10
        bcc +
        adc #6              ; a-f -> screen codes 1-6 (+carry)
        and #$0f
        sta (zp_ptr),y
        iny
        rts
+       ora #$30
        sta (zp_ptr),y
        iny
        rts
}
