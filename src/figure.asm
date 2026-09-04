!zone figure
; ---------------------------------------------------------------
; figure.asm — pose record -> sprite shadow block -> VIC.
;
; The puppet is 10 body parts on 8 hardware sprites:
;   0/1 forearms+hands  2/3 upper arms  4 head  5 torso  6/7 thighs
;   4/5 again = shins+feet after the mid-frame split IRQ (multiplex)
; All parts are shared single-colour frames (gen_sprites.asm) with
; per-frame metadata (gen_poses.asm, signed big pixels, 1 bp = 2 px
; at 2x): frm_ox/oy = box top-left from the part's pivot joint,
; frm_ex/ey = distal joint, torso_sx/sy = shoulder from the waist.
;
; figure_render (main loop, per tick) builds a shadow block in one
; of three buffers and publishes it with a single store (buf_sel);
; figure_commit (IRQ line 50) latches buf_sel and writes every
; sprite register the figure relies on; figure_split (IRQ at the
; per-tick split line) retargets sprites 4/5 to the shins. Three
; buffers: the one being displayed (commit_sel), the one just
; published (buf_sel) and a free one for the next render — so the
; main loop never writes what an IRQ is reading (no sei needed).
;
; Waist anchor: sprite X FIG_WAIST_X (184, screen centre); waist Y =
; FIG_WAIST_Y2/1 + fig_y so the feet stand on text row 20.
; ---------------------------------------------------------------

zp_jx       = zp_fig+7          ; joint x (bp, relative to the waist)
zp_jy       = zp_fig+8          ; joint y
zp_sx       = zp_fig+9          ; shoulder x (saved for both arms)
zp_sy       = zp_fig+10         ; shoulder y
zp_wy       = zp_fig+11         ; waist sprite Y this tick

; shadow block layout (BUF_STRIDE bytes per buffer)
;  +0..15  sprite 0-7 X lo / Y (same order as $d000-$d00f)
;  +16     $d010 MSB bits (main set)
;  +17..24 sprite pointers 0-7
;  +25..28 shin set: X4, Y4, X5, Y5
;  +29     $d010 for the shin set (bits 4/5 replaced)
;  +30,31  shin pointers (sprites 4, 5)
;  +32     split raster line, +33 scroller raster line
;  +34     $d017/$d01d expansion byte ($ff at 2x, 0 at 1x)
BUF_STRIDE  = 40
B_MSB       = 16
B_PTR       = 17
B_SHIN      = 25
B_SMSB      = 29
B_SPTR      = 30
B_SPLIT     = 32
B_SCROLL    = 33
B_EXP       = 34

SCROLL_ADD2 = 33                ; shin box: Y + 32 lines at 2x — the scroller glyph rows
                                ; that replace the shin's blank tail (rows 16-20) are blank too
SCROLL_ADD1 = 17

; ---------------------------------------------------------------
; place one part: Y = frame pointer byte, X = buffer base,
; zp_jx/zp_jy = its pivot joint (bp relative to the waist).
;   .xo = X-lo offset in the block (Y follows), .po = pointer offset,
;   .mo = MSB byte offset, .mb = MSB bit
; sprite X = FIG_WAIST_X + s*(jx + ox), Y = wy + s*(jy + oy), s = 2|1
; ---------------------------------------------------------------
!macro place .xo, .po, .mo, .mb {
        tya
        sta buf+.po,x           ; sprite pointer
        lda frm_ox-FRM_FIRST,y
        clc
        adc zp_jx               ; box left, bp (|value| <= 63)
        bit fig_1x
        bmi +
        asl                     ; 2x: big pixels -> screen pixels
+       cmp #$80
        bcs ++                  ; negative: no carry possible
        clc
        adc #FIG_WAIST_X
        bcc +++
        pha                     ; X >= 256: set the MSB bit
        lda buf+.mo,x
        ora #.mb
        sta buf+.mo,x
        pla
        jmp +++
++      clc
        adc #FIG_WAIST_X        ; wraps, true result is 58..183
+++     sta buf+.xo,x
        lda frm_oy-FRM_FIRST,y
        clc
        adc zp_jy
        bit fig_1x
        bmi +
        asl
+       clc
        adc zp_wy
        sta buf+.xo+1,x
}

; joint = joint + distal vector of frame Y
!macro add_distal {
        lda zp_jx
        clc
        adc frm_ex-FRM_FIRST,y
        sta zp_jx
        lda zp_jy
        clc
        adc frm_ey-FRM_FIRST,y
        sta zp_jy
}

!macro joint_waist {
        lda #0
        sta zp_jx
        sta zp_jy
}

!macro joint_shoulder {
        lda zp_sx
        sta zp_jx
        lda zp_sy
        sta zp_jy
}

