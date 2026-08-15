; ============================================================================
; sndlib_demo.asm — the program that exercises sndlib (Block 16, 16.8).
;
;   flommodore examples/sndlib_demo.flapp
;
; Three patches, chosen to reach every branch in snd_tick:
;
;   patch 0  a plain square A4 — load, note on/off, and the all-tables-off
;            path through snd_tick
;   patch 1  pulse-width sweep + arpeggio — targets 2 and 1, absolute mode
;   patch 2  filter sweep + vibrato — targets 3 and 4, DELTA mode, with a
;            looping table and a one-shot table
;
; Patch 2 exists because of what patch 1 cannot reach. Its tables are short
; enough that neither ever runs past its length, so the loop-point branch
; and the one-shot hold in tick_advance never execute — and those carry an
; $FF special case and a length-1 that are the easiest things here to get
; off by one.
;
; AND THE DEMO CHECKS THE RESULT, rather than only that it survived. A
; $600D and a stable hash prove the program ran and is deterministic; they
; do not prove the tables walked to the right values. A table stepping at
; twice the intended rate would pass both. So after each phase it reads the
; chip registers back and compares them against values derived from the
; descriptors:
;
;   patch 1, 6 frames:  VPULSE = $C0        (speed 1 -> step 5)
;                       VFREQ  = $01EA      (speed 2 -> step 2, A3+7 = E4)
;   patch 2, 6 frames:  AFCUT  = $10 / $00  (delta, wraps to loop point 2)
;                       VFREQ  = $0276      (delta, one-shot holds at -24)
;
; A mismatch reports its check number at $00084 alongside $0BAD, the same
; protocol the generated test ROMs use.
;
; Built from TWO objects, its own and sndlib.flobj, so it is also the
; tree's exercise of fll resolving symbols across an object boundary.
;
; No BIOS: sndlib drives the AUR-1 directly and the frame edge comes from
; polling the VIC's own VSTAT, so this runs as a bare .flapp with no --rom.
; ============================================================================

    SECTION code

    EQU VIC,  $80200             ; +$17 VSTAT, bit 0 = VBLANK
    EQU AUR1, $80100             ; voice 0 block
    EQU AURG, $80140             ; AUR-1 globals

MACRO LOAD_ADDR reg, addr
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO

start:
    LI   R1, $1100
    MOV  SP, R1                  ; the D12 boot stack; sndlib pushes

    LI   R11, 10
    LI   R1, (bank & $FFFF)
    LUI  R1, (bank >> 16)
    CALLA snd_init
    CMPI R1, 0
    BNE  fail

    ; ---- patch 0: a plain square A4 ---------------------------------
    LI   R11, 11
    LI   R1, 0
    CALLA snd_load_patch
    CMPI R1, 0
    BNE  fail
    LI   R11, 12
    LI   R1, 0                   ; voice 0
    LI   R2, 57                  ; A4 — note 57, $028E at ASRATE 0. A
    CALLA snd_note_on            ; literal: EQUs do not cross object files
    CMPI R1, 0
    BNE  fail

    LI   R6, 2
plain_frames:
    CALLA wait_vblank
    CALLA snd_tick               ; no tables armed — the all-off path
    SUBI R6, R6, 1
    BNE  plain_frames

    LI   R1, 0
    CALLA snd_note_off

    ; ---- patch 1: pulse width sweep + arpeggio, absolute mode -------
    LI   R11, 13
    LI   R1, 1
    CALLA snd_load_patch
    CMPI R1, 0
    BNE  fail
    LI   R11, 14
    LI   R1, 0
    LI   R2, 45                  ; A3, so the arpeggio has room above it
    CALLA snd_note_on
    CMPI R1, 0
    BNE  fail

    ; Six frames: the width table (speed 1) walks six of its eight steps
    ; and the arpeggio (speed 2) walks three of its four.
    LI   R6, 6
mod_frames:
    CALLA wait_vblank
    CALLA snd_tick
    SUBI R6, R6, 1
    BNE  mod_frames

    LOAD_ADDR R4, AUR1
    LI   R11, 1
    LB   R1, [R4 + $06]          ; VPULSE — table 0 step 5
    CMPI R1, $C0
    BNE  fail
    LI   R11, 2
    LB   R1, [R4 + $00]          ; VFREQLO — E4 = $01EA
    CMPI R1, $EA
    BNE  fail
    LI   R11, 3
    LB   R1, [R4 + $01]          ; VFREQHI
    CMPI R1, $01
    BNE  fail

    LI   R1, 0
    CALLA snd_note_off

    ; ---- patch 2: delta mode, a looping table and a one-shot --------
    LI   R11, 15
    LI   R1, 2
    CALLA snd_load_patch
    CMPI R1, 0
    BNE  fail
    LI   R11, 16
    LI   R1, 0
    LI   R2, 57                  ; A4 = $028E, the vibrato's centre
    CALLA snd_note_on
    CMPI R1, 0
    BNE  fail

    ; Six frames. The cutoff table (length 4, loop 2) wraps on frame 5;
    ; the pitch table (length 3, one-shot) holds its last step from frame
    ; 4 on, so its accumulator keeps falling: 0, -8, -16, -24.
    LI   R6, 6
