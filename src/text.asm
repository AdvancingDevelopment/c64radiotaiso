!zone text
; text.asm — English names, cues, key help + play-screen UI hooks
; (stub until phase 3; the UI module replaces these)
ui_play_init:     rts           ; static layout + backdrop
ui_movement:      rts           ; slot changed: names, cue, stations, ray
ui_beat:          rts           ; digit, words, pips, sun pulse
ui_frame:         rts           ; per frame: prefetch, pulses, clock
ui_tempo:         rts           ; redraw "tempo nnn%"
ui_toggle_lang:   rts           ; F3
ui_pause_show:    rts
ui_pause_hide:    rts
