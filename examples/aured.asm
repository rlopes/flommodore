; ============================================================================
; aured.asm — the Flommodore sound designer
; (Block 17 tasks 17.6-17.8; Block 18: envelope times and level meters).
;
;   flommodore --rom rom/flommodore.rom examples/aured.flapp
;
; Needs the BIOS ROM for its full font: gfxlib reads glyphs from $FE000 and
; this page shows letters and digits, which tests/roms/font.rom does not
; carry. It does NOT need the BIOS to have booted — the .flapp loader sets
; up the D12 environment, and nothing here touches BIOS RAM. The keyboard is
; read straight off KSTAT/KDATA rather than through SYS_POLLKEY for the same
; reason: KCTRL only gates the IRQ, so polling works on an unbooted machine.
;
; Voice 0's sixteen registers, one selected. Up and Down move the selection,
; Right and Left adjust the selected register by one and write it to the
; chip, and SPACE plays the patch so you can hear what you just changed.
; Arrows rather than +/- so no modifier decoding is needed, and the keys a
; value editor wants are the ones next to each other.
;
; It starts from a real patch rather than a chip full of zeros. An embedded
; one-patch bank is loaded through sndlib at startup, which is what makes
; the panel and the envelope readout show something worth editing — and what
; makes SPACE audible, since a voice with VVOL 0 and nothing routed into the
; mixer would play silence however correct the rest of it was.
;
; ----------------------------------------------------------------------------
; NO DAMAGE LIST, which revises the Phase 9 plan's task 17.5.
;
; The plan called for a damage-rectangle list so the app could repaint only
; what changed. Costed against the real page, that optimises the wrong
; thing:
;
;   full repaint of this page   ~45,000 cycles   19% of a frame
;   gfx_clear                   115,200 cycles   48% of a frame
;
; (Measured, and grown: the register panel alone was 30,700, the envelope
; readout and the meters took it to about 45,000. With gfx_pen rebuilt per
; frame it was 54,300, which the budget check below caught — the estimate
; that preceded it said 14,000 and was wrong twice over, forgetting the pen
; and undercounting the per-glyph loop by two and a half times.)
;
; Repainting everything every frame is affordable; CLEARING is what is not.
; And because glyphs paint their own background through the expansion table,
; a repaint overwrites cleanly — so the clear is a one-time startup cost and
; the damage list would buy nothing but invalidation bugs.
;
; THE SELECTION MARKER IS A CHARACTER, not an inverted pen, for the same
; reason: a pen rebuild is 23,500 cycles, so highlighting a row by switching
; pens would cost more than drawing the entire page.
;
; ----------------------------------------------------------------------------
; Checks, reported as R11 = (check << 8) | observed:
;
;   $01xx  repaint under 60,000 cycles   xx = measured/256, so it reports
;                                        the actual cost when it fails
;   $02xx  repaint over 30,000 cycles     the whole page is still drawn
;   $03xx  frame top-left      $60       the panel outline exists
;   $04xx  just inside it      $00       and is an outline, not a fill
;   $05xx  frame bottom-left   $60       full height
;   $06xx  cursor == 2                   two Down presses were decoded
;   $07xx  VWAVE == 2                    two Right presses reached the chip
;   $08xx  attack[0]  == 2 ms            the generated ADSR table arrived…
;   $09xx  decay[4]   == 114 ms          …and is indexed with the right stride
;   $0Axx  cutoff[128] == 3024 Hz        so did the generated filter table
;   $0Bxx  AENV == 0                     the v1.3 readback is reachable
;   $0Cxx  AOSCSEL == 0                  …and writable, from a guest
;   $0Dxx  VCTRL gate set                 SPACE gated the voice
;   $0Exx  cutoff[AFCUTHI] == 1714 Hz     the filter display indexes right
;
; $06xx and $07xx are the pair that matters most: a cursor that moves but
; never writes fails $07xx, and a write that ignores the cursor fails $06xx
; only if it also mis-tracked — so the two together pin "the selected
; register is the one that changed".
; ============================================================================

    SECTION code

    EQU AUR1, $80100             ; voice 0 register block
    EQU AURG, $80140             ; globals; +$0C AOSCSEL, +$0D AOSC, +$0E AENV
    EQU VIC,  $80200
    EQU KBD,  $80020             ; +0 KSTAT, +1 KDATA (dequeues on read)

    EQU KEY_UP,    $52           ; USB HID usage page $07
    EQU KEY_DOWN,  $51
    EQU KEY_LEFT,  $50
    EQU KEY_RIGHT, $4F
    EQU KEY_SPACE, $2C           ; play the patch
    EQU KEY_ESC,   $29           ; release every voice

    EQU PANEL_X, 4
    EQU PANEL_Y, 12
    EQU PANEL_W, 312
    EQU PANEL_H, 76

    EQU PEN_FG,  $FF             ; grey-ramp palette: index is brightness
    EQU PEN_BG,  $00
    EQU PEN_EDGE, $60

