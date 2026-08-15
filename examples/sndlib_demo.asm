; ============================================================================
; sndlib_demo.asm — the program that exercises sndlib (Block 16, 16.8).
;
;   flommodore examples/sndlib_demo.flapp
;
; Two patches, so the demo covers both halves of the library:
;
;   patch 0  a plain square A4 — snd_load_patch, snd_note_on, snd_note_off
;   patch 1  a pulse wave with a width sweep and an arpeggio — snd_tick
;
; Patch 1 is the one that matters. snd_tick is 178 instructions of nested
; table walking, and without a patch carrying mod tables the audio golden
; would not touch a single line of it.
;
; Reports through the $00080 = $600D test-ROM protocol, so the headless
; harness asserts both that it ran and — via the audio golden — that the
; right sound came out.
;
; Built from TWO objects, its own and sndlib.flobj, so it is also the
; tree's exercise of fll resolving symbols across an object boundary.
;
; No BIOS: sndlib drives the AUR-1 directly and the frame edge comes from
; polling the VIC's own VSTAT, so this runs as a bare .flapp with no --rom.
; ============================================================================

    SECTION code

    EQU VIC, $80200              ; +$17 VSTAT, bit 0 = VBLANK

MACRO LOAD_ADDR reg, addr
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO

start:
    LI   R1, $1100
    MOV  SP, R1                  ; the D12 boot stack; sndlib pushes

    LI   R1, (bank & $FFFF)
    LUI  R1, (bank >> 16)
    CALLA snd_init
    CMPI R1, 0
    BNE  fail

    ; ---- patch 0: a plain square A4 ---------------------------------
    LI   R1, 0
    CALLA snd_load_patch
    CMPI R1, 0
    BNE  fail
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

    ; ---- patch 1: pulse width sweep + arpeggio ----------------------
    LI   R1, 1
    CALLA snd_load_patch
    CMPI R1, 0
    BNE  fail
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

    LI   R1, 0
    CALLA snd_note_off
    CALLA wait_vblank            ; let the release start before we halt

    LI   R11, $600D
    SW   [R0 + $80], R11
parked:
    HLT
    JMPA parked                  ; a late IRQ wakes HLT; re-park

fail:
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
; An embedded .flsnd bank: two patches, no wavetables, two mod tables.
; Layout per amendment v1.3 §5.3 (header) and §5.2 (patch record).
; ============================================================================
    SECTION data

bank:
    DB $46, $53                  ; magic 'F','S'
    DB $01, $00                  ; version 1
    DB 2                         ; patch count
    DB 0                         ; wavetable count
    DB 2                         ; mod-table count
    DB 0, 0, 0, 0, 0, 0, 0, 0, 0 ; reserved

    ; ================= patch 0 — "DEMO SQUARE" =======================
    ; voice 0 (+$00)
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

    ; global block (+$40)
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
    ; voice 0 (+$00)
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

    ; global block (+$40)
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

    ; ================= mod tables (32 bytes each) ====================
    ; slot 0 — pulse duty, unsigned in absolute mode (SND-d): a sweep out
    ; to nearly square and back, which is audible as a widening tone.
    DB $20, $40, $60, $80, $A0, $C0, $A0, $60
    DS 24
    ; slot 1 — arpeggio semitones over the sounding note: a major triad
    ; plus the octave. Signed in absolute mode, but all four are positive.
    DB $00, $04, $07, $0C
    DS 28
