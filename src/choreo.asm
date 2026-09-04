!zone choreo
; ---------------------------------------------------------------
; choreo.asm — timeline pose decoder.
;
; Every timeline (ids 0..19, see movements.asm) is a delta-coded
; stream in gen_poses.asm: one record per cycle tick (64 ticks),
; each record = 1 mask byte + the bytes of the groups that changed
; (bit n of the mask -> grp_len[n] bytes for pose_cur+grp_off[n]).
; Tick 0 is always a full record, so a seek replays from the start.
;
;   choreo_set_anim  A = timeline id: restart at cycle tick 0
;                    (pose_cur = record 0 afterwards)
;   choreo_tick      advance to zp_local_tick: one record when it is
;                    the next tick, otherwise replay from tick 0
;   pose_cur         12 bytes: fig_y, torso, head, upperL, upperR,
;                    foreL, foreR, thighL, thighR, shinL, shinR
;                    (sprite pointer bytes), split offset
;
; Test builds: -DTEST_ANIM=n forces timeline n (idle 18, bow 19 are
; not reachable through the movement grid).
; ---------------------------------------------------------------

zp_ch_ptr   = zp_fig+0          ; word: next record in the stream
zp_ch_last  = zp_fig+2          ; tick of the record in pose_cur
zp_ch_anim  = zp_fig+3          ; current timeline id
zp_ch_mask  = zp_fig+4          ; mask bits still to process
zp_ch_cnt   = zp_fig+5          ; bytes left in the current group
zp_ch_grp   = zp_fig+6          ; group index (saved across the copy)

POSE_LEN    = 12
CYCLE_TICKS = 64

; A = timeline id 0..19
choreo_set_anim:
!ifdef TEST_ANIM {
        lda #TEST_ANIM
}
        sta zp_ch_anim
        ; fall through
; back to the start of the current timeline and decode tick 0
choreo_restart:
        ldx zp_ch_anim
        lda anim_lo,x
        sta zp_ch_ptr
        lda anim_hi,x
        sta zp_ch_ptr+1
        lda #0
        sta zp_ch_last
        jmp choreo_decode

; advance the decoder to zp_local_tick (0..63)
choreo_tick:
        lda zp_local_tick
        cmp zp_ch_last
        beq .done               ; already decoded
        ldx zp_ch_last
        inx
        cpx #CYCLE_TICKS
        bne +
        ldx #0                  ; 63 -> 0: the cycle wraps
+       stx zp_ch_cnt
        cmp zp_ch_cnt
        bne .seek               ; not the next tick: replay
        cmp #0
        beq choreo_restart      ; next tick is 0: back to the stream start
        sta zp_ch_last
        jmp choreo_decode
.seek:  jsr choreo_restart      ; tick 0 ...
-       lda zp_ch_last
        cmp zp_local_tick
        beq .done
        inc zp_ch_last
        jsr choreo_decode       ; ... then one record per tick
        jmp -
.done:  rts

; decode one record at zp_ch_ptr into pose_cur, advance the pointer
choreo_decode:
        ldy #0
        lda (zp_ch_ptr),y
        sta zp_ch_mask
        iny                     ; Y = offset of the next payload byte
        ldx #0                  ; group index
.grp:   lsr zp_ch_mask
        bcc .next
        stx zp_ch_grp
        lda grp_len,x
        sta zp_ch_cnt
        lda grp_off,x
        tax                     ; X = destination index in pose_cur
-       lda (zp_ch_ptr),y
        sta pose_cur,x
        iny
        inx
        dec zp_ch_cnt
        bne -
        ldx zp_ch_grp
.next:  inx
        cpx #8
        bne .grp
        tya                     ; record length
        clc
        adc zp_ch_ptr
        sta zp_ch_ptr
        bcc +
        inc zp_ch_ptr+1
+       rts

pose_cur:   !fill POSE_LEN, 0