MACRO LOAD_ADDR reg, addr
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO

start:
    LI   R1, $1100
    MOV  SP, R1                  ; D12 boot stack

    CALLA gfx_init
    LI   R1, PEN_BG
    CALLA gfx_clear              ; once, at startup — never per frame

    ; The pen is startup work too, and for the same reason: a rebuild is
    ; ~23,500 cycles, so calling it inside draw_page cost more than every
    ; glyph the page draws. The first version of this file did exactly that
    ; and the repaint budget check below reported 54,300 cycles.
    LI   R1, PEN_FG
    LI   R2, PEN_BG
    CALLA gfx_pen

    LOAD_ADDR R4, aured_cursor
    SW   [R4], R0                ; selection starts on FREQLO

    ; The starting patch. snd_init also gives sndlib its bank pointer and
    ; pool addresses, which snd_note_on and snd_load_patch both need — and
    ; without it snd_transpose would be whatever bss happened to contain,
    ; since bss is NOLOAD and the boot RAM clear stops below $04100.
    LI   R11, 20
    LI   R1, (bank & $FFFF)
    LUI  R1, (bank >> 16)
    CALLA snd_init
    CMPI R1, 0
    BNE  fail
    LI   R11, 21
    LI   R1, 0
    CALLA snd_load_patch
    CMPI R1, 0
    BNE  fail

    ; ---- time one repaint -------------------------------------------
    MFSR R9, CYC
    CALLA draw_page
    MFSR R1, CYC
    SUB  R1, R1, R9              ; cycles the repaint took
    MOV  R10, R1                 ; keep it for both bounds

    ; A BAND, not a ceiling. The page has grown from 30,700 cycles to about
    ; 45,000 as the envelope readout and the meters went in, and it will grow
    ; again; a bound that only caught catastrophes would stop being
    ; informative. Pinning the cost between 30,000 and 60,000 makes any real
    ; change fail AND report its measurement, so each growth is a deliberate
    ; decision recorded in a commit rather than a drift into missing 60 Hz.
    ; The frame is 240,000 cycles; 60,000 is a quarter of it.
    LI   R11, $0100              ; must be affordable…
    LI   R2, 60000
    CMP  R10, R2
    BCC  ck_floor
    LI   R12, 8
    SHR  R1, R10, R12            ; report measured/256 on failure
    ANDI R1, R1, $FF
    OR   R11, R11, R1
    JMPA fail
ck_floor:
    LI   R11, $0200              ; …and must still be drawing the whole page
    LI   R2, 30000
    CMP  R10, R2
    BCS  ck_edge
    LI   R12, 8
    SHR  R1, R10, R12
    ANDI R1, R1, $FF
    OR   R11, R11, R1
    JMPA fail

    ; ---- the panel outline, checked font-independently ---------------
ck_edge:
    LOAD_ADDR R4, $44F04         ; (4, 12)
    LI   R11, $0300
    LB   R1, [R4]
    CMPI R1, PEN_EDGE
    BEQ  ck_inside
    OR   R11, R11, R1
    JMPA fail
ck_inside:
    LOAD_ADDR R4, $45045         ; (5, 13) — inside the outline
    LI   R11, $0400
    LB   R1, [R4]
    CMPI R1, $00
    BEQ  ck_bottom
    OR   R11, R11, R1
    JMPA fail