; ---------------------------------------------------------------
; figure_init — PLAY start: static sprite setup, idle pose visible
; ---------------------------------------------------------------
figure_init:
        lda #0
        sta fig_on
        sta buf_sel
        sta commit_sel
        sta VIC_SPR_PRIO        ; sprites in front of the characters
        sta VIC_SPR_MC
!ifdef TEST_SCALE1 {
        lda #0                  ; test builds: start at 1x
} else {
        lda fig_scale           ; play.asm: 1 = 2x
}
        jsr .set_scale_byte
        lda #ANIM_IDLE
        jsr choreo_set_anim     ; pose_cur valid before the first tick
        jmp figure_render       ; -> fig_on = 1

; A = 0 (1x) / 1 (2x): re-render the current pose at the new size
figure_set_scale:
        jsr .set_scale_byte
        jmp figure_render
.set_scale_byte:
        and #1
        tax
        lda scale_flag,x
        sta fig_1x
        rts
scale_flag: !byte $80, 0        ; bit 7 set = 1x

; sprites off; the IRQ entries stop touching the VIC
figure_hide:
        lda #0
        sta fig_on
        sta VIC_SPR_ENABLE
        lda #LINE_SPLIT_DEF
        sta irq_lines+2
        lda scroll_min_line
        sta irq_lines+3
        rts

; ---------------------------------------------------------------
; figure_render — main loop, once per tick (and on a size change):
; pose_cur -> a free shadow buffer, then publish it. ~1000 cycles.
; ---------------------------------------------------------------
figure_render:
        ; pick the buffer that is neither published nor displayed
        ldx #0
-       cpx buf_sel
        beq +
        cpx commit_sel
        bne ++
+       txa
        clc
        adc #BUF_STRIDE
        tax
        jmp -
++
        ; waist Y = FIG_WAIST_Y + fig_y (fig_y is in 2x pixels)
        lda pose_cur+0
        bit fig_1x
        bpl +
        cmp #$80                ; 1x: halve, keeping the sign
        ror
        clc
        adc fig_waist_y1        ; PAL/NTSC values chosen at boot (init.asm)
        jmp ++
+       clc
        adc fig_waist_y2
++      sta zp_wy
        lda #0
        sta buf+B_MSB,x
        sta buf+B_SMSB,x
        lda #$ff
        bit fig_1x
        bpl +
        lda #0
+       sta buf+B_EXP,x

        ; torso (sprite 5) pivots at the waist
        +joint_waist
        ldy pose_cur+1
        +place 10, B_PTR+5, B_MSB, $20
        ; neck and shoulder from the torso tables
        lda frm_ex-FRM_FIRST,y
        sta zp_jx
        lda frm_ey-FRM_FIRST,y
        sta zp_jy
        lda torso_sx-TORSO_BASE,y
        sta zp_sx
        lda torso_sy-TORSO_BASE,y
        sta zp_sy
        ; head (sprite 4) at the neck
        ldy pose_cur+2
        +place 8, B_PTR+4, B_MSB, $10
        ; upper arm L (sprite 2) at the shoulder, forearm L (sprite 0) at the elbow
        +joint_shoulder
        ldy pose_cur+3
        +place 4, B_PTR+2, B_MSB, $04
        +add_distal
        ldy pose_cur+5
        +place 0, B_PTR+0, B_MSB, $01
        ; upper arm R (sprite 3), forearm R (sprite 1)
        +joint_shoulder
        ldy pose_cur+4
        +place 6, B_PTR+3, B_MSB, $08
        +add_distal
        ldy pose_cur+6
        +place 2, B_PTR+1, B_MSB, $02
        ; thigh L (sprite 6) at the waist, shin L (sprite 4 after the split) at the knee
        +joint_waist
        ldy pose_cur+7
        +place 12, B_PTR+6, B_MSB, $40
        +add_distal
        ldy pose_cur+9
        +place B_SHIN+0, B_SPTR+0, B_SMSB, $10
        ; thigh R (sprite 7), shin R (sprite 5 after the split)
        +joint_waist
        ldy pose_cur+8
        +place 14, B_PTR+7, B_MSB, $80
        +add_distal
        ldy pose_cur+10
        +place B_SHIN+2, B_SPTR+1, B_SMSB, $20

        ; $d010 for the shin set = main bits with 4/5 replaced
        lda buf+B_MSB,x
        and #$cf
        ora buf+B_SMSB,x
        sta buf+B_SMSB,x
        ; split raster line = waist line + record offset (2x lines; halve at 1x)
        lda pose_cur+11
        bit fig_1x
        bpl +
        lsr
