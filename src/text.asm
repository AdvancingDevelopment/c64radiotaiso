!zone text
; ---------------------------------------------------------------
; text.asm — the PLAY screen: static layout, Japanese glyph
; streaming (rows 2-3), count block (cols 1-6), set/pips block
; (cols 32-39), stations (row 21), sunrise backdrop (rows 4-20),
; elapsed clock / tempo (row 0) and the pause overlay (rows 22-24).
;
; Hooks called by play.asm: ui_play_init, ui_movement, ui_beat,
; ui_frame, ui_tempo, ui_toggle_lang, ui_pause_show, ui_pause_hide.
; Data: gen_glyphs.asm (glyph bitmaps + string tables) and
; gen_backdrop.asm (tiles, sun rect, ray cell lists).
;
; Japanese text uses three RAM areas of the charset: A ($80-$bf) and
; B ($c0-$ff) hold 16 glyphs each and double-buffer the name on
; rows 2-3 — while slot k is shown from one area, slot k+1's glyphs
; are copied into the other (jp_prefetch_step, 2 glyphs per frame);
; the swap is a redraw of rows 2-3 with the other area's codes.
; Area C ($70-$7f) holds the kana count word (<= 4 glyphs).
; A glyph = 4 consecutive codes TL,TR,BL,BR = one 32-byte copy.
;
; Zero page $50-$5f. zp_tmp is clobbered by the IRQ (clock/input),
; so this module never uses it.
; Test builds: -DTEST_GLYPHSHEET=n shows glyphs 32n..32n+31 on rows
; 2-5 instead of the play texts; -DTEST_LANG=1 starts with the Japanese
; emphasis (as after F3); -DTEST_PAUSE=n pauses at frame n (pause
; overlay); -DTEST_SCRDBG=1 (with DEBUG_HUD=1) shows the scroller state.
; ---------------------------------------------------------------

; zero page symbols ($50-$5f) are defined in title.asm, which main.asm
; assembles first (forward references would force 16-bit addressing)

UI_ROW_NAME     = 1
UI_ROW_JP       = 2
UI_ROW_DIGIT    = 8             ; 3x5 big digit, rows 8-12
UI_ROW_SET      = 12            ; "set n/m"
UI_ROW_PIPS     = 13            ; 8 beat pips
UI_ROW_KANA     = 14            ; kana count word, rows 14-15
UI_ROW_ROMAJI   = 17
UI_ROW_STATIONS = 21
UI_COL_SET      = 32
UI_COL_PIPS     = 32
UI_COL_STATION0 = 8             ; stations at cols 8,10,..,32
UI_COL_TEMPO    = 18
UI_COL_CLOCK    = 35
AREA_A_CODE     = $80           ; charset codes of area A (B = $c0)
AREA_B_HI       = >(CHARSET + $c0*8)   ; $4e: page of area B bitmaps
AREA_C_ADDR     = CHARSET + $70*8
BD_TILES_ADDR   = CHARSET + $50*8
ST_COL_ADDR     = COLOR_RAM + UI_ROW_STATIONS*40 + UI_COL_STATION0 - 2  ; + 2*mv

; ---------------------------------------------------------------
; hooks
; ---------------------------------------------------------------
ui_play_init:
        lda #$ff
        sta pf_slot
        lda #0
        sta pf_n
        sta jp_n
        sta rays_lit
        sta ui_sec
        sta ui_min
        sta ui_fcnt
        sta sun_t
        sta pulse_t
        lda zp_frame
        sta ui_lastframe
        lda #AREA_A_CODE
        sta jp_act_code
        lda #AREA_B_HI
        sta jp_inact_hi
!ifdef TEST_LANG {
        lda #1
        sta ui_lang
}
        ; row 0: routine title, tempo, elapsed clock
        +print 0, 0, txt_title0, COL_BRASS
        lda zp_routine
        clc
        adc #$31
        sta SCREEN+15
        lda #COL_BRASS
        sta COLOR_RAM+15
        jsr ui_tempo
        lda #COL_BRASS
        sta COLOR_RAM+UI_COL_CLOCK
        sta COLOR_RAM+UI_COL_CLOCK+1
        sta COLOR_RAM+UI_COL_CLOCK+2
        sta COLOR_RAM+UI_COL_CLOCK+3
        jsr clock_draw
        jsr bd_draw
        jsr stations_draw