ck_bottom:
    LOAD_ADDR R4, $4ACC4         ; (4, 87) — bottom edge
    LI   R11, $0500
    LB   R1, [R4]
    CMPI R1, PEN_EDGE
    BEQ  run_loop
    OR   R11, R11, R1
    JMPA fail

    ; ---- the frame loop ---------------------------------------------
    ; Six frames of the real thing: wait for the vertical blank, drain the
    ; keyboard, repaint. No clear, no damage tracking.
run_loop:
    LI   R6, 10                  ; long enough for the injected keys plus
                                 ; two frames of envelope after the note
frame_loop:
    CALLA wait_vblank
    CALLA read_keys
    CALLA draw_page
    SUBI R6, R6, 1
    BNE  frame_loop

    ; ---- did the editing land? --------------------------------------
    ; Two Downs then two Rights were injected at frame boundaries, so the
    ; selection should be on register 2 and that register should hold 2.
    LOAD_ADDR R4, aured_cursor
    LI   R11, $0600
    LW   R1, [R4]
    CMPI R1, 2
    BEQ  ck_edited
    OR   R11, R11, R1
    JMPA fail
ck_edited:
    LOAD_ADDR R4, AUR1
    LI   R11, $0700
    LB   R1, [R4 + 2]            ; VWAVE: the patch's 1, incremented twice
    CMPI R1, 3
    BEQ  ck_tables
    OR   R11, R11, R1
    JMPA fail
ck_tables:
    ; The generated tables, indexed from the guest. These are the values
    ; §4.4 and §4.5 give, so a wrong table or a wrong stride shows here
    ; rather than as a plausible-looking number on screen.
    LOAD_ADDR R4, adsr_attack_ms
    LI   R11, $0800
    LW   R1, [R4]                ; attack index 0 = 2 ms
    CMPI R1, 2
    BEQ  ck_decay
    ANDI R1, R1, $FF
    OR   R11, R11, R1
    JMPA fail
ck_decay:
    LOAD_ADDR R4, adsr_decay_ms
    LI   R11, $0900
    LW   R1, [R4 + 8]            ; decay index 4 = 114 ms
    CMPI R1, 114
    BEQ  ck_cutoff
    ANDI R1, R1, $FF
    OR   R11, R11, R1
    JMPA fail
ck_cutoff:
    LOAD_ADDR R4, cutoff_table
    LI   R11, $0A00
    LW   R1, [R4 + 256]          ; index 128, AFCUT $800 -> 3024 Hz
    LI   R2, 3024
    CMP  R1, R2
    BEQ  ck_readback
    ANDI R1, R1, $FF
    OR   R11, R11, R1
    JMPA fail
ck_readback:
    ; SPACE was injected four frames before the loop ended, and the patch's
    ; attack is 16 ms — about one frame — so by now the envelope must be
    ; RUNNING. Zero here would mean the keypress never reached snd_note_on,
    ; or that it did and the voice was never gated.
    ;
    ; This is the check the whole app is for: it passes only if a keystroke
    ; became a sound, through the editor, sndlib, the chip's envelope
    ; generator and the v1.3 readback that lets a guest see it happen.
    LOAD_ADDR R4, AURG
    LI   R11, $0B00
    LB   R1, [R4 + $0E]          ; AENV
    CMPI R1, $00
    BNE  ck_gate
    OR   R11, R11, R1
    JMPA fail
ck_gate:
    LOAD_ADDR R4, AUR1
    LI   R11, $0D00
    LB   R1, [R4 + $03]          ; VCTRL — the gate bit sndlib set
    ANDI R1, R1, $80
    CMPI R1, $80
    BEQ  ck_oscsel
    OR   R11, R11, R1
    JMPA fail
ck_oscsel:
    ; Reload the base. Inheriting R4 from the previous check is what broke
    ; this once already: ck_gate was inserted between here and the block
    ; that set R4 = AURG, so this read $8010C — voice 0's VWTBHI, whose
    ; value is the wavetable pool base and looked plausible enough to be
    ; confusing. Every check block sets up its own pointer.
    LOAD_ADDR R4, AURG
    LI   R11, $0C00
    LB   R1, [R4 + $0C]          ; AOSCSEL, written 0 by draw_meters
    CMPI R1, $00
    BEQ  ck_filter
    OR   R11, R11, R1
    JMPA fail
