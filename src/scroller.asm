!zone scroller
; scroller.asm — 8-sprite glyph scroller + border logo (stub until phase 5)
scroller_init:    rts
scroller_set_text: rts          ; A/X = glyph string ptr (queue switch)
scroller_frame:   rts           ; main loop, once per frame
scroller_commit:  rts           ; IRQ entry
scroller_hide:    rts
logo_commit:      rts           ; IRQ line 8 (PAL top border logo)
logo_show:        rts           ; A = routine
logo_hide:        rts
