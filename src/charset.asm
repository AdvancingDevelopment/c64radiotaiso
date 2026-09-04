!zone charset
; ---------------------------------------------------------------
; charset.asm — custom character set at $4800 (VIC bank 1 slot 1).
;   $00-$3f Latin font, screen-code layout so !scr strings map 1:1
;           (glyphs from ~/c64snake, 6-px chunky strokes)
;   $40-$4f UI tiles (block, station dots, beat pips, floor, arrow)
;   $50-$6f backdrop tiles (copied from gen_backdrop.asm at run time)
;   $70-$7f glyph area C (kana count word, 4 glyphs of 2x2 cells)
;   $80-$bf glyph area A, $c0-$ff area B (16 Japanese glyphs each,
;           streamed from gen_glyphs.asm by text.asm; a glyph = 4
;           consecutive codes TL,TR,BL,BR = one 32-byte copy)
; ---------------------------------------------------------------
* = CHARSET
charset_start:

; ---------------------------------------------------------------
; text font $01-$3a (hires, chunky 6px strokes), screen-code
; layout so ACME's !scr strings map straight onto it.
; ---------------------------------------------------------------

; $00 unused (@)
!fill 8, 0

; $01-$1a: A-Z
!byte $30,$78,$cc,$cc,$fc,$cc,$cc,$00  ; A
!byte $f8,$cc,$cc,$f8,$cc,$cc,$f8,$00  ; B
!byte $78,$cc,$c0,$c0,$c0,$cc,$78,$00  ; C
!byte $f0,$d8,$cc,$cc,$cc,$d8,$f0,$00  ; D
!byte $fc,$c0,$c0,$f8,$c0,$c0,$fc,$00  ; E
!byte $fc,$c0,$c0,$f8,$c0,$c0,$c0,$00  ; F
!byte $78,$cc,$c0,$dc,$cc,$cc,$7c,$00  ; G
!byte $cc,$cc,$cc,$fc,$cc,$cc,$cc,$00  ; H
!byte $78,$30,$30,$30,$30,$30,$78,$00  ; I
!byte $3c,$18,$18,$18,$18,$d8,$70,$00  ; J
!byte $cc,$d8,$f0,$e0,$f0,$d8,$cc,$00  ; K
!byte $c0,$c0,$c0,$c0,$c0,$c0,$fc,$00  ; L
!byte $c6,$ee,$fe,$d6,$c6,$c6,$c6,$00  ; M (7px)
!byte $c6,$e6,$f6,$de,$ce,$c6,$c6,$00  ; N (7px)
!byte $78,$cc,$cc,$cc,$cc,$cc,$78,$00  ; O
!byte $f8,$cc,$cc,$f8,$c0,$c0,$c0,$00  ; P
!byte $78,$cc,$cc,$cc,$cc,$d8,$6c,$00  ; Q
!byte $f8,$cc,$cc,$f8,$f0,$d8,$cc,$00  ; R
!byte $78,$cc,$c0,$78,$0c,$cc,$78,$00  ; S
!byte $fc,$30,$30,$30,$30,$30,$30,$00  ; T
!byte $cc,$cc,$cc,$cc,$cc,$cc,$78,$00  ; U
!byte $cc,$cc,$cc,$cc,$cc,$78,$30,$00  ; V
!byte $c6,$c6,$c6,$d6,$fe,$ee,$c6,$00  ; W (7px)
!byte $cc,$cc,$78,$30,$78,$cc,$cc,$00  ; X
!byte $cc,$cc,$cc,$78,$30,$30,$30,$00  ; Y
!byte $fc,$0c,$18,$30,$60,$c0,$fc,$00  ; Z

; $1b: (c) copyright sign;  $1c-$1f unused
!byte $3c,$42,$99,$a1,$a1,$99,$42,$3c
!fill 4 * 8, 0

; $20: blank (playfield empty cell)
!fill 8, 0

; $21: !
!byte $30,$30,$30,$30,$30,$00,$30,$00