ck_filter:
    ; The patch sets AFCUT $600, so the display must resolve to 1714 Hz.
    ; Check $0Axx already proved the table's contents; this proves the
    ; INDEXING — that AFCUTHI reaches the right entry.
    LOAD_ADDR R4, AURG
    LB   R1, [R4 + $06]
    ADD  R1, R1, R1
    LOAD_ADDR R12, cutoff_table
    ADD  R12, R12, R1
    LW   R1, [R12]
    LI   R11, $0E00
    LI   R2, 1714
    CMP  R1, R2
    BEQ  ck_done
    ANDI R1, R1, $FF
    OR   R11, R11, R1
    JMPA fail
ck_done:

    LI   R11, $600D
    SW   [R0 + $80], R11
parked:
    HLT
    JMPA parked

fail:
    SW   [R0 + $84], R11
    LI   R11, $0BAD
    SW   [R0 + $80], R11
fail_parked:
    HLT
    JMPA fail_parked

; ----------------------------------------------------------------------------
; read_keys — drain every queued event and act on the presses. Releases are
; discarded: this is an editor, not a game, so a held key repeating is the
; host's business and not something to emulate. Clobbers R1-R4, R12; R5
; saved.
; ----------------------------------------------------------------------------
read_keys:
    PUSH LR
    PUSH R5
    LOAD_ADDR R5, KBD
rk_loop:
    LW   R12, [R5]               ; KSTAT
    ANDI R12, R12, 1
    BEQ  rk_done                 ; queue empty
    LW   R1, [R5 + 1]            ; KDATA — dequeues on read (§5.3)
    LI   R12, $8000
    AND  R12, R1, R12
    BNE  rk_loop                 ; bit 15 set: a release, ignore it
    ANDI R1, R1, $7F
    CALLA do_key
    JMPA rk_loop
rk_done:
    POP  R5
    POP  LR
    RET

; ----------------------------------------------------------------------------
; do_key (R1 = HID code) — one press. Up/Down wrap around the sixteen
; registers; Right/Left adjust the selected one by a byte, wrapping too,
; because a register editor that stops at the ends hides what the register
; actually does. Clobbers R1-R4, R12.
; ----------------------------------------------------------------------------
do_key:
    LOAD_ADDR R4, aured_cursor
    LW   R2, [R4]
    CMPI R1, KEY_DOWN
    BNE  dk_up
    ADDI R2, R2, 1
    ANDI R2, R2, $0F
    SW   [R4], R2
    RET
dk_up:
    CMPI R1, KEY_UP
    BNE  dk_right
    SUBI R2, R2, 1
    ANDI R2, R2, $0F             ; 0 - 1 wraps to 15
    SW   [R4], R2
    RET
dk_right:
    CMPI R1, KEY_RIGHT
    BNE  dk_left
    LI   R3, 1
    JMPA dk_adjust               ; dk_adjust is no longer adjacent: dk_play
                                 ; and dk_stop sit between, so NEITHER arm
                                 ; can reach it by falling through
dk_left:
    CMPI R1, KEY_LEFT
    BNE  dk_play
    LI   R3, -1
    JMPA dk_adjust
dk_play:
    ; SPACE gates the voice through sndlib rather than by poking VCTRL, so
    ; the note picks up whatever pitch the note table says for A4 and
    ; whatever ring/sync the patch set — the same path a real program uses.
    CMPI R1, KEY_SPACE
    BNE  dk_stop
    PUSH LR                      ; snd_note_on is a call; LR is live here
    LI   R1, 0                   ; voice 0
    LI   R2, 57                  ; A4
    CALLA snd_note_on
    POP  LR
    RET
dk_stop:
    CMPI R1, KEY_ESC
    BNE  dk_ignore
    PUSH LR
    CALLA snd_stop_all
    POP  LR
    RET
dk_adjust:
    LOAD_ADDR R12, AUR1
    ADD  R12, R12, R2            ; the SELECTED register, not a fixed one
    LB   R1, [R12]
    ADD  R1, R1, R3
    ANDI R1, R1, $FF
    SB   [R12], R1
