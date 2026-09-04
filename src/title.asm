!zone title
; ---------------------------------------------------------------
; title.asm — title and finish screens.
; Title: the sprite logo (scroller.asm, wobbling in the top border
; on PAL / rows 1-4 on NTSC) over the sunrise backdrop, routine
; selection (keys 1/2, joystick up/down + fire, RETURN/SPACE),
; 第一/第二 glyphs from area A, key help, credits, PAL/NTSC tag.
; Finish: お疲れさまでした on rows 2-3, "well done!", elapsed time,
; all stations/rays brass, the finish cue in the scroller, the
; spoken phrase; any key/fire returns to the title.
; Zero page $70-$7f.
; Test builds: -DTEST_FINISH=1|2 enters the finish screen of routine
; 1|2 straight from the title (no TEST_PLAY needed).
; ---------------------------------------------------------------

zp_tsel         = zp_title+0    ; selected routine on the title
zp_ttmp         = zp_title+1

; --- zero page of the ui module (text.asm), defined here because
; title.asm is the first of the ui/scroller/text files main.asm
; assembles (a forward reference would assemble as 16-bit) ---
zp_gsrc         = zp_ui+0       ; word: glyph source (also used by scroller.asm)
zp_gdst         = zp_ui+2       ; word: glyph destination
zp_ustr         = zp_ui+4       ; word: string pointer
zp_ucnt         = zp_ui+6
zp_utmp         = zp_ui+7
zp_ucol         = zp_ui+8       ; colour for glyph_line
zp_ucode        = zp_ui+9       ; running char code for glyph_line
zp_uidx         = zp_ui+10
zp_utmp2        = zp_ui+11
pf_str          = zp_ui+12      ; word: glyph string being prefetched
; --- scroller.asm ($48-$4f) ---
zp_ssrc2        = zp_scr+0      ; word: second latin half glyph
zp_sdst         = zp_scr+2      ; word: sprite slot
zp_sstr         = zp_scr+4      ; word: current queue string
zp_stmp         = zp_scr+6
zp_stmp2        = zp_scr+7

TITLE_ROW_SEL1  = 10
TITLE_ROW_SEL2  = 13
TITLE_COL_ARROW = 7
TITLE_COL_SEL   = 9
TITLE_COL_JP    = 30

txt_t64:     !scr "radio taiso 64", $ff
txt_songs:   !scr "asa no march / hikari no march", $ff
txt_sel1:    !scr "1  radio taiso no.1", $ff
txt_sel2:    !scr "2  radio taiso no.2", $ff
txt_start:   !scr "return, space or fire: start", $ff
txt_credit:  !byte $1b, $20      ; (c) glyph
             !scr "advancing development 2026", $ff
txt_kofi:    !scr "buy me a coffee: ko-fi.com/advancing", $ff
txt_tkeys:   !scr "space:pause  q:quit  v:voice", $ff
txt_pal:     !scr "pal", $ff
txt_ntsc:    !scr "ntsc", $ff
sel_row:     !byte TITLE_ROW_SEL1, TITLE_ROW_SEL2
sel_code:    !byte AREA_A_CODE, AREA_A_CODE+8   ; 第一 / 第二 in area A
sel_txt_lo:  !byte <txt_sel1, <txt_sel2
sel_txt_hi:  !byte >txt_sel1, >txt_sel2

enter_title:
        lda #ST_TITLE
        sta zp_state
        jsr scroller_hide
        lda #COL_TEXT
        jsr screen_clear
        jsr bd_draw
        ; area A slots 0-3 = 第 一 第 二 (title_sel_glyphs, gen_glyphs.asm)
        ldx #0
