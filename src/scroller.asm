!zone scroller
; ---------------------------------------------------------------
; scroller.asm — 8-sprite Japanese glyph scroller in rows 22-24 and
; the 7-sprite 「ラジオ体操第一/第二」 logo in the top border.
;
; Scroller: sprites 0-7 at Y 226, X-expanded, Y-expanded on PAL
; (into the opened bottom border), brass, pitch 48 px (32 px glyph
; + 16 px gap, 8 sprites = 384 px). Every frame each sprite moves
; SCR_SPEED px left; when its logical X drops below -24 (fully in
; the left border) it jumps +384 and the next cell of the queue is
; converted into its slot: a 32-byte cell-order glyph becomes sprite
; rows 0-15, bytes 0-1 (TL/TR -> rows 0-7, BL/BR -> rows 8-15), or
; three 8x16 Latin half glyphs become bytes 0-2 of rows 0-15 (24 px =
; the 48-px pitch, so English text runs on without gaps).
; Queue: the movement's Japanese cue, a blank, its English cue, a
; blank, looping; scroller_set_text switches at the next load.
; Negative X uses the raster wrap (PAL 504 px / NTSC 520 px lines):
; X = 504+x is the left edge on PAL; NTSC can show -20..-9 only, so
; -8..-1 park the sprite in the left border (unexpanded at X 0).
;
; Slots: DYN_SLOTS 16-23 = scroller sprite 0-7 (one slot each — the
; load happens while the sprite is off screen, so no second buffer
; is needed), 24-30 = logo glyphs, 31 spare.
; scroller_commit runs in the IRQ at irq_lines+3 (>= 219, before the
; sprite fetch for line 226) and writes everything the 8 sprites need
; (the figure rewrites them at line 50). logo_commit runs at line 8.
; Zero page $48-$4f (plus text.asm's zp_gsrc for the glyph source).
; ---------------------------------------------------------------

SCR_SPEED       = 2             ; px per frame (tunable)
SCR_WRAP_PX     = 384           ; 8 sprites * 48 px
SCR_PARK_Y      = 250           ; hidden sprites run at 250-291 in the right border (X 350),
                                ; finished before the logo (line 8) and figure (66) commits;
                                ; never park where a running sprite gets re-pointed
LOGO_Y_PAL      = 26            ; top border: wobble 22..30, ink to 61 (lines < 20 are off most screens)
LOGO_Y_NTSC     = 52            ; title screen only: rows 0-4
LOGO_COL        = COL_BRASS
LOGO_X0         = 36            ; 7 x 44 px pitch, centred on 184

; zero page symbols ($48-$4f: zp_ssrc2, zp_sdst, zp_sstr, zp_stmp) are
; defined in title.asm (assembled first, see there)

; ---------------------------------------------------------------
scroller_init:
        lda #0
        sta scr_hidden
        sta scr_mode
        sta scr_msb
        sta scr_xexp
        lda #$ff
        sta scr_pending
        ldx zp_ntsc
        lda yexp_tbl,x
        sta scr_yexp
        lda wrap_tbl,x
        sta scr_wrap_add
        ; slots 16-23 all zero (byte 2 of each row and rows 16-20 stay 0)
        ldx #0
        txa
-       sta DYN_SLOTS,x
        sta DYN_SLOTS+$100,x
        inx
        bne -
        ; sprite i: x = -25 + 48*i (sprite 0 wraps and loads at once),
        ; pointer = slot 16+i
        lda #<(-25)
        sta scr_x_lo
        lda #>(-25)
        sta scr_x_hi
        ldx #1
-       lda scr_x_lo-1,x
        clc
        adc #48
        sta scr_x_lo,x
        lda scr_x_hi-1,x
        adc #0
        sta scr_x_hi,x
        inx
        cpx #8
        bne -
        ldx #7
-       txa
        clc
        adc #16
        sta scr_ptr,x
        dex
        bpl -
        ; queue: this routine's warm-up cue until play sets a text
        lda zp_routine
        beq +
        lda #MV_SLOTS
+       sta scr_idx
        jsr scr_load_string
        jmp scr_build
yexp_tbl: !byte $ff, 0
wrap_tbl: !byte <(504-256), <(520-256)

SCR_CUT_X0      = 64            ; where the new cue starts (px into the screen)

; A = movement table index (routine*15 + slot): cut to the new cue at
; once — English first (readable the moment the movement starts), then
; the Japanese cue, alternating. The 8 sprites are re-seated left to
; right from SCR_CUT_X0 and loaded with the first 8 cells.
scroller_set_text:
        sta scr_idx
        lda #$ff
        sta scr_pending
        lda #1                  ; English first
        sta scr_mode
        jsr scr_load_string
        sei                     ; the IRQ moves these every frame
        lda #<SCR_CUT_X0
        sta scr_x_lo
        lda #>SCR_CUT_X0
        sta scr_x_hi
        ldx #1
-       lda scr_x_lo-1,x
        clc
        adc #48
        sta scr_x_lo,x
        lda scr_x_hi-1,x
        adc #0
        sta scr_x_hi,x
        inx
        cpx #8
        bne -
        ldx #7
        lda #0
-       sta scr_load_flag,x
        dex
        bpl -
        jsr scr_build
        cli
        lda #0
        sta scr_cur
-       jsr scr_load_next
        inc scr_cur
        lda scr_cur
        cmp #8
        bne -
        rts

scroller_hide:
        lda #1
        sta scr_hidden
        rts
scroller_show:
        lda #0
        sta scr_hidden
        rts

; ---------------------------------------------------------------
; scroller_move — from the bottom IRQ (irq.asm), once per frame: move all
; eight sprites, wrap the ones that left the screen (flag them for a
; glyph load) and build the VIC shadow. Doing this in the IRQ keeps the
; eight positions consistent: when the main loop did it, the scroller
; IRQ could land mid-update (NTSC frames are short) and commit a mix of
; moved and unmoved sprites — glyphs jittering by a pixel or two.
; ---------------------------------------------------------------
scroller_move:
        ldx #7
.move:  sec
        lda scr_x_lo,x
        sbc #SCR_SPEED
        sta scr_x_lo,x
        lda scr_x_hi,x
        sbc #0
        sta scr_x_hi,x
        bpl .next               ; x >= 0
        lda scr_x_lo,x
        cmp #<(-24)
        bcs .next               ; -24..-1: still (partly) visible
        lda scr_x_lo,x
        clc
        adc #<SCR_WRAP_PX
        sta scr_x_lo,x
        lda scr_x_hi,x
        adc #>SCR_WRAP_PX
        sta scr_x_hi,x
        lda #1
        sta scr_load_flag,x     ; off-screen right now: main loop loads a glyph
.next:  dex
        bpl .move
        ; fall through
; logical x -> VIC X lo / MSB / X-expand bits
scr_build:
        lda #0
        sta scr_msb
        sta scr_xexp
        ldx #7
.b:     lda scr_x_hi,x
        bmi .neg
        beq +
        lda scr_msb
        ora bits8,x
        sta scr_msb
+       lda scr_x_lo,x
        sta scr_vx,x
        jmp .exp
.neg:   lda scr_x_lo,x
        clc
        adc scr_wrap_add
        sta scr_vx,x
        bcc .msb1               ; NTSC: 496..511
        lda zp_ntsc
        beq .msb1               ; PAL: the carry is the +256 of 480..503
        lda #0                  ; NTSC -8..-1: park unexpanded at X 0
        sta scr_vx,x
        beq .bnext
.msb1:  lda scr_msb
        ora bits8,x
        sta scr_msb
.exp:   lda scr_xexp
        ora bits8,x
        sta scr_xexp
.bnext: dex
        bpl .b
        rts
bits8:  !byte 1,2,4,8,16,32,64,128

; main loop, once per frame: load the next glyph into every sprite that
; wrapped (it sits at X >= 360, invisible, so the slot rewrite never shows)
scroller_frame:
        ldx #7
-       lda scr_load_flag,x
        beq +
        stx scr_cur
        jsr scr_load_next
        ldx scr_cur
        lda #0
        sta scr_load_flag,x
+       dex
        bpl -
        rts

; next queue cell -> slot of sprite scr_cur
scr_load_next:
        lda scr_cur
        lsr
        lsr
        clc
        adc #>DYN_SLOTS
        sta zp_sdst+1
        lda scr_cur
        and #3
        tax
        lda slot_lo,x
        sta zp_sdst
        lda scr_pending
        bmi .nopend
        sta scr_idx             ; text switch: blank, then the new cue
        lda #$ff
        sta scr_pending
        lda #0
        sta scr_mode
        jsr scr_load_string
        jmp .blank
.nopend:
        lda scr_pos
        cmp scr_n
        bcc .cell
        lda scr_mode            ; end of string: blank, other language
        eor #1
        sta scr_mode
        jsr scr_load_string
.blank: lda #0
        jsr glyph_addr
        jmp glyph_to_slot
.cell:  lda scr_mode
        bne .latin
        ldy scr_pos
        iny
        lda (zp_sstr),y
        inc scr_pos
        jsr glyph_addr
        jmp glyph_to_slot
.latin: lda scr_pos             ; 3 half glyphs at string offset 1+3*pos
        asl
        adc scr_pos
        tay
        iny
        sty zp_stmp2
        inc scr_pos
        lda #0
        sta zp_stmp             ; byte column 0..2
-       ldy zp_stmp2
        lda (zp_sstr),y
        inc zp_stmp2
        jsr latin_addr
        jsr latin_col
        inc zp_stmp
        lda zp_stmp
        cmp #3
        bne -
        rts
slot_lo: !byte 0, 64, 128, 192

; zp_sstr / scr_n / scr_pos from scr_mode (0 = Japanese, 1 = English) + scr_idx
scr_load_string:
        ldx scr_idx
        lda scr_mode
        bne +
        lda mv_cue_lo,x
        sta zp_sstr
        lda mv_cue_hi,x
        sta zp_sstr+1
        jmp ++
+       lda mv_cue_en_lo,x
        sta zp_sstr
        lda mv_cue_en_hi,x
        sta zp_sstr+1
++      ldy #0
        lda (zp_sstr),y
        sta scr_n
        sty scr_pos
        rts

; A = latin half glyph index -> zp_gsrc = latin_data + A*16
latin_addr:
        pha
        lsr
        lsr
        lsr
        lsr
        clc
        adc #>latin_data
        sta zp_gsrc+1
        pla
        asl
        asl
        asl
        asl
        clc
        adc #<latin_data
        sta zp_gsrc
        bcc +
        inc zp_gsrc+1
+       rts

; cell-order glyph at zp_gsrc -> sprite rows at zp_sdst (bytes 0-1 of
; rows 0-15; byte 2 cleared in case the slot held a Latin cell)
glyph_to_slot:
        ldx #31
-       txa
        tay
        lda (zp_gsrc),y
        ldy cell2spr,x
        sta (zp_sdst),y
        dex
        bpl -
        ldx #15
        lda #0
-       ldy row3,x
        iny
        iny
        sta (zp_sdst),y
        dex
        bpl -
        rts
cell2spr:                       ; glyph byte i -> sprite byte offset
!for i, 0, 7  { !byte i*3 }     ; TL rows 0-7  -> byte 0
!for i, 0, 7  { !byte i*3+1 }   ; TR rows 0-7  -> byte 1
!for i, 8, 15 { !byte i*3 }     ; BL rows 8-15 -> byte 0
!for i, 8, 15 { !byte i*3+1 }   ; BR rows 8-15 -> byte 1

; 8x16 half glyph at zp_gsrc -> byte column zp_stmp (0..2) of rows 0-15
latin_col:
        ldx #15
-       txa
        tay
        lda (zp_gsrc),y
        pha
        lda row3,x
        clc
        adc zp_stmp
        tay
        pla
        sta (zp_sdst),y
        dex
        bpl -
        rts
row3:   !for i, 0, 15 { !byte i*3 }
scr_y_now: !byte SCR_Y_PAL

; ---------------------------------------------------------------
; IRQ at irq_lines+3: all 8 sprite register sets for the scroller
; ---------------------------------------------------------------
; one sprite's register set, straight-line (no loop: this runs inside the
; narrow window before the 24-row border switch, see irq.asm)
!macro scr_set .n {
        lda scr_vx+.n
        sta VIC_SPR0_X+2*.n
        lda scr_y_now
        sta VIC_SPR0_X+2*.n+1
        lda scr_ptr+.n
        sta SPR_PTRS+.n
        lda #COL_BRASS
        sta VIC_SPR0_COL+.n
}
scroller_commit:
        lda scr_hidden
        beq +
        jmp .hide
