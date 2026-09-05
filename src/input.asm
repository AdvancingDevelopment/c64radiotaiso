!zone input
; ---------------------------------------------------------------
; input.asm — joystick port 2 + the plain keys we need (1-5, S, L, V,
; SPACE, Q, RUN/STOP, RETURN), scanned from the bottom IRQ. Produces 16-bit key masks (see constants.asm):
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
!macro key_col .mask {          ; select column .mask, A = pressed rows (1 = down)
        lda #.mask
        sta CIA1_PRA
        lda CIA1_PRB
        eor #$ff
        tax
}
!macro key_lo .rowbit, .keybit { ; row bit -> key bit in keys_now (X = pressed rows)
        txa
        and #.rowbit
        beq +
        lda keys_now
        ora #.keybit
        sta keys_now
+
}
!macro key_hi .rowbit, .keybit {
        txa
        and #.rowbit
        beq +
        lda keys_now+1
        ora #.keybit
        sta keys_now+1
+
}
        +key_col %01111111      ; PA7: 1(r0) 2(r3) SPACE(r4) Q(r6) STOP(r7)
        +key_lo $01, KEY_1
        +key_lo $08, KEY_2
        +key_lo $10, KEY_SPACE
        +key_lo $40, KEY_Q
        +key_lo $80, KEY_STOP
        +key_col %11111110      ; PA0: RETURN(r1)
        +key_lo $02, KEY_RETURN
        +key_col %11111101      ; PA1: 3(r0) 4(r3) S(r5)
        +key_lo $01, KEY_3
        +key_lo $08, KEY_4
        +key_hi $20, KEY_S
        +key_col %11111011      ; PA2: 5(r0)
        +key_hi $01, KEY_5
        +key_col %11011111      ; PA5: L(r2)
        +key_hi $04, KEY_L
        lda #$ff
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