dk_ignore:
    RET

; ----------------------------------------------------------------------------
; draw_page — the whole visible page, every time. Title, panel outline, and
; voice 0's sixteen registers in two columns of eight, each as NAME $XX read
; live off the chip, with '>' against the selected one.
; Clobbers R1-R5, R12; R6-R8 saved.
; ----------------------------------------------------------------------------
draw_page:
    PUSH LR
    PUSH R6
    PUSH R7
    PUSH R8

    LI   R1, 8
    LI   R2, 0
    LOAD_ADDR R3, str_title
    CALLA gfx_text

    LI   R1, PANEL_X
    LI   R2, PANEL_Y
    LI   R3, PANEL_W
    LI   R4, PANEL_H
    LI   R5, PEN_EDGE
    CALLA gfx_frame

    LI   R6, 0                   ; register index 0-15
dp_reg:
    ; Two columns of eight: column = index / 8, row = index & 7.
    LI   R12, 8
    DIV  R7, R6, R12             ; column
    LI   R12, 152
    MUL  R7, R7, R12
    ADDI R7, R7, 8               ; x = 8 or 160, both even
    ANDI R8, R6, 7               ; row
    LI   R12, 8
    MUL  R8, R8, R12
    ADDI R8, R8, 16              ; y = 16 .. 72

    ; the selection marker, in the margin left of the name
    LOAD_ADDR R12, aured_cursor
    LW   R12, [R12]
    CMP  R12, R6
    BNE  dp_unselected
    LOAD_ADDR R3, str_mark
    JMPA dp_marker
dp_unselected:
    LOAD_ADDR R3, str_blank
dp_marker:
    MOV  R1, R7
    SUBI R1, R1, 8               ; x = 0 or 152, still even
    MOV  R2, R8
    CALLA gfx_text

    ; the register's name, from the 8-byte-per-entry table
    LI   R12, 8
    MUL  R3, R6, R12
    LOAD_ADDR R12, reg_names
    ADD  R3, R3, R12
    MOV  R1, R7
    MOV  R2, R8
    CALLA gfx_text

    ; "$XX" built from the live register value
    LOAD_ADDR R4, val_buf
    LI   R12, $24                ; '$'
    SB   [R4], R12
    LOAD_ADDR R12, AUR1
    ADD  R12, R12, R6
    LB   R2, [R12]               ; the register, read off the chip
    LOAD_ADDR R1, val_buf
    ADDI R1, R1, 1
    CALLA fmt_hex8

    MOV  R1, R7
    ADDI R1, R1, 56              ; past the six-character name
    MOV  R2, R8
    LOAD_ADDR R3, val_buf
    CALLA gfx_text

    ADDI R6, R6, 1
    CMPI R6, 16
    BNE  dp_reg

    CALLA draw_env
    CALLA draw_filter
    CALLA draw_meters

    POP  R8
    POP  R7
    POP  R6
    POP  LR
    RET

; ----------------------------------------------------------------------------
; draw_num (R1 = x, R2 = y, R3 = value) — an unsigned decimal at x. The
; column is five characters wide because 24000 ms is the longest thing the
; ADSR tables can produce. Clobbers R1-R4, R12; R5, R6 saved.
; ----------------------------------------------------------------------------
draw_num:
    PUSH LR
    PUSH R5
    PUSH R6
    MOV  R5, R1
    MOV  R6, R2
    LOAD_ADDR R1, val_buf
    MOV  R2, R3
    CALLA fmt_dec
    MOV  R1, R5
    MOV  R2, R6
    LOAD_ADDR R3, val_buf
    CALLA gfx_text
    POP  R6
    POP  R5
    POP  LR
    RET