+       ; the shin sprites (4/5) may still be running when this IRQ fires:
        ; the figure sets irq_lines+3 to max(shin box bottom + 1, 235), so
        ; the glyphs start 6 lines below it (never above SCR_Y). Sprites 4/5
        ; are written last, after the others (~3 raster lines in).
        lda irq_lines+3
        clc
        adc #6
        cmp scr_y_min           ; PAL 245 (border), NTSC 235 (inside the picture)
        bcs +
        lda scr_y_min
+       sta scr_y_now
        +scr_set 0
        +scr_set 1
        +scr_set 2
        +scr_set 3
        +scr_set 6
        +scr_set 7
        +scr_set 4
        +scr_set 5
        lda scr_msb
        sta VIC_SPR_MSB
        lda scr_xexp
        sta VIC_SPR_XEXP
        lda scr_yexp
        ldx zp_ntsc
        beq +
        ora #$30                ; NTSC: sprites 4/5 (shins) may still run — keep
+       sta VIC_SPR_YEXP        ; their expansion; irq.asm clears it after line 234
        lda #$ff
        sta VIC_SPR_ENABLE
        rts
.hide:  ldy #14                 ; park all 8 in the right border (X 350)
-       lda #<350
        sta VIC_SPR0_X,y
        lda #SCR_PARK_Y         ; and at a Y no raster low byte matches
        sta VIC_SPR0_X+1,y      ; before the logo sets it again at line 8
        dey
        dey
        bpl -
        lda #$ff
        sta VIC_SPR_MSB
        lda #0
        sta VIC_SPR_XEXP
        rts

