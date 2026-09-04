!zone digi
; ---------------------------------------------------------------
; digi.asm — digitised voice: 4-bit samples through the SID master
; volume register, one sample per CIA2 timer A NMI.
;
; Data: tools/digi.py packs two 4-bit samples per byte (low nibble
; first) into src/gen_digi.asm (staged, lives at $e000+ at runtime)
; and src/gen_digi2.asm (data segment, which also holds the tables:
;   digi_word_lo/hi   start address of sample slot X
;   digi_len_lo/hi    byte count (0 = word dropped for lack of room)
;   digi_chain        slot to continue with when X ends, $ff = none
;                     (the titles share "rajio taiso" + "dai-ichi/ni")
;   digi_period_lo/hi CIA timer latch for PAL / NTSC (index zp_ntsc)
;
; Player: two NMI handlers alternate through the vector at $fffa —
; nmi_lo fetches a byte and outputs its low nibble, nmi_hi outputs
; the high nibble and counts down. Each is ~50 cycles including the
; RESTORE-key check, so the raster IRQ chain is delayed by at most
; one handler. While a word plays $d418 = sample | (mus_d418 & $f0);
; at the end mus_d418 is written back. The machine is all-RAM, so
; the $e000+ samples are read directly ($01 never changes).
;
; API (see HANDOFF.md):
;   digi_play    A = word 0..12 (constants below); preempts a word
;   digi_stop    silence now, restore $d418
;   digi_frame   main-loop housekeeping (RESTORE-stall kick, tests)
;   digi_toggle  F5: flip digi_enabled (stops if disabling)
;   digi_enabled 1 = speak, 0 = mute        digi_playing 1 while busy
; Zero page: $40-$47.
; Build with -DTEST_DIGI=1 to play every word once in sequence, one
; per 64 frames, while ignoring the play state's own requests (used
; by the WAV-capture test).
; ---------------------------------------------------------------

; word indices — play.asm uses these
DIGI_ICHI     = 0               ; 0..7 = ichi..hachi
DIGI_TITLE1   = 8               ; "rajio taiso dai-ichi"
DIGI_TITLE2   = 9               ; "rajio taiso dai-ni"
DIGI_SUTTE    = 10              ; breathe in
DIGI_HAITE    = 11              ; breathe out
DIGI_OTSUKARE = 12              ; "otsukaresama deshita"
DIGI_PUBLIC   = 13              ; number of public words

; zero page ($40-$47)
zp_digi_byte  = zp_digi         ; $40 current sample byte (both nibbles)
zp_digi_hi    = zp_digi+1       ; $41 mus_d418 & $f0, captured at start
zp_digi_cnt   = zp_digi+2       ; $42/$43 bytes left: lo, hi(+1 if lo)
zp_digi_last  = zp_digi+4       ; $44 count low byte seen last frame

; ---------------------------------------------------------------
; digi_play: A = public word 0..12
; ---------------------------------------------------------------
!ifdef TEST_DIGI {
digi_play:
        rts                     ; the test sequencer owns the player
} else {
digi_play:
        ldx digi_enabled
        beq .no
        cmp #DIGI_PUBLIC
        bcs .no
        tax
        jmp digi_start
.no:    rts
}

; X = sample slot (0..DIGI_SLOTS-1). Stops whatever plays, then
; starts slot X from its first byte.
digi_start:
        lda digi_len_lo,x
        ora digi_len_hi,x
        beq .empty              ; word dropped by the generator: silent
        jsr digi_quiesce        ; no NMI can interfere from here on
        lda digi_word_lo,x
        sta digi_fetch+1
        lda digi_word_hi,x
        sta digi_fetch+2
        lda digi_len_hi,x
        sta zp_digi_cnt+1
        lda digi_len_lo,x
        sta zp_digi_cnt
        beq +
        inc zp_digi_cnt+1       ; dec-lo/dec-hi countdown form
+       lda digi_chain,x
        sta digi_next
        lda mus_d418
        and #$f0                ; keep the music's filter mode bits
        sta zp_digi_hi
        ; duck the music under the voice: all three voices through the
        ; low-pass filter with the cutoff at zero (the sample stream goes
        ; straight to the output stage, so only the music gets quieter)
        lda #(FILT_RES | $07)
        sta SID_FILT_RES
        lda #0
        sta SID_FILT_LO
        sta SID_FILT_HI
        lda #1
        sta digi_ducked
        lda #<nmi_lo
        sta VEC_NMI             ; first sample = low nibble
        lda #1
        sta digi_playing
        ldx zp_ntsc
        lda digi_period_lo,x
        sta CIA2_TA_LO
        lda digi_period_hi,x
        sta CIA2_TA_HI
        lda #$81
        sta CIA2_ICR            ; timer A -> NMI
        lda #$11                ; force load + start, continuous, phi2
        sta CIA2_CRA
.empty: rts

; stop the timer and let a possibly latched NMI run (it then finds
; the interrupt flag already cleared and ignores itself)
digi_quiesce:
        lda #$00
        sta CIA2_CRA            ; timer A off: no further NMIs
        lda CIA2_ICR            ; drop a pending flag
        nop                     ; a latched NMI is serviced here...
        nop                     ; ...at the latest
        rts

