!zone title
; ---------------------------------------------------------------
; title.asm — title and finish screens (scaffold version)
; ---------------------------------------------------------------

txt_title:   !scr "radio taiso 64", $ff
txt_sub:     !scr "asa no march / hikari no march", $ff
txt_sel1:    !scr "1  radio taiso no.1", $ff
txt_sel2:    !scr "2  radio taiso no.2", $ff
txt_keys:    !scr "space:pause f1:size +/-:tempo q:quit", $ff
txt_credit:  !scr "advancing development 2026", $ff
txt_pal:     !scr "pal", $ff
txt_ntsc:    !scr "ntsc", $ff

enter_title:
        lda #ST_TITLE
        sta zp_state
        lda #COL_TEXT
        jsr screen_clear
        +print 13,  3, txt_title,  COL_BRASS
        +print  5,  5, txt_sub,    COL_DIM
        +print 10, 10, txt_sel1,   COL_TEXT
        +print 10, 12, txt_sel2,   COL_TEXT
        +print  2, 21, txt_keys,   COL_DIM
        +print  7, 23, txt_credit, COL_GREY
        lda zp_ntsc
        beq +
        +print 36, 0, txt_ntsc, COL_DIM
        rts
+       +print 37, 0, txt_pal, COL_DIM
        rts

; one call per frame while in ST_TITLE
step_title:
        lda keys_new
        and #KEY_1
        beq +
        lda #0
        sta zp_routine
        jmp .go
+       lda keys_new
        and #KEY_2
        beq +
        lda #1
        sta zp_routine
        jmp .go
+       lda keys_new+1
        and #JOY_FIRE
        beq +
        jmp .go
+       lda keys_new
        and #(KEY_RETURN|KEY_SPACE)
        beq +
.go:    lda #0
        sta keys_new
        sta keys_new+1
        jmp enter_play
+       rts

enter_finish:
        lda #ST_FINISH
        sta zp_state
        +print 14, 12, txt_done, COL_BRASS
        rts
txt_done: !scr "well done", $ff

step_finish:
        lda keys_new
        ora keys_new+1
        beq +
        lda #0
        sta keys_new
        sta keys_new+1
        jmp enter_title
+       rts