; ---------------------------------------------------------------
; logo: 7 glyphs of title_jp[A] converted into slots 24-30
; ---------------------------------------------------------------
logo_show:                      ; A = routine
        tax
        lda title_jp_lo,x
        sta zp_ssrc2
        lda title_jp_hi,x
        sta zp_ssrc2+1
        ldx #0
        txa
-       sta DYN_SLOTS+$200,x    ; slots 24-31 clear
        sta DYN_SLOTS+$300,x
        inx
        bne -
-       stx zp_stmp
        txa
        tay
        iny
        lda (zp_ssrc2),y
        jsr glyph_addr
        lda zp_stmp
        lsr
        lsr
        clc
        adc #>(DYN_SLOTS+$200)
        sta zp_sdst+1
        lda zp_stmp
        and #3
        tax
        lda slot_lo,x
        sta zp_sdst
        jsr glyph_to_slot
        ldx zp_stmp
        inx
        cpx #7
        bne -
        lda #1
        sta logo_on
        ; fall through: static Y table

; main loop: the 7 sprite Y values (wobble on the title, else static).
; Computed here so that the line-8 IRQ only copies registers — the
; sprites' Y compare lines (15..23) are only a few lines after line 8.
logo_frame:
        lda #LOGO_Y_PAL
        ldx zp_ntsc
        beq +
        lda #LOGO_Y_NTSC
