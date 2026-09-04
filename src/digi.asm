!zone digi
; digi.asm — NMI 4-bit sample player (stub until phase 4)
; word indices (gen_digi.asm defines the real table in the same order)
DIGI_ICHI   = 0                 ; 0..7 = ichi..hachi
DIGI_TITLE1 = 8                 ; "radio taiso dai-ichi"
DIGI_TITLE2 = 9
DIGI_SUTTE  = 10
DIGI_HAITE  = 11
DIGI_OTSUKARE = 12
digi_play:        rts           ; A = word index
digi_stop:        rts
digi_frame:       rts           ; main loop housekeeping
digi_toggle:                    ; F5
        lda digi_enabled
        eor #1
        sta digi_enabled
        rts
digi_enabled:     !byte 1
nmi_handler:
        pha
        lda CIA2_ICR        ; ack CIA2 timer; RESTORE is ignored
        pla
        rti