!ifdef TEST_GLYPHSHEET {
        ; glyphs 32n..32n+31 into areas A+B (contiguous), 16 per 2 rows
        ldx #0
-       stx zp_uidx
        txa
        clc
        adc #TEST_GLYPHSHEET*32
        cmp #GLYPH_COUNT
        bcc +
        lda #0
+       jsr glyph_addr
        lda #<(CHARSET+AREA_A_CODE*8)
        sta zp_gdst
        lda #>(CHARSET+AREA_A_CODE*8)
        sta zp_gdst+1
        lda zp_uidx
        jsr slot_offset
        jsr copy32
        ldx zp_uidx
        inx
        cpx #32
        bne -
        lda #COL_TEXT
        sta zp_ucol
        lda #4
        sta zp_x
        lda #2
        sta zp_y
        lda #AREA_A_CODE
        ldx #16
        jsr glyph_line
        lda #4
        sta zp_x
        sta zp_y
        lda #AREA_A_CODE+$40
        ldx #16
        jsr glyph_line
}
        rts

txt_title0: !scr "radio taiso no.", $ff

; slot changed: row 1, rows 2-3, stations, rays, set, scroller text
ui_movement:
!ifdef TEST_GLYPHSHEET {
        rts
}
        jsr ui_row1
        jsr jp_show
        jsr stations_draw
        jsr rays_update
        jsr set_draw
        jsr mv_index
        txa
        jmp scroller_set_text

; new beat: big digit, romaji, kana, pips, set, sun/station pulses
ui_beat:
!ifdef TEST_GLYPHSHEET {
        rts
}
        jsr digit_draw
        jsr romaji_draw
        jsr kana_draw
        jsr pips_draw
        jsr set_draw
        lda zp_count8
        cmp #1
        bne +
        lda #COL_BRASS
        jsr sun_colour
        lda #3
        sta sun_t
+       lda zp_cur_mv
        beq +
        cmp #MV_SLOTS-1
        bcs +
        asl
        tax
        lda #COL_TEXT
        sta ST_COL_ADDR,x
        lda #6
        sta pulse_t
+       rts

; every frame: glyph prefetch, elapsed clock, pulse decays
ui_frame:
!ifdef TEST_GLYPHSHEET {
        rts
}
        jsr jp_prefetch_step
!ifdef TEST_PAUSE {
        lda zp_frame
        cmp #TEST_PAUSE
        bne +
        lda zp_state
        cmp #ST_PLAY
        bne +
        jsr enter_pause
+
}
        lda zp_frame
        sec
        sbc ui_lastframe        ; frames since the last call
        ldx zp_frame
        stx ui_lastframe
        ldx zp_tick_hold
        bne .pulses             ; paused: the clock holds
        clc
        adc ui_fcnt
        sta ui_fcnt
        ldx zp_ntsc
        cmp fps_tbl,x
        bcc .pulses
        sbc fps_tbl,x
        sta ui_fcnt
        inc ui_sec
        lda ui_sec
        cmp #60
        bne +
        lda #0
        sta ui_sec
        inc ui_min
+       jsr clock_draw
.pulses:
        lda sun_t
        beq +
        dec sun_t
        bne +
        lda #COL_SUN
        jsr sun_colour
+       lda pulse_t
        beq +
        dec pulse_t
        bne +
        lda zp_cur_mv
        asl
        tax
        lda #COL_VERMILLION
        sta ST_COL_ADDR,x
+
!ifdef TEST_SCRDBG {            ; row 23: scr_idx mode n pos pending x1
        lda #0
        sta zp_x
        lda #23
        sta zp_y
        jsr cell_ptr
        ldy #0
        lda scr_idx
        jsr put_hex
        iny
        lda scr_mode
        jsr put_hex
        iny
        lda scr_n
        jsr put_hex
        iny
        lda scr_pos
        jsr put_hex
        iny
        lda scr_pending
        jsr put_hex
        iny
        lda scr_x_hi+1
        jsr put_hex
        lda scr_x_lo+1
        jsr put_hex
        iny
        lda zp_sstr+1
        jsr put_hex
        lda zp_sstr
        jsr put_hex
}
        rts