; ----------------------------------------------------------------------------
; draw_env — the envelope as TIMES, not as register bytes. This is the point
; of the whole exercise: $F4 in ADSR1 means "sustain 15, release 114 ms", and
; the second reading is the one a person designing a sound can act on.
;
; The millisecond values come from adsr_attack_ms and adsr_decay_ms, which
; sndlib carries and flsnd generated from aur1.zig's own arrays — so the
; number displayed and the time the envelope actually takes cannot drift
; apart. Decay and release share one table, which is why REL indexes
; adsr_decay_ms and not a table of its own.
;
; Clobbers R1-R5, R12; R6, R7 saved.
; ----------------------------------------------------------------------------
draw_env:
    PUSH LR
    PUSH R6
    PUSH R7
    LOAD_ADDR R6, AUR1
    LB   R7, [R6 + 4]            ; ADSR0: attack 7:4, decay 3:0

    LI   R1, 8
    LI   R2, 96
    LOAD_ADDR R3, str_atk
    CALLA gfx_text
    LI   R12, 4
    SHR  R1, R7, R12
    ANDI R1, R1, $0F
    ADD  R1, R1, R1              ; two bytes per entry
    LOAD_ADDR R12, adsr_attack_ms
    ADD  R12, R12, R1
    LW   R3, [R12]
    LI   R1, 40
    LI   R2, 96
    CALLA draw_num
    LI   R1, 88
    LI   R2, 96
    LOAD_ADDR R3, str_ms
    CALLA gfx_text

    LI   R1, 120
    LI   R2, 96
    LOAD_ADDR R3, str_dec
    CALLA gfx_text
    ANDI R1, R7, $0F
    ADD  R1, R1, R1
    LOAD_ADDR R12, adsr_decay_ms
    ADD  R12, R12, R1
    LW   R3, [R12]
    LI   R1, 152
    LI   R2, 96
    CALLA draw_num
    LI   R1, 200
    LI   R2, 96
    LOAD_ADDR R3, str_ms
    CALLA gfx_text

    LOAD_ADDR R6, AUR1
    LB   R7, [R6 + 5]            ; ADSR1: sustain 7:4, release 3:0

    LI   R1, 8
    LI   R2, 104
    LOAD_ADDR R3, str_sus
    CALLA gfx_text
    LI   R12, 4
    SHR  R3, R7, R12
    ANDI R3, R3, $0F             ; sustain is a level, not a time
    LI   R1, 40
    LI   R2, 104
    CALLA draw_num

    LI   R1, 120
    LI   R2, 104
    LOAD_ADDR R3, str_rel
    CALLA gfx_text
    ANDI R1, R7, $0F
    ADD  R1, R1, R1
    LOAD_ADDR R12, adsr_decay_ms ; release shares the decay table (§4.4)
    ADD  R12, R12, R1
    LW   R3, [R12]
    LI   R1, 152
    LI   R2, 104
    CALLA draw_num
    LI   R1, 200
    LI   R2, 104
    LOAD_ADDR R3, str_ms
    CALLA gfx_text

    POP  R7
    POP  R6
    POP  LR
    RET

; ----------------------------------------------------------------------------
; draw_filter — the filter as a frequency, not as a register pair.
;
; AFCUT is 12-bit, split as (AFCUTHI << 4) | AFCUTLO, and cutoff_table is
; indexed by AFCUT >> 4 — so the index IS AFCUTHI, with no arithmetic at
; all. That is a happy accident of the table's stride matching the register
; split, not something to rely on if either ever changes.
;
; The table exists because §4.5's curve cannot be evaluated here: it needs
; AFCUT squared, and 4095^2 is 24 bits against a 20-bit register. flsnd
; generates it from the one authoritative formula.
;
; Clobbers R1-R4, R12; R6, R7 saved.
; ----------------------------------------------------------------------------
draw_filter:
    PUSH LR
    PUSH R6
    PUSH R7

    LI   R1, 8
    LI   R2, 144
    LOAD_ADDR R3, str_cut
    CALLA gfx_text

    LOAD_ADDR R6, AURG
    LB   R7, [R6 + $06]          ; AFCUTHI, which is the table index
    ADD  R7, R7, R7              ; two bytes an entry
    LOAD_ADDR R12, cutoff_table
    ADD  R12, R12, R7
    LW   R3, [R12]
    LI   R1, 40
    LI   R2, 144
    CALLA draw_num
    LI   R1, 88
    LI   R2, 144
    LOAD_ADDR R3, str_hz
    CALLA gfx_text

    LOAD_ADDR R6, AURG
    LI   R1, 120
    LI   R2, 144
    LOAD_ADDR R3, str_res
    CALLA gfx_text
    LOAD_ADDR R6, AURG
    LB   R3, [R6 + $07]          ; AFRESON
    LI   R1, 152
    LI   R2, 144
    CALLA draw_num

    LOAD_ADDR R6, AURG
    LB   R7, [R6 + $08]          ; AFMODE
    ANDI R7, R7, 3
    LI   R12, 8
    MUL  R7, R7, R12
    LOAD_ADDR R3, str_modes
    ADD  R3, R3, R7
    LI   R1, 200
    LI   R2, 144
    CALLA gfx_text

    POP  R7
    POP  R6
    POP  LR
    RET

