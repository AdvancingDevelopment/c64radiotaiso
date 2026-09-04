!zone ui
; ---------------------------------------------------------------
; ui.asm — screen helpers: row tables, print, clear.
; Strings are !scr, $ff-terminated.
; ---------------------------------------------------------------

row_lo: !for i, 0, 24 { !byte <(SCREEN + i*40) }
row_hi: !for i, 0, 24 { !byte >(SCREEN + i*40) }

; zp_ptr = screen address of (zp_x, zp_y); zp_ptr2 = its colour cell
cell_ptr:
        ldx zp_y
        lda row_lo,x
        clc
        adc zp_x
        sta zp_ptr
        sta zp_ptr2
        lda row_hi,x
        adc #0
        sta zp_ptr+1
        clc
        adc #COLOR_OFFSET_HI
        sta zp_ptr2+1
        rts

; print $ff-terminated string at zp_src to (zp_x, zp_y) in zp_color
ui_print:
        jsr cell_ptr
        ldy #0
-       lda (zp_src),y
        cmp #$ff
        beq +
        sta (zp_ptr),y
        lda zp_color
        sta (zp_ptr2),y
        iny
        bne -
+       rts


; clear the whole screen to spaces, colour A
screen_clear:
        sta zp_color
        ldx #0
-       lda #$20
        sta SCREEN,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$2e8,x
        lda zp_color
        sta COLOR_RAM,x
        sta COLOR_RAM+$100,x
        sta COLOR_RAM+$200,x
        sta COLOR_RAM+$2e8,x
        inx
        bne -
        rts

; clear rows zp_y .. zp_y+A-1
rows_clear:
        sta zp_len
.row:   lda #0
        sta zp_x
        jsr cell_ptr
        ldy #39
        lda #$20
-       sta (zp_ptr),y
        dey
        bpl -
        inc zp_y
        dec zp_len
        bne .row
        rts

; write byte A as two decimal digits at (zp_ptr),y (0..99)
put_dec2:
        ldx #0
-       cmp #10
        bcc +
        sbc #10
        inx
        bne -
+       pha
        txa
        ora #$30
        sta (zp_ptr),y
        iny
        pla
        ora #$30
        sta (zp_ptr),y
        iny
        rts