fps_tbl: !byte 50, 60

; "tempo nnn%" on row 0 from clock_tempo (0..4 = 80..120 %)
ui_tempo:
        lda #0
        sta zp_y
        lda #UI_COL_TEMPO
        sta zp_x
        jsr cell_ptr
        lda #COL_DIM
        sta zp_color
        lda #<txt_tempo
        sta zp_ustr
        lda #>txt_tempo
        sta zp_ustr+1
        ldy #0
        jsr puts
        ldx clock_tempo
        lda tempo_hund,x
        sta (zp_ptr),y
        lda zp_color
        sta (zp_ptr2),y
        iny
        lda tempo_tens,x
        jsr put_dec2
        lda #$25                ; %
        sta (zp_ptr),y
        lda zp_color
        sta (zp_ptr2),y
        dey
        sta (zp_ptr2),y
        dey
        sta (zp_ptr2),y
        rts
txt_tempo:  !scr "tempo ", $ff
tempo_hund: !byte $20, $20, $31, $31, $31
tempo_tens: !byte 80, 90, 0, 10, 20

; F3: swap the colour emphasis between row 1 and rows 2-3
ui_toggle_lang:
        lda ui_lang
        eor #1
        sta ui_lang
        jsr ui_row1
        lda #UI_ROW_JP
        sta zp_y
        lda #0
        sta zp_x
        jsr cell_ptr
        jsr jp_colour
        ldy #79
-       sta (zp_ptr2),y
        dey
        bpl -
        rts

; pause overlay in the scroller zone (rows 22-24)
ui_pause_show:
        jsr scroller_hide
        +print 17, 22, txt_paused, COL_BRASS
        +print  5, 23, txt_help1, COL_DIM
        +print  6, 24, txt_help2, COL_DIM
        rts
ui_pause_hide:
        lda #22
        sta zp_y
        lda #3
        jsr rows_clear
        jmp scroller_show
txt_paused: !scr "paused", $ff
txt_help1:  !scr "space:resume  q:quit  f1:size", $ff
txt_help2:  !scr "f3:lang  f5:voice  +/-:tempo", $ff

