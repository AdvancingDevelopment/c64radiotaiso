!zone instruments
; ---------------------------------------------------------------
; instruments.asm — SID instrument descriptors for music.asm.
; 8 bytes per instrument, indexed by the INSTRUMENT byte of the
; song data (tools/songconv.py numbers them the same way):
;   +0 control   waveform | gate (bit 0 is cleared for gate off /
;                hard restart, the rest is written as is)
;   +1 AD        attack / decay
;   +2 SR        sustain / release
;   +3 PW lo     pulse width (voice 1 restarts its sweep here)
;   +4 PW hi
;   +5 flags     see FLAG_* below
;   +6 cutoff    $d416 written at note-on (only voice 3 is routed
;                through the filter, $d417 = FILT_RES)
;   +7 arpeggio  frames per chord tone (0 = no arpeggio)
; Tune by ear: the numbers below are the plan's starting values.
; ---------------------------------------------------------------
FLAG_MELODY = 1                 ; voice 1: pulse-width sweep + delayed vibrato
FLAG_HAMMER = 2                 ; voice 2: saw attack, triangle body after 2 frames
FLAG_SWEEP  = 4                 ; voice 3: cutoff sweeps +1/frame up to FLT_MAX

I_MELODY    = 0
I_BASS      = 1
I_STAB      = 2
I_CALM_BASS = 3
I_CALM_ARP  = 4

inst_tab:
;             ctrl  AD   SR   PWlo PWhi flags        cut  arp
        !byte $41, $09, $48, $00, $03, FLAG_MELODY, $00, 0   ; 0 MELODY    pulse lead
        !byte $21, $08, $67, $00, $08, FLAG_HAMMER, $00, 0   ; 1 BASS      saw hammer -> triangle
        !byte $41, $08, $26, $00, $06, 0,           $70, 1   ; 2 STAB      filtered pulse chord, 16.7 Hz arp
        !byte $11, $2a, $8a, $00, $08, 0,           $00, 0   ; 3 CALM_BASS triangle, slow attack
        !byte $11, $8a, $8a, $00, $08, FLAG_SWEEP,  $50, 4   ; 4 CALM_ARP  triangle harp, filter sweep
