!zone play
; ---------------------------------------------------------------
; play.asm — the PLAY / PAUSED states: clock flags -> movement slot,
; counts, hooks into figure/ui/scroller/digi. Everything here is
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
        jsr ui_play_init        ; static layout + backdrop (ui/text modules)
        jsr figure_init
        jsr scroller_init
        lda zp_routine
        jsr play_announce       ; spoken title (digi module)
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

play_announce:
        lda zp_routine
        clc
        adc #DIGI_TITLE1
        jmp digi_play

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
+       lda keys_new
        and #KEY_F1
        beq +
        lda fig_scale
        eor #1
        sta fig_scale
        jsr figure_set_scale
+       lda keys_new+1
        and #KEY_F3
        beq +
        jsr ui_toggle_lang
+       lda keys_new+1
        and #KEY_F5
        beq +
        jsr digi_toggle
+       lda keys_new+1
        and #KEY_PLUS
        beq +
        lda clock_tempo
        cmp #4
        bcs +
        adc #1
        jsr clock_set_tempo
        jsr ui_tempo
+       lda keys_new+1
        and #KEY_MINUS
        beq +
        lda clock_tempo
        beq +
        sec
        sbc #1
        jsr clock_set_tempo
        jsr ui_tempo
+       lda keys_new
        and #KEY_F7
        beq +
        lda clock_tempo
        beq +
        sec
        sbc #1
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
        lda zp_tick+1           ; hold the clock once the target tick is shown
        cmp #>TEST_TICK
        bne +
        lda zp_tick
        cmp #<TEST_TICK
        bne +
        lda #1
        sta zp_tick_hold
+
}
        lda zp_beat_flag
        beq .no_beat
        lda #0
        sta zp_beat_flag
        jsr ui_beat             ; digit, words, pips, sun pulse
        lda digi_enabled
        beq .no_beat
        jsr play_speak_count
.no_beat:
        lda zp_mv_flag
        beq .no_mv
        lda #0
        sta zp_mv_flag
        lda zp_cur_mv
        cmp #MV_SLOTS-1
        bcc +
        jmp enter_finish
+       jsr play_anim_for_slot
        jsr ui_movement         ; names, cue, stations, ray
.no_mv:
.no_tick:
        jsr scroller_frame
        jsr ui_frame            ; prefetch step, pulses, clock display
        jsr digi_frame
!ifdef DEBUG_HUD {
        jsr debug_hud
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

; spoken count: breathing slot (13) says suutte/haite on counts 1/5
play_speak_count:
        lda zp_cur_mv
        beq .none               ; warm-up: no counting
        cmp #13
        beq .breath
        lda zp_count8
        clc
        adc #DIGI_ICHI-1
        jmp digi_play
.breath:
        lda zp_count8
        cmp #1
        bne +
        lda #DIGI_SUTTE
        jmp digi_play
+       cmp #5
        bne .none
        lda #DIGI_HAITE
        jmp digi_play
.none:  rts

play_quit:
        lda #0
        sta keys_new
        sta keys_new+1
        jsr music_stop
        jsr digi_stop
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
        jsr digi_stop
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
        sta zp_y
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
        rts
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
