; ============================================================================
; sndlib_demo.asm — the smallest program that links sndlib (Block 16, 16.8).
;
;   flommodore examples/sndlib_demo.flapp
;
; Plays A4 on voice 0 through a square-wave patch, holds it, releases it,
; and reports through the $00080 = $600D test-ROM protocol so the headless
; harness can assert it end to end.
;
; This is the first program in the tree built from TWO objects — its own
; and sndlib.flobj — so it is also the first real exercise of fll's
; cross-object symbol resolution. Everything before it linked one object
; against a script.
;
; The bank is embedded rather than loaded from disk on purpose: the point
; here is that sndlib works, not that storage does, and an embedded bank
; keeps the audio hash a pure function of the program.
;
; No BIOS needed — sndlib talks to the AUR-1 directly — so this runs as a
; bare .flapp with no --rom.
; ============================================================================

    SECTION code

start:
    LI   R1, $1100
    MOV  SP, R1                  ; the D12 boot stack; sndlib pushes

    ; snd_init validates the bank magic and silences the chip.
    LI   R1, (bank & $FFFF)
    LUI  R1, (bank >> 16)
    CALLA snd_init
    CMPI R1, 0
    BNE  fail

    LI   R1, 0                   ; patch 0 — "DEMO SQUARE"
    CALLA snd_load_patch
    CMPI R1, 0
    BNE  fail

    ; Note 57 is A4 = $028E at ASRATE 0. Spelled as a literal because EQUs
    ; do not cross object files: NOTE_A4 lives in sndlib's translation
    ; unit, not this one.
    LI   R1, 0                   ; voice 0
    LI   R2, 57
    CALLA snd_note_on
    CMPI R1, 0
    BNE  fail

    ; Hold ~120k cycles, half a frame — long past the 2 ms attack.
    LI   R5, 60000
hold:
    SUBI R5, R5, 1
    BNE  hold

    LI   R1, 0
    CALLA snd_note_off

    ; Let the 114 ms release run out before the hash is taken.
    LI   R5, 60000
release:
    SUBI R5, R5, 1
    BNE  release

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

; ============================================================================
; An embedded .flsnd bank: one patch, no wavetables, no mod tables.
; Layout per amendment v1.3 §5.3 (header) and §5.2 (patch record).
; ============================================================================
    SECTION data

bank:
    DB $46, $53                  ; magic 'F','S'
    DB $01, $00                  ; version 1
    DB 1                         ; patch count
    DB 0                         ; wavetable count
    DB 0                         ; mod-table count
    DB 0, 0, 0, 0, 0, 0, 0, 0, 0 ; reserved

    ; --- patch 0: voice block 0 (+$00) --------------------------------
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
    DB $00                       ; mod mask
    DB $0F                       ; VVOLR  centre pan
    DB $0F                       ; VVOLL
    DB $00                       ; reserved

    ; --- voices 1-3: silent (+$10, +$20, +$30) ------------------------
    DS 48

    ; --- global block (+$40) ------------------------------------------
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

    ; --- name (+$50), 16 bytes ----------------------------------------
    DB "DEMO SQUARE     "

    ; --- mod-table descriptors (+$60), 4 x 8 bytes --------------------
    DS 32