; finish screen texts (called by title.asm's enter_finish)
ui_finish:
        lda #MV_SLOTS-1
        sta zp_cur_mv
        jsr ui_row1             ; "well done!"
        jsr jp_show             ; お疲れさまでした
        jsr stations_draw       ; all done -> brass
        jsr rays_update         ; all 13 rays lit
        lda #COL_BRASS
        jsr sun_colour
        lda #0
        sta sun_t
        sta pulse_t
        jsr set_draw            ; clears "set n/m"
        ; clear the count block (rows 8-17, cols 1-6) and the pips
        lda #UI_ROW_DIGIT
        sta zp_y
--      lda #1
        sta zp_x
        jsr cell_ptr
        ldy #5
        lda #$20
-       sta (zp_ptr),y
        dey
        bpl -
        inc zp_y
        lda zp_y
        cmp #UI_ROW_ROMAJI+1
        bne --
        lda #UI_ROW_PIPS
        sta zp_y
        lda #UI_COL_PIPS
        sta zp_x
        jsr cell_ptr
        ldy #7
        lda #$20
-       sta (zp_ptr),y
        dey
        bpl -
        jsr mv_index
        txa
        jmp scroller_set_text

; ---------------------------------------------------------------
; row 1: "n/13 " (brass) + English name
; ---------------------------------------------------------------
ui_row1:
        lda #UI_ROW_NAME
        sta zp_y
        lda #1
        jsr rows_clear
        lda #0
        sta zp_x
        lda #UI_ROW_NAME
        sta zp_y
        jsr cell_ptr
        ldy #0
        lda zp_cur_mv
        beq .name
        cmp #MV_SLOTS-1
        bcs .name
        lda #COL_BRASS
        sta zp_color
        lda zp_cur_mv
        cmp #10
        bcc +
        sbc #10
        pha
        lda #$31
        sta (zp_ptr),y
        lda zp_color
        sta (zp_ptr2),y
        iny
        pla
+       ora #$30
        sta (zp_ptr),y
        lda zp_color
        sta (zp_ptr2),y
        iny
        lda #<txt_of13
        sta zp_ustr
        lda #>txt_of13
        sta zp_ustr+1
        jsr puts
.name:  jsr mv_index
        lda mv_name_lo,x
        sta zp_ustr
        lda mv_name_hi,x
        sta zp_ustr+1
        ldx ui_lang
        lda lang_tbl,x
        sta zp_color
        jmp puts
txt_of13: !scr "/13 ", $ff
lang_tbl: !byte COL_TEXT, COL_GREY   ; [ui_lang] = English colour; Japanese = the other

; A = colour of the Japanese name
jp_colour:
        lda ui_lang
        eor #1
        tax
        lda lang_tbl,x
        rts

; X = routine*15 + zp_cur_mv (index into the mv_* tables)
mv_index:
        lda zp_cur_mv
mv_index_a:                     ; X = routine*15 + A
        ldx zp_routine
        beq +
        clc
        adc #MV_SLOTS
+       tax
        rts

; print the $ff-terminated string at zp_ustr to (zp_ptr),y in zp_color;
; Y advances, zp_ustr is consumed
puts:
        ldx #0
-       lda (zp_ustr,x)
        cmp #$ff
        beq +
        sta (zp_ptr),y
        lda zp_color
        sta (zp_ptr2),y
        iny
        inc zp_ustr
        bne -
        inc zp_ustr+1
        bne -
+       rts

; ---------------------------------------------------------------
; Japanese glyphs
; ---------------------------------------------------------------
; A = glyph index -> zp_gsrc = glyph_data + A*32 (glyph_data is page aligned)
glyph_addr:
        pha
        lsr
        lsr
        lsr
        clc
        adc #>glyph_data
        sta zp_gsrc+1
        pla
        asl
        asl
        asl
        asl
        asl
        sta zp_gsrc
        rts

; zp_gdst += A*32 (A = 0..15)
slot_offset:
        ldx #0
        stx zp_utmp
        asl
        rol zp_utmp
        asl
        rol zp_utmp
        asl
        rol zp_utmp
        asl
        rol zp_utmp
        asl
        rol zp_utmp
        clc
        adc zp_gdst
        sta zp_gdst
        lda zp_utmp
        adc zp_gdst+1
        sta zp_gdst+1
        rts

copy32:
        ldy #31
-       lda (zp_gsrc),y
        sta (zp_gdst),y
        dey
        bpl -
        rts

; draw X glyphs as 2x2 cells from char code A at (zp_x, zp_y), colour zp_ucol
glyph_line:
        sta zp_ucode
        stx zp_ucnt
        jsr cell_ptr
        ldy #0
.g:     lda zp_ucode
        sta (zp_ptr),y          ; TL
        lda zp_ucol
        sta (zp_ptr2),y
        iny
        lda zp_ucode
        clc
        adc #1
        sta (zp_ptr),y          ; TR
        lda zp_ucol
        sta (zp_ptr2),y
        tya
        clc
        adc #39
        tay                     ; row below, left cell
        lda zp_ucode
        clc
        adc #2
        sta (zp_ptr),y          ; BL
        lda zp_ucol
        sta (zp_ptr2),y
        iny
        lda zp_ucode
        clc
        adc #3
        sta (zp_ptr),y          ; BR
        lda zp_ucol
        sta (zp_ptr2),y
        tya
        sec
        sbc #39
        tay                     ; top row, next column
        lda zp_ucode
        clc
        adc #4
        sta zp_ucode
        dec zp_ucnt
        bne .g
        rts

; A = slot (0..14): start streaming its name into the inactive area
jp_prefetch_start:
        sta pf_slot
        jsr mv_index_a
        lda mv_jp_lo,x
        sta pf_str
        lda mv_jp_hi,x
        sta pf_str+1
        ldy #0
        lda (pf_str),y
        sta pf_n
        sty pf_i
        rts

; copy up to two glyphs per call (main loop, every frame)
jp_prefetch_step:
        lda #2
        sta pf_burst
.next:  lda pf_slot
        bmi .done
        lda pf_i
        cmp pf_n
        bcs .done
        tay
        iny
        lda (pf_str),y
        jsr glyph_addr
        lda #0
        sta zp_gdst
        lda jp_inact_hi
        sta zp_gdst+1
        lda pf_i
        jsr slot_offset
        jsr copy32
        inc pf_i
        dec pf_burst
        bne .next
.done:  rts

; show zp_cur_mv's Japanese name on rows 2-3: finish the prefetch (or do
; it now if another slot was pending), swap areas, draw, prefetch slot+1
jp_show:
        lda pf_slot
        cmp zp_cur_mv
        beq .wait
        lda zp_cur_mv
        jsr jp_prefetch_start