+       clc
        adc zp_wy
        sta buf+B_SPLIT,x
        ; scroller line = max(shin box top + 33, scroll_min_line), <= 246
        lda buf+B_SHIN+1,x
        cmp buf+B_SHIN+3,x
        bcs +
        lda buf+B_SHIN+3,x
+       bit fig_1x
        bmi +
        clc
        adc #SCROLL_ADD2
        jmp ++
+       clc
        adc #SCROLL_ADD1
++      cmp scroll_min_line
        bcs +
        lda scroll_min_line
+       cmp #247
        bcc +
        lda #246
+       sta buf+B_SCROLL,x
        ; publish
        stx buf_sel
        lda #1
        sta fig_on
        rts

; ---------------------------------------------------------------
; figure_commit — IRQ at line 50: the whole sprite 0-7 state the
; figure needs (the scroller and logo reuse the sprites later in
; the frame). ~300 cycles.
; ---------------------------------------------------------------
figure_commit:
        lda fig_on
        bne +
        rts
+        ldx buf_sel
        stx commit_sel
        lda buf+0,x
        sta VIC_SPR0_X+0
        lda buf+1,x
        sta VIC_SPR0_X+1
        lda buf+2,x
        sta VIC_SPR0_X+2
        lda buf+3,x
        sta VIC_SPR0_X+3
        lda buf+4,x
        sta VIC_SPR0_X+4
        lda buf+5,x
        sta VIC_SPR0_X+5
        lda buf+6,x
        sta VIC_SPR0_X+6
        lda buf+7,x
        sta VIC_SPR0_X+7
        lda buf+8,x
        sta VIC_SPR0_X+8
        lda buf+9,x
        sta VIC_SPR0_X+9
        lda buf+10,x
        sta VIC_SPR0_X+10
        lda buf+11,x
        sta VIC_SPR0_X+11
        lda buf+12,x
        sta VIC_SPR0_X+12
        lda buf+13,x
        sta VIC_SPR0_X+13
        lda buf+14,x
        sta VIC_SPR0_X+14
        lda buf+15,x
        sta VIC_SPR0_X+15
        lda buf+B_MSB,x
        sta VIC_SPR_MSB
        lda buf+B_PTR+0,x
        sta SPR_PTRS+0
        lda buf+B_PTR+1,x
        sta SPR_PTRS+1
        lda buf+B_PTR+2,x
        sta SPR_PTRS+2
        lda buf+B_PTR+3,x
        sta SPR_PTRS+3
        lda buf+B_PTR+4,x
        sta SPR_PTRS+4
        lda buf+B_PTR+5,x
        sta SPR_PTRS+5
        lda buf+B_PTR+6,x
        sta SPR_PTRS+6
        lda buf+B_PTR+7,x
        sta SPR_PTRS+7
        lda buf+B_EXP,x
        sta VIC_SPR_YEXP
        sta VIC_SPR_XEXP
        lda #COL_INK
        sta VIC_SPR0_COL+0
        sta VIC_SPR0_COL+1
        sta VIC_SPR0_COL+2
        sta VIC_SPR0_COL+3
        sta VIC_SPR0_COL+4
        sta VIC_SPR0_COL+5
        sta VIC_SPR0_COL+6
        sta VIC_SPR0_COL+7
        lda #0
        sta VIC_SPR_PRIO
        sta VIC_SPR_MC
        lda #$ff
        sta VIC_SPR_ENABLE
        ; this frame's split and scroller lines (ascending: 50 < split < scroller)
        lda buf+B_SPLIT,x
        sta irq_lines+2
        lda buf+B_SCROLL,x
        sta irq_lines+3
        rts

; ---------------------------------------------------------------
; figure_split — IRQ at the split line: sprites 4/5 -> shins. ~75 cycles.
; ---------------------------------------------------------------
figure_split:
        lda fig_on
        beq .soff
        ldx commit_sel
        lda buf+B_SHIN+0,x
        sta VIC_SPR0_X+8
        lda buf+B_SHIN+1,x
        sta VIC_SPR0_X+9
        lda buf+B_SHIN+2,x
        sta VIC_SPR0_X+10
        lda buf+B_SHIN+3,x
        sta VIC_SPR0_X+11
        lda buf+B_SMSB,x
        sta VIC_SPR_MSB
        lda buf+B_SPTR+0,x
        sta SPR_PTRS+4
        lda buf+B_SPTR+1,x
        sta SPR_PTRS+5
.soff:   rts

fig_on:     !byte 0             ; 1 = the IRQ entries drive sprites 0-7
fig_1x:     !byte 0             ; $80 = 1x (no expansion), 0 = 2x
buf_sel:    !byte 0             ; published buffer (base offset)
commit_sel: !byte 0             ; buffer latched at line 50

buf:        !fill 3*BUF_STRIDE, 0