; ----------------------------------------------------------------------------
; draw_bar (R1 = y, R2 = level 0-255) — a 128 px trough with the level
; filled in. The trough is redrawn every frame because a shrinking bar would
; otherwise leave its own tail behind: nothing clears the screen.
; Clobbers R1-R5, R12; R6, R7 saved.
; ----------------------------------------------------------------------------
draw_bar:
    PUSH LR
    PUSH R6
    PUSH R7
    MOV  R6, R1                  ; y
    MOV  R7, R2                  ; level
    LI   R1, 40
    MOV  R2, R6
    LI   R3, 128
    LI   R4, 4
    LI   R5, $18                 ; trough
    CALLA gfx_rect
    LI   R12, 1
    SHR  R3, R7, R12             ; 255 -> 127, so the bar fits the trough
    CMPI R3, 0
    BEQ  bar_done                ; a zero-width rect draws nothing anyway
    LI   R1, 40
    MOV  R2, R6
    LI   R4, 4
    LI   R5, $C0                 ; level
    CALLA gfx_rect
bar_done:
    POP  R7
    POP  R6
    POP  LR
    RET

; ----------------------------------------------------------------------------
; draw_meters — the envelope level and the oscillator's current sample, read
; off the chip through the v1.3 §1.2 readback registers.
;
; This is the first thing outside a test ROM to use them, and the reason
; amendment v1.3 added them: before AOSC and AENV the chip could be written
; but not observed, so an editor could show what it had asked for and never
; what the chip was doing. AENV is the envelope's live level; AOSC is the
; oscillator's latest sample, biased so $80 is the zero crossing.
;
; A single sample per frame is a LEVEL METER, not an oscilloscope. AOSC holds
; one value for a whole 326-cycle sample period, so reading it in a loop
; returns the same byte many times over; a real trace needs the timer-IRQ
; ring buffer §1.5 describes, sampling at 11.25 kHz. That is a later piece of
; work, and calling this a scope would be a lie about what it shows.
;
; Clobbers R1-R5, R12; R6, R7 saved.
; ----------------------------------------------------------------------------
draw_meters:
    PUSH LR
    PUSH R6
    PUSH R7
    LOAD_ADDR R6, AURG
    SB   [R6 + $0C], R0          ; AOSCSEL: voice 0, oscillator source

    LI   R1, 8
    LI   R2, 120
    LOAD_ADDR R3, str_env
    CALLA gfx_text
    LB   R7, [R6 + $0E]          ; AENV
    LI   R1, 120
    MOV  R2, R7
    CALLA draw_bar

    LOAD_ADDR R6, AURG           ; draw_bar reached gfx_rect, which took R6
    LI   R1, 8
    LI   R2, 132
    LOAD_ADDR R3, str_osc
    CALLA gfx_text
    LB   R7, [R6 + $0D]          ; AOSC
    LI   R1, 132
    MOV  R2, R7
    CALLA draw_bar

    POP  R7
    POP  R6
    POP  LR
    RET

; ----------------------------------------------------------------------------
; wait_vblank — block until the next 0->1 edge of VSTAT bit 0. Open-coded
; rather than SYS_VBLANK so the app does not require a booted BIOS.
; Clobbers R4, R12.
; ----------------------------------------------------------------------------
wait_vblank:
    LOAD_ADDR R4, VIC
vb_drain:
    LW   R12, [R4 + $17]
    ANDI R12, R12, 1
    BNE  vb_drain
