!zone input
; ---------------------------------------------------------------
; input.asm — joystick port 2 + the few keys we need, scanned from
; the bottom IRQ. Produces 16-bit key masks (see constants.asm):
;   keys_now     raw state this frame
;   keys_stable  debounced (held two consecutive frames)
;   keys_new     press edges of the debounced state (main clears)
; Joystick ghosting rule (from c64snake): joy2 shares CIA1 port A
; with the keyboard column drivers, so while any stick line is low
; the matrix is not scanned at all.
; ---------------------------------------------------------------

input_scan:
        lda #0
        sta keys_now
        sta keys_now+1
        lda #$ff
        sta CIA1_PRA        ; deselect all columns
        lda CIA1_PRA        ; joystick 2 (active low)
        and #$1f
        cmp #$1f
        beq .keyboard
        tax
        and #$10
        bne +
        lda keys_now+1
        ora #JOY_FIRE
        sta keys_now+1
+       txa
        and #$01
        bne +
        lda keys_now+1
        ora #JOY_UP
        sta keys_now+1
+       txa
        and #$02
        bne +
        lda keys_now+1
        ora #JOY_DOWN
        sta keys_now+1
+       jmp .debounce

.keyboard:
        lda #%01111111      ; PA7: 1(r0) 2(r3) SPACE(r4) Q(r6) STOP(r7)
        sta CIA1_PRA
        lda CIA1_PRB
        eor #$ff
        tax                 ; 1 = pressed
        and #$01
        beq +
        lda #KEY_1
        ora keys_now
        sta keys_now
+       txa
        and #$08
        beq +
        lda #KEY_2
        ora keys_now
        sta keys_now
+       txa
        and #$10
        beq +
        lda #KEY_SPACE
        ora keys_now
        sta keys_now
+       txa
        and #$40
        beq +
        lda #KEY_Q
        ora keys_now
        sta keys_now
+       txa
        and #$80
        beq +
        lda #KEY_STOP
        ora keys_now
        sta keys_now
+       lda #%11111110      ; PA0: RETURN(r1) F7(r3) F1(r4) F3(r5) F5(r6)
        sta CIA1_PRA
        lda CIA1_PRB
        eor #$ff
        tax
        and #$02
        beq +
        lda #KEY_RETURN
        ora keys_now
        sta keys_now
+       txa
        and #$08
        beq +
        lda #KEY_F7
        ora keys_now
        sta keys_now
+       txa
        and #$10
        beq +
        lda #KEY_F1
        ora keys_now
        sta keys_now
+       txa
        and #$20
        beq +
        lda #KEY_F3
        ora keys_now+1
        sta keys_now+1
+       txa
        and #$40
        beq +
        lda #KEY_F5
        ora keys_now+1
        sta keys_now+1
+       lda #%11011111      ; PA5: +(r0) -(r3)
        sta CIA1_PRA
        lda CIA1_PRB
        eor #$ff
        tax
        and #$01
        beq +
        lda #KEY_PLUS
        ora keys_now+1
        sta keys_now+1
+       txa
        and #$08
        beq +
        lda #KEY_MINUS
        ora keys_now+1
        sta keys_now+1
+       lda #$ff
        sta CIA1_PRA

.debounce:
        ldx #1
-       lda keys_now,x
        and keys_prev,x     ; stable = now & previous raw
        sta zp_irq_tmp
        lda keys_stable,x
        eor #$ff
        and zp_irq_tmp      ; newly stable
        ora keys_new,x      ; accumulate until main consumes
        sta keys_new,x
        lda zp_irq_tmp
        sta keys_stable,x
        lda keys_now,x
        sta keys_prev,x
        dex
        bpl -
        rts

keys_now:    !byte 0, 0
keys_prev:   !byte 0, 0
keys_stable: !byte 0, 0
keys_new:    !byte 0, 0