.wait:  lda pf_i
        cmp pf_n
        bcs .go
        jsr jp_prefetch_step
        jmp .wait
.go:    lda jp_act_code
        eor #$40
        sta jp_act_code
        lda jp_inact_hi
        eor #$02
        sta jp_inact_hi
        lda pf_n
        sta jp_n
        jsr jp_draw
        lda #$ff
        sta pf_slot
        lda #0
        sta pf_n
        lda zp_cur_mv
        cmp #MV_SLOTS-1
        bcs +
        clc
        adc #1
        jsr jp_prefetch_start
+       rts

; rows 2-3 from the active area, centred (start col 20-n)
jp_draw:
        lda #UI_ROW_JP
        sta zp_y
        lda #2
        jsr rows_clear
        lda #UI_ROW_JP
        sta zp_y
        lda #20
        sec
        sbc jp_n
        sta zp_x
        jsr jp_colour
        sta zp_ucol
        lda jp_act_code
        ldx jp_n
        jmp glyph_line

; ---------------------------------------------------------------
; count block (cols 1-6) and set/pips block (cols 32-39)
; ---------------------------------------------------------------
; big digit: 3x5 "pixels", each 2 cells wide, rows 8-12
digit_draw:
        lda #UI_ROW_DIGIT
        sta zp_y
        lda #1
        sta zp_x
        jsr cell_ptr
        lda zp_count8
        sec
        sbc #1
        sta zp_utmp
        asl
        asl
        adc zp_utmp             ; *5
        tax
        ldy #0
        lda #5
        sta zp_ucnt
.row:   lda digit_font,x
        sta zp_utmp
        lda #3
        sta zp_utmp2
.bit:   asl zp_utmp
        lda #$20
        bcc +
        lda #TILE_BLOCK
+       sta (zp_ptr),y
        iny
        sta (zp_ptr),y
        iny
        dec zp_utmp2
        bne .bit
        tya
        clc
        adc #34
        tay
        inx
        dec zp_ucnt
        bne .row
        rts
digit_font:                     ; bits 7-5 = the 3 pixels of a row
!byte $40,$c0,$40,$40,$e0       ; 1
!byte $e0,$20,$e0,$80,$e0       ; 2
!byte $e0,$20,$e0,$20,$e0       ; 3
!byte $a0,$a0,$e0,$20,$20       ; 4
!byte $e0,$80,$e0,$20,$e0       ; 5
!byte $e0,$80,$e0,$a0,$e0       ; 6
!byte $e0,$20,$20,$20,$20       ; 7
!byte $e0,$a0,$e0,$a0,$e0       ; 8

; romaji word centred in cols 1-6 of row 17
romaji_draw:
        lda #UI_ROW_ROMAJI
        sta zp_y
        lda #1
        sta zp_x
        jsr cell_ptr
        ldy #5
        lda #$20
-       sta (zp_ptr),y
        dey
        bpl -
        ldx zp_count8
        dex
        lda romaji_lo,x
        sta zp_ustr
        lda romaji_hi,x
        sta zp_ustr+1
        ldy #0
-       lda (zp_ustr),y
        cmp #$ff
        beq +
        iny
        bne -
+       sty zp_utmp
        lda #6
        sec
        sbc zp_utmp
        lsr
        tay
        lda #COL_GREY
        sta zp_color
        jmp puts

