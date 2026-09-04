!zone irq
; ---------------------------------------------------------------
; irq.asm — table-driven raster IRQ chain (one entry per raster
; event, all lines < 256, ascending). Entries 2 and 3 (shin split,
; scroller) are rewritten per tick by figure.asm.
;   0 line 8    irq_top      logo sprites, back to 25-row mode
;   1 line 50   irq_figure   commit figure sprite block
;   2 split     irq_split    sprites 4/5 become the shins
;   3 scroller  irq_scroll   sprites 0-7 become the glyph scroller
;   4 line 249  irq_bottom   24-row mode (the vertical border never closes),
;                            then clock, music, input, frame counter
; Rules learned the hard way: never write a $d011 value that carries the
; current raster bit 8 (it becomes the compare MSB), and ack the raster
; flag before running a late entry by hand — the VIC compares every
; cycle, so writing a compare value equal to the current line raises the
; flag immediately and would dispatch that entry twice.
; ---------------------------------------------------------------

irq_init:                       ; call with interrupts disabled
        lda #0
        sta irq_idx
        lda irq_lines
        sta VIC_RASTER
        lda VIC_CTRL1
        and #$7f
        sta VIC_CTRL1
        lda #$0f
        sta VIC_IRQFLAG     ; ack all
        lda #1
        sta VIC_IRQMASK     ; raster IRQ on
        rts

irq_handler:
        pha
        txa
        pha
        tya
        pha
        cld
        lda VIC_IRQFLAG
        sta VIC_IRQFLAG     ; ack whatever fired
        and #1
        beq .done           ; not the raster (spurious) — leave
.dispatch:
        ldx irq_idx
!ifdef RASTER_DEBUG {
        lda irq_dbg_col,x
        sta BORDER
}
        lda irq_vec_lo,x
        sta zp_irq_jmp
        lda irq_vec_hi,x
        sta zp_irq_jmp+1
        jsr .call
!ifdef RASTER_DEBUG {
        lda #COL_BG
        sta BORDER
}
        ldx irq_idx
        inx
        cpx #IRQ_ENTRIES
        bne +
        ldx #0
+       stx irq_idx
        lda irq_lines,x
        sta VIC_RASTER
        ; if that line has already passed (a late handler), run it now
        cpx #0
        bne +
        ; entry 0 belongs to the next frame: late only if the raster has
        ; already wrapped past LINE_TOP (bottom IRQ overran the frame end)
        bit VIC_CTRL1
        bmi .done           ; raster bit 8: still in lines 256+ of this frame
        lda VIC_RASTER
        cmp #LINE_TOP
        bcc .done           ; new frame, before line 8: on time
        cmp #LINE_BORDER
        bcs .done           ; this frame, lines 249..255
        bcc .late           ; wrapped past line 8: run it now
+       cmp VIC_RASTER
        bcc .late           ; next line <= current raster: run it now
        beq .late
.done:  pla
        tay
        pla
        tax
        pla
        rti
.call:  jmp (zp_irq_jmp)
.late:  lda #1
        sta VIC_IRQFLAG     ; ack the flag the compare write just raised
        jmp .dispatch

; --- handlers -------------------------------------------------
irq_top:
        lda VIC_CTRL1
        and #$7f            ; never write raster bit 8 back
        ora #$08            ; 25-row mode again (top border compare)
        sta VIC_CTRL1
        jsr logo_commit
        rts

irq_figure:
        jmp figure_commit

irq_split:
        jmp figure_split

irq_scroll:
!ifdef DEBUG_HUD {
        lda VIC_RASTER          ; max raster seen at entry
        cmp irq_max_a
        bcc +
        sta irq_max_a
+
}
        jsr scroller_commit
!ifdef DEBUG_HUD {
        lda VIC_RASTER          ; max raster after the sprite writes
        cmp irq_max_b
        bcc +
        sta irq_max_b
+
}
        lda zp_ntsc
        beq +
        ; NTSC: no border to open. Clearing Y-expansion while the shin
        ; sprites (4/5) still run would crunch them, so wait for their end
-       lda VIC_RASTER
        cmp #SHIN_END_NTSC+1
        bcc -
        lda #0
        sta VIC_SPR_YEXP
        rts
+
        ; The 24-row switch that keeps the vertical border open must land in
        ; lines 248-251 (after the 24-row bottom compare at 247, before the
        ; 25-row one at 251). Doing it here right after the scroller writes
        ; gives ~3 lines of slack; the bottom entry at 249 would be too late
        ; whenever this entry is stretched by the digi NMI.
-       lda VIC_RASTER
        cmp #LINE_BORDER-1
        bcc -
        lda VIC_CTRL1
        and #$77            ; 24-row mode, raster MSB clear
        sta VIC_CTRL1
!ifdef DEBUG_HUD {
        lda VIC_CTRL1       ; count switches that landed too late (> line 251)
        bmi .latecnt
        lda VIC_RASTER
        cmp irq_max_c
        bcc ++
        sta irq_max_c
++      cmp #LINE_BORDER+3
        bcc +
.latecnt:
        inc irq_late_border
+
}
        rts

irq_bottom:
        lda VIC_CTRL1
        and #$77            ; 24-row mode again (harmless repeat, see irq_scroll)
        sta VIC_CTRL1
        inc zp_frame
        jsr clock_frame
        jsr music_frame
        jsr scroller_move       ; scroll step + shadow build (atomic vs. the commit)
        jsr input_scan
        rts

; NMI: digi player (digi.asm); before it exists, an acknowledging stub
irq_idx:     !byte 0
!ifdef DEBUG_HUD {
irq_late_border: !byte 0
irq_max_a: !byte 0
irq_max_b: !byte 0
irq_max_c: !byte 0
}
irq_lines:   !byte LINE_TOP, LINE_FIGURE, LINE_SPLIT_DEF, LINE_SCROLL_PAL, LINE_BORDER
irq_vec_lo:  !byte <irq_top, <irq_figure, <irq_split, <irq_scroll, <irq_bottom
irq_vec_hi:  !byte >irq_top, >irq_figure, >irq_split, >irq_scroll, >irq_bottom
!ifdef RASTER_DEBUG {
irq_dbg_col: !byte 2, 5, 7, 4, 10
}
