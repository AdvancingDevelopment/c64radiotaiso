!zone scroller
; ---------------------------------------------------------------
; scroller.asm — 8-sprite English text scroller in the bottom border
; (PAL; rows 23-24 on NTSC) and the 7-sprite ラジオ体操 logo in the
; top border of the title screen.
;
; Scroller: sprites 0-7 at Y 247 (PAL, Y-expanded into the opened
; bottom border) / 237 (NTSC), brass, X-expanded, SCR_PITCH (48) px
; apart. Each sprite carries three 8x16 half-width Latin glyphs, i.e.
; 16 px per character once expanded, so the eight sprites form one
; seamless 384 px train of 24 characters that covers the 320 px
; picture and both side borders: the text streams by continuously,
; with no gaps between sprites.
; Every frame each sprite moves SCR_SPEED px left. Once its logical X
; drops below SCR_WRAP_AT (it has left the picture) the main loop
; converts the next three characters of the queue into the sprite's
; spare slot; the bottom IRQ then, in one step, jumps the sprite
; +SCR_WRAP_PX to the right end of the train and flips its pointer to
; that slot. So a glyph is never rewritten while it is on screen, and
; position and pointer always change together (between the last
; commit of a frame and the next frame's). Each sprite has two slots:
; 16+i and 24+i (the logo uses 24-30 on the title screen, where the
; scroller is hidden; play start re-initialises them).
; Queue: the movement's English cue, SCR_GAP_CELLS blank cells, again.
; scroller_set_text cuts to a new cue: the main loop loads its first 8
; cells into the spare slots, the IRQ re-seats and flips all 8 sprites.
; Only the top/bottom border is opened, so the side borders cover the
; sprites outside X 24..343: the text slides in from behind the right
; border and out behind the left one, and a sprite that wraps from
; x <= -32 (fully behind the left border) to x+384 >= 352 (fully
; behind the right border) is never seen jumping.
; Negative X uses the raster wrap (PAL 504 px / NTSC 520 px lines):
; X = 504+x on PAL. NTSC would need X 512-519 for x = -8..-1, which do
; not exist: for those four frames the sprite sits at X 0 or X 511,
; whichever is nearer (a wobble of <= 4 px in the leftmost 16 px of
; the picture, where the text is leaving anyway).
;
; scroller_commit_pre / scroller_commit run in the IRQ (lines from
; irq_lines+3 / +4) and write everything the 8 sprites need (the
; figure rewrites them at line 66). logo_commit runs at line 8.
; Zero page $48-$4f (plus text.asm's zp_gsrc for the glyph source).
; ---------------------------------------------------------------

SCR_SPEED       = 2             ; px per frame = one expanded glyph pixel (tunable)
SCR_PITCH       = 48            ; px between sprites = the width of an X-expanded sprite
SCR_WRAP_PX     = 8*SCR_PITCH   ; the 8-sprite train wraps seamlessly (384)
SCR_WRAP_AT     = -28           ; ask for the next cell once x < this; the wrap follows a
                                ; frame later (x <= -32): the sprite (x..x+47) is behind
                                ; the left border (picture starts at X 24) and reappears
                                ; at x+384 >= 352, behind the right border (picture ends
                                ; at 343) — any wrap between -40 and -24 is invisible
SCR_GAP_CELLS   = 1             ; blank cell (3 spaces, plus the cue's padding) between repeats
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
        sta scr_msb
        sta scr_next
        sta scr_cut
        lda #1
        sta scr_unhide          ; shown from the next bottom IRQ on (see scroller_show)
        ldx zp_ntsc
        lda yexp_tbl,x
        sta scr_yexp
        lda wrap_tbl,x
        sta scr_wrap_add
        ; both slot sets (16-23 and 24-31) blank: rows 16-20 and byte 63
        ; of every slot stay 0 for good (only rows 0-15 are ever written)
        ldx #0
        txa
-       sta DYN_SLOTS,x
        sta DYN_SLOTS+$100,x
        sta DYN_SLOTS+$200,x
        sta DYN_SLOTS+$300,x
        inx
        bne -
        ; sprite i: x = SCR_WRAP_AT-2 + 48*i (sprite 0 wraps and loads at
        ; once, the rest enter blank), pointer = slot 16+i, spare = 24+i
        lda #<(SCR_WRAP_AT-2)
        sta scr_x_lo
        lda #>(SCR_WRAP_AT-2)
        sta scr_x_hi
        ldx #1
-       lda scr_x_lo-1,x
        clc
        adc #SCR_PITCH
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
        lda #0
        sta scr_load_flag,x
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
; once (readable the moment the movement starts). scr_cut = 1 holds the
; train (no wraps, no flips) while the first 8 cells are converted into
; the spare slots of sprites 0-7; scr_cut = 2 then makes the bottom IRQ
; re-seat the 8 sprites left to right from SCR_CUT_X0 and flip them all
; to the new slots, so the next commit shows the whole new text at once.
scroller_set_text:
        sta scr_idx
        lda #1
        sta scr_cut
        jsr scr_load_string
        lda #0
        sta scr_cur
-       jsr scr_load_next       ; cells 0-7 -> spare slots of sprites 0-7
        inc scr_cur
        lda scr_cur
        cmp #8
        bne -
        lda #2
        sta scr_cut
        rts

scroller_hide:                  ; at once: the next commit parks the sprites
        lda #1
        sta scr_hidden
        rts
scroller_show:                  ; deferred to the bottom IRQ, after its register
        lda #1                  ; check and before the next frame's commits, so a
        sta scr_unhide          ; shown scroller has always been committed as such
        rts

; ---------------------------------------------------------------
; scroller_move — from the bottom IRQ (irq.asm), once per frame: move all
; eight sprites, wrap (and flip) the ones whose next cell is loaded, ask
; the main loop for the cells of the ones that left the picture, apply a
; pending cut, and build the VIC shadow. Doing all of this in the IRQ
; keeps the eight positions and pointers consistent: when the main loop
; did it, the scroller IRQ could land mid-update (NTSC frames are short)
; and commit a mix of moved and unmoved sprites — glyphs jittering by a
; pixel or two. A hidden scroller (pause, title) stands still, so the
; text resumes exactly where it stopped.
; scr_load_flag: 0 idle, 1 cell requested, 2 cell loaded (wrap it now).
; ---------------------------------------------------------------
scroller_move:
        lda scr_unhide
        beq +
        lda #0
        sta scr_unhide
        sta scr_hidden
+       lda scr_cut
        beq +
        cmp #2
        beq .apply
        rts                     ; 1: a cut is being loaded — hold everything
+       lda scr_hidden
        beq +
        rts
+       ldx #7
.move:  sec
        lda scr_x_lo,x
        sbc #SCR_SPEED
        sta scr_x_lo,x
        lda scr_x_hi,x
        sbc #0
        sta scr_x_hi,x
        bpl .next               ; x >= 0
        lda scr_load_flag,x
        beq .check
        cmp #2
        bne .next               ; 1: requested, the main loop has not loaded it yet
        lda scr_x_lo,x          ; 2: the spare slot holds the next cell — wrap and flip
        clc
        adc #<SCR_WRAP_PX
        sta scr_x_lo,x
        lda scr_x_hi,x
        adc #>SCR_WRAP_PX
        sta scr_x_hi,x
        lda scr_ptr,x
        eor #8
        sta scr_ptr,x
        lda #0
        sta scr_load_flag,x
        beq .next
.check: lda scr_x_lo,x
        cmp #<SCR_WRAP_AT
        bcs .next               ; SCR_WRAP_AT..-1: still leaving the picture
        lda #1
        sta scr_load_flag,x     ; ask the main loop for the next cell
.next:  dex
        bpl .move
        jmp scr_build
.apply: lda #<SCR_CUT_X0        ; the cut: re-seat the train, flip every sprite
        sta scr_x_lo
        lda #>SCR_CUT_X0
        sta scr_x_hi
        ldx #1
-       lda scr_x_lo-1,x
        clc
        adc #SCR_PITCH
        sta scr_x_lo,x
        lda scr_x_hi-1,x
        adc #0
        sta scr_x_hi,x
        inx
        cpx #8
        bne -
        ldx #7
-       lda scr_ptr,x
        eor #8                  ; spare slot (the new cell) -> shown
        sta scr_ptr,x
        lda #0
        sta scr_load_flag,x
        dex
        bpl -
        sta scr_next            ; sprite 0 is the leftmost again
        sta scr_cut
        ; fall through
; logical x -> VIC X lo / MSB (all eight sprites are X-expanded)
scr_build:
        lda #0
        sta scr_msb
        ldx #7
.b:     lda scr_x_hi,x
        bmi .neg
        beq +
        lda scr_msb
        ora bits8,x
        sta scr_msb
+       lda scr_x_lo,x
        sta scr_vx,x
        jmp .bnext
.neg:   lda scr_x_lo,x
        clc
        adc scr_wrap_add
        sta scr_vx,x
        bcc .msb1               ; NTSC: 496..511
        ldy zp_ntsc
        beq .msb1               ; PAL: the carry is the +256 of 472..503
        ; NTSC x = -8..-1 (A = x+8): X 512..519 do not exist — use X 0
        ; for -4..-1 and X 511 for -8..-5, the nearer one (<= 4 px off)
        cmp #4
        bcs .park0
        lda #$ff
        sta scr_vx,x
        bne .msb1
.park0: lda #0
        sta scr_vx,x
        beq .bnext
.msb1:  lda scr_msb
        ora bits8,x
        sta scr_msb
.bnext: dex
        bpl .b
        rts
bits8:  !byte 1,2,4,8,16,32,64,128

; main loop, once per frame: load the next cell into every sprite that
; asked for one, in train order (scr_next = the sprite that wraps next;
; more than one is pending only after a long stall), and hand it to the
; IRQ (flag 2) for the wrap + pointer flip
scroller_frame:
        lda scr_cut
        bne .sf_done            ; a cut is being loaded: the spare slots are its
        ldx scr_next
        lda scr_load_flag,x
        cmp #1
        bne .sf_done
        stx scr_cur
        jsr scr_load_next
        ldx scr_cur
        lda #2
        sta scr_load_flag,x
        inx
        txa
        and #7
        sta scr_next
        jmp scroller_frame
.sf_done: rts

; next queue cell -> the spare slot (scr_ptr ^ 8) of sprite scr_cur:
; three half glyphs (24 bytes of rows 0-15, bytes 0-2) or a blank
scr_load_next:
        ldx scr_cur
        lda scr_ptr,x
        eor #8
        sec
        sbc #16                 ; slot - 16 = 0..15 -> DYN_SLOTS + 64*that
        pha
        lsr
        lsr
        clc
        adc #>DYN_SLOTS
        sta zp_sdst+1
        pla
        and #3
        tax
        lda slot_lo,x
        sta zp_sdst
        lda scr_pos
        cmp scr_n
        bcc .cell
        ; past the end: SCR_GAP_CELLS blanks, then the cue from the start
        inc scr_pos
        lda scr_pos
        sec
        sbc scr_n
        cmp #SCR_GAP_CELLS
        bcc +
        lda #0
        sta scr_pos
+       ldy #47                 ; rows 0-15, bytes 0-2
        lda #0
-       sta (zp_sdst),y
        dey
        bpl -
        rts
.cell:  lda scr_pos             ; 3 half glyphs at string offset 1+3*pos
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

; zp_sstr / scr_n / scr_pos from scr_idx: the movement's English cue
; (mv_cue_en: !byte cells, then 3 half glyph indices per cell)
scr_load_string:
        ldx scr_idx
        lda mv_cue_en_lo,x
        sta zp_sstr
        lda mv_cue_en_hi,x
        sta zp_sstr+1
        ldy #0
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
; rows 0-15; byte 2 cleared) — used by the logo
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
; pre-commit (IRQ at irq_lines+3, set by the figure to the line after the
; lowest of these six figure boxes ended): sprites 0-3, 6, 7 become glyph
; sprites. Only a few stores are left for the late entry below.
scroller_commit_pre:
        lda scr_hidden
        beq +
        jmp .hide_pre
+       lda scr_y_min           ; PAL 247 (border), NTSC 237 (inside the picture)
        sta scr_y_now
        +scr_set 0
        +scr_set 1
        +scr_set 2
        +scr_set 3
        +scr_set 6
        +scr_set 7
        rts
.hide_pre:
        ldx #0
-       lda #<350               ; park in the right border
        sta VIC_SPR0_X,x
        lda #SCR_PARK_Y
        sta VIC_SPR0_X+1,x
        inx
        inx
        cpx #8
        bne -
        lda #<350
        sta VIC_SPR0_X+12
        sta VIC_SPR0_X+14
        lda #SCR_PARK_Y
        sta VIC_SPR0_X+13
        sta VIC_SPR0_X+15
        rts

; IRQ at irq_lines+4 (max(shin box top + 33, scroll_min_line)): sprites 4/5
; after the shins have shown their last ink row, plus the shared registers.
scroller_commit:
        lda scr_hidden
        beq +
        jmp .hide
+       +scr_set 4
        +scr_set 5
        lda scr_msb
        sta VIC_SPR_MSB
        lda #$ff                ; every glyph sprite is X-expanded
        sta VIC_SPR_XEXP
        lda scr_yexp
        ldx zp_ntsc
        beq +
        ora #$30                ; NTSC: sprites 4/5 (shins) may still run — keep
+       sta VIC_SPR_YEXP        ; their expansion; irq.asm clears it after line 228
        lda #$ff
        sta VIC_SPR_ENABLE
        rts
.hide:  lda #<350               ; park 4/5 too, and the shared registers
        sta VIC_SPR0_X+8
        sta VIC_SPR0_X+10
        lda #SCR_PARK_Y
        sta VIC_SPR0_X+9
        sta VIC_SPR0_X+11
        lda #$ff
        sta VIC_SPR_MSB
        lda #0
        sta VIC_SPR_XEXP
        rts

; ---------------------------------------------------------------
; logo: 7 glyphs of title_jp[A] converted into slots 24-30
; ---------------------------------------------------------------
; title screen: just ラジオ体操 (5 glyphs, centred) — 第一/第二 is the
; routine's name, which the menu shows next to each choice
logo_show_plain:
        lda #0
        jsr logo_show           ; ラジオ体操第一 into slots 24-30 ...
        ldx #0
        txa
-       sta DYN_SLOTS+$340,x    ; ... then blank slots 29,30 (第一)
        inx
        cpx #128
        bne -
        lda #44                 ; and shift the five glyphs to the centre
        sta logo_xoff
        lda #%11110000          ; MSB: sprites 4 (X 256), 5, 6 (blank), 7
        sta logo_msb
        rts

logo_show:                      ; A = routine (7 glyphs, used during play)
        pha
        lda #0
        sta logo_xoff
        lda #%11100000          ; MSB: sprites 5, 6 (X >= 256) and 7
        sta logo_msb
        pla
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
        clc
        adc logo_xoff
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
        lda logo_msb            ; MSB bits for this logo layout
        sta VIC_SPR_MSB
        lda #$ff
        sta VIC_SPR_XEXP
        sta VIC_SPR_YEXP
        sta VIC_SPR_ENABLE
.out:   rts
logo_x_lo: !for i, 0, 6 { !byte <(LOGO_X0 + 44*i) }
logo_xoff: !byte 0
logo_msb:  !byte %11100000
logo_sine: !for i, 0, 63 { !byte int(4.5 + 4.0 * sin(float(i) * 6.2831853 / 64.0)) }

; --- state ---
scr_hidden:   !byte 1
scr_unhide:   !byte 0           ; scroller_show request, applied by scroller_move
scr_x_lo:     !fill 8, 0        ; logical X, signed 16 bit
scr_x_hi:     !fill 8, 0
scr_load_flag: !fill 8, 0       ; 0 idle, 1 cell requested (IRQ), 2 loaded (main loop)
scr_vx:       !fill 8, 0        ; VIC X low bytes
scr_ptr:      !fill 8, 0        ; sprite pointers (slot 16+i or 24+i; the other is spare)
scr_msb:      !byte 0
scr_yexp:     !byte 0
scr_wrap_add: !byte 0
scr_cur:      !byte 0
scr_next:     !byte 0           ; the sprite that wraps (and loads) next
scr_cut:      !byte 0           ; 0 none, 1 cut being loaded, 2 cut ready for the IRQ
scr_pos:      !byte 0           ; next cell of the queue (cue cells, then gap cells)
scr_n:        !byte 0           ; cells in the cue
scr_idx:      !byte 0           ; movement table index of the queue
logo_on:      !byte 0
logo_phase:   !byte 0
logo_ybase:   !byte 0
logo_y:       !fill 7, 0        ; sprite Y per logo glyph