; kana word: glyphs into area C, drawn on rows 14-15 centred in cols 1-6
kana_draw:
        ldx zp_count8
        dex
        lda kana_lo,x
        sta zp_ustr
        lda kana_hi,x
        sta zp_ustr+1
        ldy #0
        lda (zp_ustr),y
        sta kana_n
.copy:  iny
        sty zp_utmp2
        lda (zp_ustr),y
        jsr glyph_addr
        lda #<AREA_C_ADDR
        sta zp_gdst
        lda #>AREA_C_ADDR
        sta zp_gdst+1
        lda zp_utmp2
        sec
        sbc #1
        jsr slot_offset
        jsr copy32
        ldy zp_utmp2
        cpy kana_n
        bne .copy
        ; clear rows 14-15 cols 1-6
        lda #UI_ROW_KANA
        sta zp_y
        lda #1
        sta zp_x
        jsr cell_ptr
        ldy #5
        lda #$20
-       sta (zp_ptr),y
        dey
        bpl -
        ldy #45
-       sta (zp_ptr),y
        dey
        cpy #39
        bne -
        lda #4
        sec
        sbc kana_n
        sta zp_x
        lda #COL_VERMILLION
        sta zp_ucol
        lda #$70
        ldx kana_n
        jmp glyph_line

; 8 beat pips at cols 32-39 of row 13
pips_draw:
        lda #UI_ROW_PIPS
        sta zp_y
        lda #UI_COL_PIPS
        sta zp_x
        jsr cell_ptr
        ldy #0
-       tya
        cmp zp_count8
        bcs .poff
        lda #TILE_PIP_ON
        sta (zp_ptr),y
        lda #COL_BRASS
        bne .pput
.poff:  lda #TILE_PIP_OFF
        sta (zp_ptr),y
        lda #COL_DIM
.pput:  sta (zp_ptr2),y
        iny
        cpy #8
        bne -
        rts

; "set n/m" at row 12 col 32 (n = 8-count set within the slot)
set_draw:
        lda #UI_ROW_SET
        sta zp_y
        lda #UI_COL_SET
        sta zp_x
        jsr cell_ptr
        ldx zp_cur_mv
        lda mv_len_hi,x
        ora mv_len_lo,x
        beq .clear              ; finish slot has no sets
        lda #COL_DIM
        sta zp_color
        lda #<txt_set
        sta zp_ustr
        lda #>txt_set
        sta zp_ustr+1
        ldy #0
        jsr puts
        ldx zp_cur_mv
        lda zp_tick
        sec
        sbc mv_start_lo,x       ; slot lengths <= 256: the low byte suffices
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        clc
        adc #$31
        sta (zp_ptr),y
        lda zp_color
        sta (zp_ptr2),y
        iny
        lda #$2f
        sta (zp_ptr),y
        lda zp_color
        sta (zp_ptr2),y
        iny
        lda mv_len_hi,x
        beq +
        lda #4
        bne ++
+       lda mv_len_lo,x
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
++      ora #$30
        sta (zp_ptr),y
        lda zp_color
        sta (zp_ptr2),y
        rts
.clear: ldy #6
        lda #$20
-       sta (zp_ptr),y
        dey
        bpl -
        rts
txt_set: !scr "set ", $ff

; ---------------------------------------------------------------
; stations, rays, sun, backdrop
; ---------------------------------------------------------------
; row 21: 13 stations, done / current / upcoming from zp_cur_mv
stations_draw:
        lda #UI_ROW_STATIONS
        sta zp_y
        lda #UI_COL_STATION0
        sta zp_x
        jsr cell_ptr
        ldy #0
        ldx #1
-       cpx zp_cur_mv
        bcc .sdone
        beq .scur
        lda #TILE_ST_OPEN
        sta (zp_ptr),y
        lda #COL_DIM
        bne .sput
.sdone: lda #TILE_ST_DONE
        sta (zp_ptr),y
        lda #COL_BRASS
        bne .sput
.scur:  lda #TILE_ST_CUR
        sta (zp_ptr),y
        lda #COL_VERMILLION