+       sta logo_ybase
        ldx #6
.y:     lda logo_ybase
        ldy zp_state
        cpy #ST_TITLE
        bne .st
        txa                     ; index = (phase + 9*sprite) & 63
        asl
        asl
        asl
        stx zp_stmp2
        adc zp_stmp2
        adc logo_phase
        and #63
        tay
        lda logo_sine,y
        clc
        adc logo_ybase
        sec
        sbc #4
.st:    sta logo_y,x
        dex
        bpl .y
        inc logo_phase
        rts

logo_hide:
        lda #0
        sta logo_on
        rts

; IRQ line 8: sprites 0-6 = logo (PAL: top border; NTSC: title screen
; only, inside the visible area), sprite 7 parked. Y registers first.
logo_commit:
        lda logo_on
        beq .out
        ldx zp_ntsc
        beq +
        lda zp_state
        cmp #ST_TITLE
        bne .out
+       ldx #6
        ldy #12
-       lda logo_y,x
        sta VIC_SPR0_X+1,y
        dey
        dey
        dex
        bpl -
        ldx #6
        ldy #12
-       lda logo_x_lo,x
        sta VIC_SPR0_X,y
        txa
        clc
        adc #24
        sta SPR_PTRS,x
        lda #LOGO_COL
        sta VIC_SPR0_COL,x
        dey
        dey
        dex
        bpl -
        lda #<350
        sta VIC_SPR0_X+14       ; sprite 7 parked in the right border
        lda #%11100000          ; MSB: sprites 5, 6 (X >= 256) and 7
        sta VIC_SPR_MSB
        lda #$ff
        sta VIC_SPR_XEXP
        sta VIC_SPR_YEXP
        sta VIC_SPR_ENABLE
.out:   rts
logo_x_lo: !for i, 0, 6 { !byte <(LOGO_X0 + 44*i) }
logo_sine: !for i, 0, 63 { !byte int(4.5 + 4.0 * sin(float(i) * 6.2831853 / 64.0)) }

; --- state ---
scr_hidden:   !byte 1
scr_x_lo:     !fill 8, 0        ; logical X, signed 16 bit
scr_x_hi:     !fill 8, 0
scr_load_flag: !fill 8, 0       ; set by scroller_move (IRQ), cleared by scroller_frame
scr_vx:       !fill 8, 0        ; VIC X low bytes
scr_ptr:      !fill 8, 0        ; sprite pointers (slot numbers)
scr_msb:      !byte 0
scr_xexp:     !byte 0
scr_yexp:     !byte 0
scr_wrap_add: !byte 0
scr_cur:      !byte 0
scr_pos:      !byte 0           ; next cell of the current string
scr_n:        !byte 0           ; cells in the current string
scr_mode:     !byte 0           ; 0 = Japanese cue, 1 = English cue
scr_idx:      !byte 0           ; movement table index of the queue
scr_pending:  !byte $ff         ; index to switch to ($ff = none)
logo_on:      !byte 0
logo_phase:   !byte 0
logo_ybase:   !byte 0
logo_y:       !fill 7, 0        ; sprite Y per logo glyph
