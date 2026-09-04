!zone figure
; figure.asm — pose record -> sprite shadow block (stub until phase 2)
figure_init:      rts           ; sprite static setup for PLAY
figure_render:    rts           ; main loop, once per tick: build the shadow block
figure_commit:    rts           ; IRQ line 50: shadow -> VIC
figure_split:     rts           ; IRQ split line: sprites 4/5 -> shins
figure_set_scale: rts           ; A = 0 (1x) / 1 (2x)
figure_hide:      rts           ; sprites off (title/finish transitions)