.sput:  sta (zp_ptr2),y
        iny
        iny
        inx
        cpx #14
        bne -
        rts

; ray X (0..12) painted in colour A (cells from gen_backdrop.asm)
ray_paint:
        sta zp_ucol
        lda bd_ray_lo,x
        sta zp_ustr
        lda bd_ray_hi,x
        sta zp_ustr+1
        ldy #0
        lda (zp_ustr),y
        sta zp_ucnt
        iny
.cell:  lda (zp_ustr),y
        sta zp_y
        iny
        lda (zp_ustr),y
        sta zp_x
        iny
        lda (zp_ustr),y
        iny
        sty zp_utmp
        pha
        jsr cell_ptr
        pla
        ldy #0
        sta (zp_ptr),y
        lda zp_ucol
        sta (zp_ptr2),y
        ldy zp_utmp
        dec zp_ucnt
        bne .cell
        rts

; rays 0..zp_cur_mv-1 lit brass — incremental: normally one new ray per
; movement (rays_lit counts the lit ones); all at once after a clock jump
rays_update:
        ldx rays_lit
-       cpx zp_cur_mv
        bcs +
        cpx #13
        bcs +
        stx zp_uidx
        lda #COL_BRASS
        jsr ray_paint
        ldx zp_uidx
        inx
        stx rays_lit
        bne -
+       rts

; colour the sun rect (rows 17-20, cols 16-23) in A
sun_colour:
        sta zp_ucol
        lda #17
        sta zp_y
.r:     lda #16
        sta zp_x
        jsr cell_ptr
        ldy #7
        lda zp_ucol
-       sta (zp_ptr2),y
        dey
        bpl -
        inc zp_y
        lda zp_y
        cmp #21
        bne .r
        rts

; the whole backdrop: tiles into the charset, horizon, sun disc, dark rays
bd_draw:
        ldx #0
-       lda bd_tiles,x
        sta BD_TILES_ADDR,x
        inx
        cpx #BD_TILE_COUNT*8
        bne -
        lda #20
        sta zp_y
        lda #0
        sta zp_x
        jsr cell_ptr
        ldy #39
-       lda #TILE_FLOOR
        sta (zp_ptr),y
        lda #COL_RAY
        sta (zp_ptr2),y
        dey
        bpl -
        lda #17
        sta zp_y
        lda #0
        sta zp_utmp2
.srow:  lda #16
        sta zp_x
        jsr cell_ptr
        ldy #0
.scol:  ldx zp_utmp2
        lda bd_sun,x
        sta (zp_ptr),y
        lda #COL_SUN
        sta (zp_ptr2),y
        inc zp_utmp2
        iny
        cpy #8
        bne .scol
        inc zp_y
        lda zp_y
        cmp #21
        bne .srow
        ldx #0
-       stx zp_uidx
        lda #COL_RAY
        jsr ray_paint
        ldx zp_uidx
        inx
        cpx #13
        bne -
        rts

; elapsed m:ss at row 0 col 35
clock_draw:
        lda #0
        sta zp_y
        lda #UI_COL_CLOCK
        sta zp_x
        jsr cell_ptr
        ldy #0
        lda ui_min
        ora #$30
        sta (zp_ptr),y
        iny
        lda #$3a
        sta (zp_ptr),y
        iny
        lda ui_sec
        jmp put_dec2

; --- state ---
ui_lang:      !byte 0           ; 0 = English emphasised, 1 = Japanese
pf_slot:      !byte $ff         ; slot being prefetched ($ff = none)
pf_n:         !byte 0
pf_i:         !byte 0
pf_burst:     !byte 0
jp_act_code:  !byte AREA_A_CODE ; char code of the displayed area
jp_inact_hi:  !byte AREA_B_HI   ; bitmap page of the other area
jp_n:         !byte 0           ; glyphs shown on rows 2-3
kana_n:       !byte 0
ui_sec:       !byte 0
ui_min:       !byte 0
ui_fcnt:      !byte 0
ui_lastframe: !byte 0
rays_lit:     !byte 0           ; rays already painted brass
sun_t:        !byte 0           ; sun flash frames left
pulse_t:      !byte 0           ; station pulse frames left
