; ---------------------------------------------------------------
; constants.asm — hardware registers, memory map, zero page, states
; Radio Taiso 64 runs in the all-RAM configuration ($01 = $35):
; I/O visible, no BASIC, no KERNAL, own vectors at $FFFA-$FFFF.
; ---------------------------------------------------------------

; --- hardware ---
CPU_PORT        = $01
VIC_SPR0_X      = $d000         ; +2n = X, +2n+1 = Y
VIC_SPR_MSB     = $d010
VIC_CTRL1       = $d011
VIC_RASTER      = $d012
VIC_SPR_ENABLE  = $d015
VIC_CTRL2       = $d016
VIC_SPR_YEXP    = $d017
VIC_MEMPTR      = $d018
VIC_IRQFLAG     = $d019
VIC_IRQMASK     = $d01a
VIC_SPR_PRIO    = $d01b
VIC_SPR_MC      = $d01c
VIC_SPR_XEXP    = $d01d
BORDER          = $d020
BACKGROUND      = $d021
VIC_SPR0_COL    = $d027
SID_BASE        = $d400
SID_FILT_LO     = $d415
SID_FILT_HI     = $d416
SID_FILT_RES    = $d417
SID_VOL         = $d418
COLOR_RAM       = $d800
CIA1_PRA        = $dc00         ; joy2 / keyboard columns
CIA1_PRB        = $dc01         ; joy1 / keyboard rows
CIA1_DDRA       = $dc02
CIA1_DDRB       = $dc03
CIA1_ICR        = $dc0d
CIA2_PRA        = $dd00         ; VIC bank bits 0-1
CIA2_DDRA       = $dd02
CIA2_TA_LO      = $dd04
CIA2_TA_HI      = $dd05
CIA2_ICR        = $dd0d
CIA2_CRA        = $dd0e
VEC_NMI         = $fffa
VEC_RESET       = $fffc
VEC_IRQ         = $fffe

; --- memory map ---
CODE_START      = $0810
CODE_LIMIT      = $3600         ; code + text + sprite metadata
STAGE_START     = $3600         ; load-time staging (digi part 1 -> $e000)
STAGE_LIMIT     = $4800
SCREEN          = $4000         ; VIC bank 1: $4000-$7fff
SPR_PTRS        = $43f8
DYN_SLOTS       = $4400         ; sprite slots 16..31 (scroller/logo buffers)
CHARSET         = $4800
CHARSET_LIMIT   = $5000
FRAMES          = $5000         ; sprite slots 64..255
FRAMES_LIMIT    = $8000
DATA_START      = $8000
DATA_LIMIT      = $d000
HIMEM_START     = $e000         ; runtime address of the staged block
HIMEM_LIMIT     = $fffa
COLOR_OFFSET_HI = >(COLOR_RAM - SCREEN)   ; $98: SCREEN+$9800 = COLOR_RAM

VIC_BANK_BITS   = 2             ; $dd00 low bits for bank 1
VIC_MEMPTR_VAL  = $02           ; screen at bank+$0000, charset at bank+$0800

