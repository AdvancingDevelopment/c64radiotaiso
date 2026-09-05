!zone init
; ---------------------------------------------------------------
; init.asm — one-time setup: all-RAM config, vectors, staging copy,
; VIC bank 1, colours, PAL/NTSC detection.
; ---------------------------------------------------------------

hw_init:
        lda #$35            ; I/O in, BASIC + KERNAL out (all RAM)
        sta CPU_PORT
        lda #$7f            ; no CIA interrupts
        sta CIA1_ICR
        sta CIA2_ICR
        lda CIA1_ICR        ; ack anything pending
        lda CIA2_ICR
        lda #<irq_handler
        sta VEC_IRQ
        lda #>irq_handler
        sta VEC_IRQ+1
        lda #<nmi_handler
        sta VEC_NMI
        lda #>nmi_handler
        sta VEC_NMI+1
        lda #<start
        sta VEC_RESET
        lda #>start
        sta VEC_RESET+1
        lda #$ff            ; keyboard columns are outputs, rows inputs
        sta CIA1_DDRA
        lda #0
        sta CIA1_DDRB
        ; VIC bank 1 ($4000-$7fff)
        lda CIA2_DDRA
        ora #3
        sta CIA2_DDRA
        lda CIA2_PRA
        and #$fc
        ora #VIC_BANK_BITS
        sta CIA2_PRA
        lda #VIC_MEMPTR_VAL
        sta VIC_MEMPTR
        lda #%11001000      ; hires, 40 columns, no x-scroll
        sta VIC_CTRL2
        lda #%00011011      ; 25 rows, display on, y-scroll 3, raster msb 0
        sta VIC_CTRL1
        lda #0
        sta VIC_SPR_ENABLE
        sta VIC_SPR_MC
        sta VIC_SPR_PRIO    ; sprites in front of chars
        sta VIC_SPR_MSB
        lda #COL_BG
        sta BORDER
        sta BACKGROUND
        ; silence SID
        ldx #$18
        lda #0
-       sta SID_BASE,x
        dex
        bpl -
        rts


; Sets zp_ntsc: 0 = PAL (312 lines), 1 = NTSC (263 lines).
; While the raster is in lines >= 256 ($d011 bit 7 set), track the
; max $d012 seen. PAL reaches 311 (low byte $37); NTSC only 262.
detect_pal:
        lda #0
        sta zp_tmp
-       lda VIC_CTRL1       ; wait for raster high bit
        bpl -
--      lda VIC_CTRL1
        bpl +               ; wrapped back below 256 — done
        lda VIC_RASTER
        cmp zp_tmp
        bcc --
        sta zp_tmp
        bcs --
+       lda zp_tmp
        cmp #$20            ; > $20 => PAL
        lda #0
        adc #0
        eor #1              ; carry set (PAL) -> 0, clear (NTSC) -> 1
        sta zp_ntsc
        ; system-dependent layout values
        tax
        lda scroll_line_tbl,x
        sta scroll_min_line
        lda scr_y_tbl,x
        sta scr_y_min
        lda waist2_tbl,x
        sta fig_waist_y2
        lda waist1_tbl,x
        sta fig_waist_y1
        stx ui_dy               ; NTSC: backdrop bottom + stations one row higher
        lda border_line_tbl,x
        sta irq_lines+5         ; bottom entry (24-row switch) line
        lda scroll_line_tbl,x
        sta irq_lines+4         ; scroller entry line until the figure publishes one
        rts
scroll_line_tbl: !byte LINE_SCROLL_PAL, LINE_SCROLL_NTSC
border_line_tbl: !byte LINE_BORDER, LINE_BORDER_NTSC
scr_y_tbl:       !byte SCR_Y_PAL, SCR_Y_NTSC
; NTSC has no visible bottom border: the figure stands 8 px higher so the
; shin sprites finish before the (in-picture) scroller line
waist2_tbl:      !byte FIG_WAIST_Y2, FIG_WAIST_Y2-8
waist1_tbl:      !byte FIG_WAIST_Y1, FIG_WAIST_Y1-8
scroll_min_line: !byte LINE_SCROLL_PAL
scr_y_min:       !byte SCR_Y_PAL
fig_waist_y2:    !byte FIG_WAIST_Y2
fig_waist_y1:    !byte FIG_WAIST_Y1
ui_dy:           !byte 0