-       stx zp_ttmp
        lda title_sel_glyphs,x
        jsr glyph_addr
        lda #<(CHARSET+AREA_A_CODE*8)
        sta zp_gdst
        lda #>(CHARSET+AREA_A_CODE*8)
        sta zp_gdst+1
        lda zp_ttmp
        jsr slot_offset
        jsr copy32
        ldx zp_ttmp
        inx
        cpx #4
        bne -
        +print 13,  6, txt_t64,    COL_BRASS
        +print  5,  7, txt_songs,  COL_DIM
        +print  6, 16, txt_start,  COL_GREY
        +print  6, 21, txt_tkeys,  COL_DIM
        +print  4, 22, txt_help2,  COL_DIM
        +print  6, 23, txt_credit, COL_GREY
        +print  2, 24, txt_kofi,   COL_BRASS
        lda zp_ntsc
        beq +
        +print 36, 0, txt_ntsc, COL_DIM
        jmp ++
+       +print 37, 0, txt_pal, COL_DIM
++      lda zp_routine
        sta zp_tsel
        jsr title_select
        ldx #0
        jmp music_loop_title

; draw both selection lines (colours from zp_tsel) and rebuild the logo
title_select:
        lda #0
        jsr .line
        lda #1
        jsr .line
        jmp logo_show_plain     ; ラジオ体操 (no routine number yet)
.line:  tax
        lda #COL_GREY
        cpx zp_tsel
        bne +
        lda #COL_TEXT
+       sta zp_color
        sta zp_ucol
        lda sel_row,x
        sta zp_y
        lda #TITLE_COL_ARROW
        sta zp_x
        stx zp_ttmp
        jsr cell_ptr            ; (clobbers X)
        ldx zp_ttmp
        ldy #0
        lda #$20
        cpx zp_tsel
        bne +
        lda #TILE_ARROW
+       sta (zp_ptr),y
        lda #COL_VERMILLION
        sta (zp_ptr2),y
        ldy #TITLE_COL_SEL-TITLE_COL_ARROW
        ldx zp_ttmp
        lda sel_txt_lo,x
        sta zp_ustr
        lda sel_txt_hi,x
        sta zp_ustr+1
        jsr puts
        ldx zp_ttmp
        lda #TITLE_COL_JP
        sta zp_x
        lda sel_code,x
        ldx #2
        jmp glyph_line

; one call per frame while in ST_TITLE
step_title:
!ifdef TEST_FINISH {
        lda #TEST_FINISH-1
        sta zp_routine
        jsr logo_show
        jsr enter_play
        jmp enter_finish
}
        lda keys_new
        sta zp_ttmp
        lda keys_new+1
        sta zp_ttmp+1
        lda #0
        sta keys_new
        sta keys_new+1
        lda zp_ttmp
        and #KEY_1
        beq +
        lda #0
        sta zp_tsel
        beq .go
+       lda zp_ttmp
        and #KEY_2
        beq +
        lda #1
        sta zp_tsel
        bne .go
+       lda zp_ttmp+1
        and #JOY_UP
        beq +
        lda #0
        sta zp_tsel
        jmp title_select
+       lda zp_ttmp+1
        and #JOY_DOWN
        beq +
        lda #1
        sta zp_tsel
        jmp title_select
+       lda zp_ttmp+1
        and #JOY_FIRE
        bne .go
        lda zp_ttmp
        and #(KEY_RETURN|KEY_SPACE)
        bne .go
        jmp logo_frame          ; wobble the logo (Y table for the IRQ)
.go:    lda zp_tsel
        sta zp_routine
        jsr logo_show           ; static routine logo during play
        jmp enter_play

; ---------------------------------------------------------------
enter_finish:
        lda #ST_FINISH
        sta zp_state
        jsr ui_finish           ; texts, stations, rays, sun, scroller cue
        lda #ANIM_BOW
        jsr choreo_set_anim
        lda digi_enabled
        beq +
        lda #DIGI_OTSUKARE
        jsr digi_play
+       rts

step_finish:
        lda zp_tick_flag
        beq +
        lda #0
        sta zp_tick_flag
        lda zp_tick
        and #63
        sta zp_local_tick
        jsr choreo_tick         ; the bow keeps cycling
        jsr figure_render
+       jsr scroller_frame
        jsr digi_frame
        lda keys_new
        ora keys_new+1
        beq +
        lda #0
        sta keys_new
        sta keys_new+1
        jsr music_stop
        jsr digi_stop
        jsr figure_hide
        jsr scroller_hide
        jmp enter_title
+       rts