; --- raster chain ---
LINE_TOP        = 8             ; logo sprites, restore 25-row mode
LINE_FIGURE     = 66            ; commit figure sprite block (after the logo's last line 59)
LINE_SPLIT_DEF  = 190           ; default shin split (overwritten per tick)
LINE_SCROLL_DEF = 235           ; scroller IRQ line (sprites 4/5 written last, after the shins)
LINE_BORDER     = 249           ; 24-row mode (opens the borders) + music/input/frame tick
IRQ_ENTRIES     = 5

; --- screen colours (hires char mode, any of 16 is legal) ---
COL_BG          = 6             ; indigo
COL_TEXT        = 1
COL_DIM         = 14
COL_GREY        = 15
COL_BRASS       = 7
COL_VERMILLION  = 10
COL_CYAN        = 3
COL_SUN         = 8
COL_RAY         = 11
COL_INK         = 1             ; figure sprites

; --- states ---
ST_TITLE        = 0
ST_PLAY         = 1
ST_PAUSED       = 2
ST_FINISH       = 3

; --- key bits (keys_now / keys_new, low byte then high byte) ---
; plain keys only (F-keys are awkward on Mac keyboards / VICE)
KEY_1           = %00000001     ; title: routine 1;  play: tempo 80 %
KEY_2           = %00000010     ; title: routine 2;  play: tempo 90 %
KEY_SPACE       = %00000100     ; pause / resume, start
KEY_Q           = %00001000     ; back to the title
KEY_STOP        = %00010000     ; RUN/STOP = same as Q
KEY_RETURN      = %00100000     ; start
KEY_3           = %01000000     ; tempo 100 %
KEY_4           = %10000000     ; tempo 110 %
; high byte
KEY_5           = %00000001     ; tempo 120 %
KEY_S           = %00000010     ; figure size 2x / 1x
KEY_L           = %00000100     ; language emphasis
KEY_V           = %00001000     ; voice on / off
JOY_FIRE        = %00010000
JOY_UP          = %00100000
JOY_DOWN        = %01000000

; --- routine / movement grid ---
TICKS_PER_BEAT  = 8
TOTAL_TICKS     = 3072          ; 384 beats
MV_SLOTS        = 15            ; 0 = warm-up, 1..13 movements, 14 = finish

; ---------------------------------------------------------------
; zero page (all of $02-$ff is ours)
; ---------------------------------------------------------------
zp_tmp          = $02
zp_tmp2         = $03
zp_tmp3         = $04
zp_ptr          = $05           ; word
zp_ptr2         = $07           ; word
zp_src          = $09           ; word
zp_dst          = $0b           ; word
zp_x            = $0d
zp_y            = $0e
zp_state        = $0f
zp_frame        = $10           ; frame counter (bottom IRQ)
zp_tick         = $11           ; word: absolute tick (1/8 beat)
zp_beat         = $13           ; low byte of tick>>3 (0..255, wraps)
zp_count8       = $14           ; 1..8
zp_beat_flag    = $15           ; set by IRQ on a new beat, cleared by main
zp_tick_flag    = $16           ; set by IRQ on a new tick, cleared by main
zp_ntsc         = $17           ; 0 = PAL, 1 = NTSC
zp_tick_hold    = $18           ; nonzero = clock frozen (pause)
zp_color        = $19           ; colour for ui_print
zp_len          = $1a
zp_routine      = $1b           ; 0 = No.1, 1 = No.2
zp_cur_mv       = $1c           ; movement slot 0..14
zp_local_tick   = $1d           ; tick & 63 within the cycle
zp_mv_flag      = $1e           ; set by play on a movement change
zp_tick_music   = $1f           ; set by clock on a tick, cleared by music_frame
; $20-$2f figure / choreo
zp_fig          = $20
; $30-$3f music
zp_mus          = $30
; $40-$47 digi
zp_digi         = $40
; $48-$4f scroller
zp_scr          = $48
; $50-$5f ui
zp_ui           = $50
; $60-$6f irq chain
zp_irq_jmp      = $60           ; word: current handler
zp_clock_tbl    = $62           ; word: period table pointer
zp_clock_tmp    = $64           ; IRQ-side scratch (never zp_tmp in the IRQ!)
zp_irq_tmp      = $65           ; IRQ-side scratch for input_scan
; $70-$7f title
zp_title        = $70

; ---------------------------------------------------------------
; macros (defined here so every module can use them)
; ---------------------------------------------------------------
!macro print .col, .row, .str, .color {
        lda #<.str
        sta zp_src
        lda #>.str
        sta zp_src+1
        lda #.col
        sta zp_x
        lda #.row
        sta zp_y
        lda #.color
        sta zp_color
        jsr ui_print
}