vb_wait:
    LW   R12, [R4 + $17]
    ANDI R12, R12, 1
    BEQ  vb_wait
    RET

    SECTION data

str_title:
    DB "AURED  VOICE 0", 0
str_mark:
    DB ">", 0
str_blank:
    DB " ", 0
str_atk:
    DB "ATK", 0
str_dec:
    DB "DEC", 0
str_sus:
    DB "SUS", 0
str_rel:
    DB "REL", 0
str_ms:
    DB "MS", 0
str_env:
    DB "ENV", 0
str_osc:
    DB "OSC", 0
str_cut:
    DB "CUT", 0
str_hz:
    DB "HZ", 0
str_res:
    DB "RES", 0

; Eight bytes an entry so AFMODE indexes by a shift. §4.5 modes in order.
str_modes:
    DB "LP", 0, 0, 0, 0, 0, 0
    DB "HP", 0, 0, 0, 0, 0, 0
    DB "BP", 0, 0, 0, 0, 0, 0
    DB "NOTCH", 0, 0, 0

; Eight bytes per entry so the index is a shift, not a search. Names are
; six characters or fewer, which is what puts the value column at x+56.
reg_names:
    DB "FREQLO", 0, 0
    DB "FREQHI", 0, 0
    DB "WAVE", 0, 0, 0, 0
    DB "CTRL", 0, 0, 0, 0
    DB "ADSR0", 0, 0, 0
    DB "ADSR1", 0, 0, 0
    DB "PULSE", 0, 0, 0
    DB "VOL", 0, 0, 0, 0, 0
    DB "MODLO", 0, 0, 0
    DB "MODHI", 0, 0, 0
    DB "FBK", 0, 0, 0, 0, 0
    DB "WTBLO", 0, 0, 0
    DB "WTBHI", 0, 0, 0
    DB "VOLR", 0, 0, 0, 0
    DB "VOLL", 0, 0, 0, 0
    DB "RSVD", 0, 0, 0, 0

; ============================================================================
; The starting patch: one voice, a square wave with an envelope you can hear
; the shape of. Layout per amendment v1.3 §5.3 and §5.2.
; ============================================================================
bank:
    DB $46, $53                  ; magic 'F','S'
    DB $01, $00                  ; version 1
    DB 1                         ; patch count
    DB 0                         ; wavetable count
    DB 0                         ; mod-table count
    DB 0, 0, 0, 0, 0, 0, 0, 0, 0 ; reserved

    DB $00, $00                  ; VFREQ  — snd_note_on sets the pitch
    DB $01                       ; VWAVE  square
    DB $00                       ; VCTRL  gate cleared on load
    DB $24                       ; VADSR0 attack idx 2 (16 ms), decay 4 (114)
    DB $C6                       ; VADSR1 sustain 12, release idx 6 (204 ms)
    DB $00                       ; VPULSE
    DB $FF                       ; VVOL
    DB $00, $00                  ; VMOD
    DB $00                       ; VFBK
    DB $00                       ; wavetable slot
    DB $00                       ; mod mask
    DB $0F, $0F                  ; VVOLR, VVOLL — centre
    DB $00                       ; reserved
    DS 48                        ; voices 1-3 silent

    DB $FF, $0F, $0F             ; AMVOL, AMVOLL, AMVOLR
    DB $01                       ; AMVOICE — voice 0 into the mix
    DB $01                       ; AMFILT  — voice 0 through the filter
    DB $00, $60                  ; AFCUTLO/HI — AFCUT $600, about 1.7 kHz
    DB $08                       ; AFRESON
    DB $00                       ; AFMODE  low-pass
    DB $00                       ; ASRATE  44.1 kHz, the note table's rate
    DB $00                       ; AIRQEN  — chip image ends here (§5.2)
    DB $00, $00, $01, $00, $00   ; arch, transpose, tickdiv, flags, reserved
    DB "INIT PATCH      "
    DS 32                        ; no mod tables

    SECTION bss

aured_cursor:
    DS 2                         ; which register is selected, 0-15
val_buf:
    DS 8                         ; '$' + two hex, or five decimal digits + NUL
