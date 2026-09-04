!zone movements
; ---------------------------------------------------------------
; movements.asm — the shared timing grid (identical for both
; routines): slot 0 = warm-up (intro), 1..13 = movements, 14 = end.
; Timeline ids (tools/puppet.py must use the same numbering):
;   0 stretch-up            1 arm-swings-leg-bends   2 arm-circles
;   3 chest-stretch         4 side-bends             5 forward-back-bends
;   6 body-twists           7 up-down-stretch        8 diagonal-bend-chest
;   9 body-rotation        10 jumping               11 cool-down-swings
;  12 deep-breathing       13 whole-body-shake      14 hop-steps
;  15 curl-squats          16 deep-folds            17 warmup
;  18 idle                 19 bow
; ---------------------------------------------------------------
ANIM_WARMUP = 17
ANIM_IDLE   = 18
ANIM_BOW    = 19

mv_start_lo: !byte <0,<128,<384,<640,<896,<1152,<1408,<1664,<1920,<2048,<2304,<2432,<2688,<2816,<3072
mv_start_hi: !byte >0,>128,>384,>640,>896,>1152,>1408,>1664,>1920,>2048,>2304,>2432,>2688,>2816,>3072
mv_anim_r1:  !byte 17,0,1,2,3,4,5,6,7,8,9,10,11,12,19
mv_anim_r2:  !byte 17,13,15,2,3,4,5,6,14,8,16,10,11,12,19
; ticks per slot (128 = 4 bars, 256 = 8 bars)
mv_len_lo:   !byte <128,<256,<256,<256,<256,<256,<256,<256,<128,<256,<128,<256,<128,<256,<0
mv_len_hi:   !byte >128,>256,>256,>256,>256,>256,>256,>256,>128,>256,>128,>256,>128,>256,>0