delta_frames:
    CALLA wait_vblank
    CALLA snd_tick
    SUBI R6, R6, 1
    BNE  delta_frames

    LOAD_ADDR R4, AURG
    LI   R11, 4
    LB   R1, [R4 + $06]          ; AFCUTHI — accumulator back down to 16
    CMPI R1, $10
    BNE  fail
    LI   R11, 5
    LB   R1, [R4 + $05]          ; AFCUTLO — always 0: the byte is the top 8
    CMPI R1, $00
    BNE  fail
    LOAD_ADDR R4, AUR1
    LI   R11, 6
    LB   R1, [R4 + $00]          ; VFREQLO — $028E - 24 = $0276
    CMPI R1, $76
    BNE  fail
    LI   R11, 7
    LB   R1, [R4 + $01]          ; VFREQHI
    CMPI R1, $02
    BNE  fail

    LI   R1, 0
    CALLA snd_note_off
    CALLA wait_vblank            ; let the release start before we halt

    LI   R11, $600D
    SW   [R0 + $80], R11
parked:
    HLT
    JMPA parked                  ; a late IRQ wakes HLT; re-park

fail:
    SW   [R0 + $84], R11         ; which check
    LI   R11, $0BAD
    SW   [R0 + $80], R11
fail_parked:
    HLT
    JMPA fail_parked

; ----------------------------------------------------------------------------
; wait_vblank — block until the next 0->1 edge of VSTAT bit 0. Drains any
; blank already in progress first, so two calls in a row are two frames
; rather than one. The same shape as SYS_VBLANK, open-coded because this
; program has no BIOS. Clobbers R4, R12.
; ----------------------------------------------------------------------------
wait_vblank:
    LOAD_ADDR R4, VIC
vb_drain:
    LW   R12, [R4 + $17]
    ANDI R12, R12, 1
    BNE  vb_drain                ; still blanking — wait for line 0
vb_wait:
    LW   R12, [R4 + $17]
    ANDI R12, R12, 1
    BEQ  vb_wait                 ; drawing — wait for the blank to start
    RET

; ============================================================================
; An embedded .flsnd bank: three patches, no wavetables, four mod tables.
; Layout per amendment v1.3 §5.3 (header) and §5.2 (patch record).
; ============================================================================
    SECTION data