; ---------------------------------------------------------------
digi_stop:
        jsr digi_quiesce
        lda #$7f
        sta CIA2_ICR            ; mask everything on CIA2
        lda #<nmi_lo
        sta VEC_NMI
        lda #0
        sta digi_playing
        lda #$ff
        sta digi_next
        lda mus_d418
        sta SID_VOL             ; give $d418 back to the music
        ; fall through: restore the music's filter
digi_unduck:
        lda digi_ducked
        beq +
        lda #FILT_RES
        sta SID_FILT_RES        ; the music's routing (voice 3 only)
        lda flt_cut
        sta SID_FILT_HI         ; and its current cutoff
        lda #0
        sta SID_FILT_LO
        sta digi_ducked
+       rts

digi_toggle:                    ; F5
        lda digi_enabled
        eor #1
        sta digi_enabled
        bne +
        jmp digi_stop
+       rts

; ---------------------------------------------------------------
; digi_frame: once per frame from the main loop.
; RESTORE holds the NMI line low, so a timer underflow during that
; time produces no edge and the player would stall with its flag
; set forever. If the sample counter has not moved for a whole frame
; while playing, read $dd0d to release the line: the next underflow
; is a fresh edge again.
; ---------------------------------------------------------------
digi_frame:
        lda digi_playing
        bne +
        jsr digi_unduck         ; word over (NMI end path): music back up
        jmp .idle
+
        lda zp_digi_cnt
        cmp zp_digi_last
        sta zp_digi_last
        bne .idle
        lda CIA2_ICR            ; stalled: release the interrupt line
.idle:
!ifdef TEST_DIGI {
        ; test sequencer: one word per 64 frames, slots 0..12 once
        lda digi_test_cnt
        and #63
        bne +
        ldx digi_test_word
        cpx #DIGI_PUBLIC
        bcs +
        inc digi_test_word
        jsr digi_start
+       inc digi_test_cnt
}
        rts

digi_enabled:   !byte 1
digi_ducked:    !byte 0         ; music filter-ducked under a word
digi_playing:   !byte 0
digi_next:      !byte $ff       ; slot to chain at the end, $ff = none
!ifdef TEST_DIGI {
digi_test_cnt:  !byte 0
digi_test_word: !byte 0
}

; ---------------------------------------------------------------
; NMI handlers. nmi_lo / nmi_hi must share a page: the handlers swap
; only the low byte of the vector ($fffa is RAM in the $35 config).
; Cycle counts exclude the 7-cycle NMI entry.
; ---------------------------------------------------------------
!if (* & $ff) > ($100 - 64) { !align 255, 0 }
nmi_handler:                    ; label used by init.asm for $fffa
nmi_lo:
        pha                     ; 3
        lda CIA2_ICR            ; 4  ack; bit 7 clear = RESTORE key
        bpl .out_lo             ; 2      (or a stray edge): ignore
digi_fetch:
        lda $ffff               ; 4  self-modified sample address
        sta zp_digi_byte        ; 3  the high nibble is served next
        and #$0f                ; 2
        ora zp_digi_hi          ; 3
        sta SID_VOL             ; 4
        lda #<nmi_hi            ; 2
        sta VEC_NMI             ; 4  next NMI: high nibble
        inc digi_fetch+1        ; 6
        bne .out_lo             ; 3
        inc digi_fetch+2        ; 6  (once per page)
.out_lo:
        pla                     ; 4
        rti                     ; 6  = 50 cycles (55 on a page cross)

nmi_hi:
        pha                     ; 3
        lda CIA2_ICR            ; 4
        bpl .out_hi             ; 2
        lda zp_digi_byte        ; 3
        lsr                     ; 2
        lsr                     ; 2
        lsr                     ; 2
        lsr                     ; 2
        ora zp_digi_hi          ; 3
        sta SID_VOL             ; 4
        lda #<nmi_lo            ; 2
        sta VEC_NMI             ; 4  next NMI: fetch a new byte
        dec zp_digi_cnt         ; 5
        bne .out_hi             ; 3
        dec zp_digi_cnt+1       ; 5  (once per page)
        bne .out_hi             ; 3
        jmp digi_end            ; word finished (rare, longer path)
.out_hi:
        pla                     ; 4
        rti                     ; 6  = 51 cycles (59 on a page cross)
!if >nmi_lo != >nmi_hi { !error "digi: nmi_lo and nmi_hi must share a page" }

; end of a word inside the NMI (A pushed): chain the next slot without
; a gap, or stop the timer and hand $d418 back to the music
digi_end:
        txa
        pha
        ldx digi_next
        bmi .stop
        lda digi_len_lo,x
        ora digi_len_hi,x
        beq .stop               ; chained word missing: just stop
        lda digi_word_lo,x
        sta digi_fetch+1
        lda digi_word_hi,x
        sta digi_fetch+2
        lda digi_len_hi,x
        sta zp_digi_cnt+1
        lda digi_len_lo,x
        sta zp_digi_cnt
        beq +
        inc zp_digi_cnt+1
+       lda #$ff
        sta digi_next
        pla
        tax
        pla
        rti
.stop:  lda #$00
        sta CIA2_CRA            ; timer A off
        lda #$7f
        sta CIA2_ICR
        lda mus_d418
        sta SID_VOL
        lda #0
        sta digi_playing
        pla
        tax
        pla
        rti