; $22-$24 unused (" # $)
!fill 3 * 8, 0
; $25: %   $26: &   $27: '
!byte $c4,$cc,$18,$30,$60,$cc,$8c,$00
!byte $70,$d8,$d8,$70,$dc,$d8,$76,$00
!byte $30,$30,$60,$00,$00,$00,$00,$00

; $28: (   $29: )
!byte $18,$30,$60,$60,$60,$30,$18,$00
!byte $60,$30,$18,$18,$18,$30,$60,$00

; $2a: *   $2b: +
!byte $00,$6c,$38,$fe,$38,$6c,$00,$00
!byte $00,$30,$30,$fc,$fc,$30,$30,$00

; $2c: ,   $2d: -   $2e: .   $2f: /
!byte $00,$00,$00,$00,$00,$60,$60,$c0
!byte $00,$00,$00,$78,$00,$00,$00,$00
!byte $00,$00,$00,$00,$00,$60,$60,$00
!byte $0c,$0c,$18,$30,$60,$c0,$c0,$00

; $30-$39: digits
!byte $78,$cc,$cc,$cc,$cc,$cc,$78,$00  ; 0
!byte $30,$70,$30,$30,$30,$30,$78,$00  ; 1
!byte $78,$cc,$0c,$18,$30,$60,$fc,$00  ; 2
!byte $78,$cc,$0c,$38,$0c,$cc,$78,$00  ; 3
!byte $1c,$3c,$6c,$cc,$fc,$0c,$0c,$00  ; 4
!byte $fc,$c0,$f8,$0c,$0c,$cc,$78,$00  ; 5
!byte $38,$60,$c0,$f8,$cc,$cc,$78,$00  ; 6
!byte $fc,$cc,$0c,$18,$30,$30,$30,$00  ; 7
!byte $78,$cc,$cc,$78,$cc,$cc,$78,$00  ; 8
!byte $78,$cc,$cc,$7c,$0c,$18,$70,$00  ; 9

; $3a: :
!byte $00,$60,$60,$00,$60,$60,$00,$00

; $3b: ;   $3c: <   $3d: =   $3e: >
!fill 8, 0
!byte $0c,$18,$30,$60,$30,$18,$0c,$00
!byte $00,$00,$fc,$00,$fc,$00,$00,$00
!byte $60,$30,$18,$0c,$18,$30,$60,$00

; $3f: ?
!byte $78,$cc,$0c,$18,$30,$00,$30,$00

; ---------------------------------------------------------------
; $40-$4f: UI tiles (text.asm / title.asm)
; ---------------------------------------------------------------
TILE_BLOCK   = $40              ; full cell: big count digit, sun interior
TILE_ST_OPEN = $41              ; station, upcoming (ring)
TILE_ST_DONE = $42              ; station, done (disc)
TILE_ST_CUR  = $43              ; station, current (ringed disc)
TILE_PIP_OFF = $44              ; beat pip, unlit
TILE_PIP_ON  = $45              ; beat pip, lit
TILE_FLOOR   = $46              ; horizon line (row 20)
TILE_ARROW   = $47              ; title selection marker
!byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff  ; $40 block
!byte $3c,$42,$81,$81,$81,$81,$42,$3c  ; $41 ring
!byte $3c,$7e,$ff,$ff,$ff,$ff,$7e,$3c  ; $42 disc
!byte $3c,$42,$99,$bd,$bd,$99,$42,$3c  ; $43 ringed disc
!byte $00,$00,$00,$18,$18,$00,$00,$00  ; $44 pip off (dot)
!byte $00,$18,$3c,$7e,$7e,$3c,$18,$00  ; $45 pip on (diamond)
!byte $00,$00,$00,$00,$00,$00,$ff,$ff  ; $46 floor line
!byte $00,$60,$78,$7e,$7e,$78,$60,$00  ; $47 arrow
!fill 8 * 8, 0                         ; $48-$4f spare

; $50-$6f: backdrop tiles (RAM, loaded from bd_tiles at run time)
!fill $20 * 8, 0
; $70-$7f: glyph area C (RAM, kana count word)
!fill $10 * 8, 0

; $80-$ff: dynamic glyph areas A and B (filled at run time)
!fill $80 * 8, 0
charset_end:
!if * > CHARSET_LIMIT { !error "charset overflows" }