bank:
    DB $46, $53                  ; magic 'F','S'
    DB $01, $00                  ; version 1
    DB 3                         ; patch count
    DB 0                         ; wavetable count
    DB 4                         ; mod-table count
    DB 0, 0, 0, 0, 0, 0, 0, 0, 0 ; reserved

    ; ================= patch 0 — "DEMO SQUARE" =======================
    DB $00, $00                  ; VFREQ — snd_note_on overwrites this
    DB $01                       ; VWAVE  square
    DB $00                       ; VCTRL  no ring/sync; gate cleared on load
    DB $00                       ; VADSR0 attack idx 0 (2 ms), decay idx 0
    DB $F4                       ; VADSR1 sustain 15, release idx 4 (114 ms)
    DB $00                       ; VPULSE
    DB $FF                       ; VVOL   full pre-mixer
    DB $00, $00                  ; VMOD   no FM
    DB $00                       ; VFBK
    DB $00                       ; wavetable slot (unused by a square)
    DB $00                       ; mod mask — no tables drive this voice
    DB $0F                       ; VVOLR  centre pan
    DB $0F                       ; VVOLL
    DB $00                       ; reserved
    DS 48                        ; voices 1-3 silent

    DB $FF                       ; AMVOL
    DB $0F                       ; AMVOLL
    DB $0F                       ; AMVOLR
    DB $01                       ; AMVOICE — voice 0 only
    DB $00                       ; AMFILT  — dry
    DB $00, $00                  ; AFCUT
    DB $00                       ; AFRESON
    DB $00                       ; AFMODE
    DB $00                       ; ASRATE  44.1 kHz — the note table's rate
    DB $00                       ; AIRQEN
    ; …the chip image ends here (v1.3 §5.2 rev. 5). The next five bytes
    ; are patch metadata sitting on ASTAT/AOSCSEL/AOSC/AENV, and
    ; snd_load_patch reads them rather than writing them.
    DB $00                       ; architecture: 4x mono
    DB $00                       ; transpose
    DB $01                       ; tick divider
    DB $00                       ; flags
    DB $00                       ; reserved
    DB "DEMO SQUARE     "        ; name (+$50)
    DS 32                        ; mod descriptors (+$60) — none

    ; ================= patch 1 — "MOD PULSE ARP" =====================
    DB $00, $00                  ; VFREQ
    DB $04                       ; VWAVE  pulse — VPULSE actually matters
    DB $00                       ; VCTRL
    DB $00                       ; VADSR0 instant attack
    DB $F4                       ; VADSR1 sustain 15, release idx 4
    DB $80                       ; VPULSE 50% to start; table 0 sweeps it
    DB $FF                       ; VVOL
    DB $00, $00                  ; VMOD
    DB $00                       ; VFBK
    DB $00                       ; wavetable slot
    DB $03                       ; mod mask — tables 0 and 1 drive voice 0
    DB $0F                       ; VVOLR
    DB $0F                       ; VVOLL
    DB $00                       ; reserved
    DS 48                        ; voices 1-3 silent

    DB $FF                       ; AMVOL
    DB $0F                       ; AMVOLL
    DB $0F                       ; AMVOLR
    DB $01                       ; AMVOICE
    DB $00                       ; AMFILT
    DB $00, $00                  ; AFCUT
    DB $00                       ; AFRESON
    DB $00                       ; AFMODE
    DB $00                       ; ASRATE
    DB $00                       ; AIRQEN
    DB $00                       ; architecture: 4x mono
    DB $00                       ; transpose
    DB $01                       ; tick divider — every frame
    DB $00                       ; flags
    DB $00                       ; reserved
    DB "MOD PULSE ARP   "        ; name (+$50)

    ; mod descriptors (+$60): target, slot, length, loop, speed, mode, 0, 0
    DB $02, $00, $08, $00, $01, $00, $00, $00   ; 0: pulse width, every frame
    DB $01, $01, $04, $00, $02, $00, $00, $00   ; 1: arpeggio, every 2nd
    DB $00, $00, $00, $00, $00, $00, $00, $00   ; 2: off
    DB $00, $00, $00, $00, $00, $00, $00, $00   ; 3: off

    ; ================= patch 2 — "DELTA FILT VIB" ====================
    DB $00, $00                  ; VFREQ
    DB $03                       ; VWAVE  sawtooth — plenty for a filter
    DB $00                       ; VCTRL
    DB $00                       ; VADSR0 instant attack
    DB $F4                       ; VADSR1 sustain 15, release idx 4
    DB $00                       ; VPULSE
    DB $FF                       ; VVOL
    DB $00, $00                  ; VMOD
    DB $00                       ; VFBK
    DB $00                       ; wavetable slot
    DB $03                       ; mod mask — tables 0 and 1
    DB $0F                       ; VVOLR
    DB $0F                       ; VVOLL
    DB $00                       ; reserved
    DS 48                        ; voices 1-3 silent

    DB $FF                       ; AMVOL
    DB $0F                       ; AMVOLL
    DB $0F                       ; AMVOLR
    DB $01                       ; AMVOICE
    DB $01                       ; AMFILT — voice 0 through the filter
    DB $00, $00                  ; AFCUT — the delta table drives it from 0
    DB $04                       ; AFRESON
    DB $00                       ; AFMODE low-pass
    DB $00                       ; ASRATE
    DB $00                       ; AIRQEN
    DB $00                       ; architecture: 4x mono
    DB $00                       ; transpose
    DB $01                       ; tick divider
    DB $00                       ; flags
    DB $00                       ; reserved
    DB "DELTA FILT VIB  "        ; name (+$50)

    ; Both tables are delta mode, and both exercise an end-of-table rule
    ; that patch 1 never reaches: table 0 wraps to a loop point, table 1
    ; is one-shot and holds its last step.
    DB $03, $02, $04, $02, $01, $01, $00, $00   ; 0: cutoff, loop to step 2
    DB $04, $03, $03, $FF, $01, $01, $00, $00   ; 1: pitch, one-shot
    DB $00, $00, $00, $00, $00, $00, $00, $00   ; 2: off
    DB $00, $00, $00, $00, $00, $00, $00, $00   ; 3: off

    ; ================= mod tables (32 bytes each) ====================
    ; slot 0 — pulse duty, unsigned in absolute mode (SND-d): a sweep out
    ; to nearly square and back, which is audible as a widening tone.
    DB $20, $40, $60, $80, $A0, $C0, $A0, $60
    DS 24
    ; slot 1 — arpeggio semitones over the sounding note: a major triad
    ; plus the octave. Signed in absolute mode, but all four are positive.
    DB $00, $04, $07, $0C
    DS 28
    ; slot 2 — cutoff deltas. Always signed in delta mode, so $F8 is -8:
    ; up, up, down, hold — then the loop point sends it round from step 2.
    DB $10, $10, $F8, $00
    DS 28
    ; slot 3 — pitch deltas: up, up, down. One-shot, so once the table
    ; ends the last step repeats and the accumulator keeps falling.
    DB $04, $04, $F8
    DS 29
