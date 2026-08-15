; ============================================================================
; sndlib.asm — the Flommodore AUR-1 runtime (Block 16, tasks 16.2-16.3).
;
; A relocatable library, not a program: assemble with flas, link into any
; .flapp alongside your own code. Every label here is a global symbol, so a
; program calls snd_note_on directly once fll has resolved it.
;
; Register conventions follow decision be, the same contract the BIOS
; syscalls use: arguments in R1-R3, result in R1, callers may lose R1-R4
; and R12. R5-R11, R13, LR and SP are preserved.
;
; It talks to the chip directly rather than through SYS_SND* — a library
; that works before the BIOS exists is more useful than one that does not,
; and it avoids a second opinion about what "silent" means.
;
;   snd_init(R1 = bank base)        validate a .flsnd bank, silence the chip
;   snd_load_patch(R1 = index)      write a patch to the registers
;   snd_note_on(R1 = voice, R2 = note)
;   snd_note_off(R1 = voice)
;   snd_stop_all()
;   snd_tick()                      mod tables — task 16.4, next commit
;
; ----------------------------------------------------------------------------
; THE GLOBAL BLOCK IS 11 BYTES, NOT 16 — a correction to amendment v1.3.
;
; §5.2 says a patch's first 80 bytes are "a byte image of $80100-$8014F", so
; loading one should be a straight block copy. That was true when §5.2 was
; written and stopped being true three sections earlier in the same
; document: §1.2 defined AOSCSEL at $8014C, and §5.2 puts the patch's
; TRANSPOSE byte at that same offset. A 16-byte copy would write transpose
; into AOSCSEL and silently redirect the oscilloscope AURED reads.
;
;   +$00..+$0A  AMVOL..AIRQEN   genuine chip image, copied
;   +$0B        ASTAT (w1c)     patch: architecture
;   +$0C        AOSCSEL (RW)    patch: transpose   <-- the collision
;   +$0D        AOSC (RO)       patch: tick divider
;   +$0E        AENV (RO)       patch: flags
;   +$0F        reserved        patch: reserved
;
; Only $8014D/$8014E are read-only enough to make a blind copy harmless.
; So: copy +$00..+$0A, and read the last five as patch metadata. The claim
; to fix in the amendment is the extent of the image, not the layout —
; nothing moves, the sentence was just wrong past +$0A.
;
; The voice blocks have the same shape for a different reason: +$0B/+$0C
; hold a wavetable SLOT, which has to be resolved to an address, and +$03's
; gate bit must not arrive set or loading a patch would sound it.
; ============================================================================

; The note table and its EQUs come first so the code section can use them:
; labels resolve across sections, but an EQU wants to exist before its use.
    SECTION data
    INCLUDE "notes.inc"

    SECTION code

    EQU AUR,     $80100          ; voice n at n*$10; globals at +$40
    EQU AURG,    $80140

MACRO LOAD_ADDR reg, addr        ; amendment §1.2: full 20-bit load
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO

MACRO VOICE_BASE reg, vreg       ; reg <- AUR + 16*(vreg & 3)
    ANDI \vreg, \vreg, 3
    LI   R12, 16
    MUL  \reg, \vreg, R12
    LI   R12, (AUR & $FFFF)
    ADD  \reg, \reg, R12
    LUI  \reg, (AUR >> 16)
ENDMACRO

; ----------------------------------------------------------------------------
; snd_init (R1 = .flsnd bank base) — validate the bank, remember where its
; wavetable pool starts, and leave the chip silent. R1 <- 0, or $FFFF if the
; bank is not a v1 .flsnd. Clobbers R1-R4, R12.
; ----------------------------------------------------------------------------
snd_init:
    PUSH LR
    PUSH R5
    MOV  R5, R1
    LB   R12, [R5]
    CMPI R12, $46                ; 'F'
    BNE  init_bad
    LB   R12, [R5 + 1]
    CMPI R12, $53                ; 'S'
    BNE  init_bad
    LB   R12, [R5 + 2]           ; version, low byte
    CMPI R12, 1
    BNE  init_bad

    LOAD_ADDR R4, snd_bank       ; a 20-bit pointer in two words
    SW   [R4], R5
    LI   R1, 16
    SHR  R1, R5, R1
    SW   [R4 + 2], R1

    ; Wavetable pool sits after the header and the patches. VWTB counts
    ; 16-byte units, so keep the pool base pre-divided and never divide
    ; again at note rate.
    LB   R1, [R5 + 4]            ; patch count
    LI   R12, 128
    MUL  R1, R1, R12
    ADDI R1, R1, 16
    ADD  R1, R1, R5
    LI   R12, 4
    SHR  R1, R1, R12
    LOAD_ADDR R4, snd_wtdiv16
    SW   [R4], R1

    CALLA snd_silence
    LI   R1, 0
    JMPA init_done
init_bad:
    LI   R1, $FFFF
init_done:
    POP  R5
    POP  LR
    RET

; ----------------------------------------------------------------------------
; snd_silence — master volume off, nothing routed, no envelope IRQ, all four
; gates released, ASTAT cleared. AMVOLL/AMVOLR are parked at $0F so raising
; AMVOL alone makes sound, the same bargain SYS_SNDINIT strikes (decision
; bp). Clobbers R4, R12.
; ----------------------------------------------------------------------------
snd_silence:
    LOAD_ADDR R4, AUR
    SB   [R4 + $40], R0          ; AMVOL
    SB   [R4 + $43], R0          ; AMVOICE
    SB   [R4 + $44], R0          ; AMFILT
    SB   [R4 + $4A], R0          ; AIRQEN
    SB   [R4 + $03], R0          ; gates
    SB   [R4 + $13], R0
    SB   [R4 + $23], R0
    SB   [R4 + $33], R0
    LI   R12, $0F
    SB   [R4 + $41], R12         ; AMVOLL
    SB   [R4 + $42], R12         ; AMVOLR
    LI   R12, $FF
    SB   [R4 + $4B], R12         ; ASTAT w1c
    RET

; ----------------------------------------------------------------------------
; snd_load_patch (R1 = patch index) — write patch `index` to the chip.
; Clobbers R1-R4, R12; R5-R7 saved.
;
; Per voice: 15 bytes copied, three substituted. Per the header note, only
; 11 of the 16 global bytes are a chip image.
; ----------------------------------------------------------------------------
snd_load_patch:
    PUSH LR
    PUSH R5
    PUSH R6
    PUSH R7
    ANDI R1, R1, $1F
    LI   R12, 128
    MUL  R5, R1, R12
    ADDI R5, R5, 16              ; past the bank header
    LOAD_ADDR R4, snd_bank
    LW   R6, [R4 + 2]
    LI   R12, 16
    SHL  R6, R6, R12
    LW   R12, [R4]
    OR   R6, R6, R12
    ADD  R5, R5, R6              ; R5 = patch base

    LOAD_ADDR R4, snd_patch      ; snd_tick needs it later
    SW   [R4], R5
    LI   R12, 16
    SHR  R12, R5, R12
    SW   [R4 + 2], R12

    LI   R6, 0                   ; voice index
lp_voice:
    MOV  R1, R6
    VOICE_BASE R7, R1            ; R7 = chip voice base
    LI   R12, 16
    MUL  R4, R6, R12
    ADD  R4, R4, R5              ; R4 = patch voice block

    LI   R1, 0
lp_byte:
    CMPI R1, $03                 ; gate — written last, masked
    BEQ  lp_skip
    CMPI R1, $0B                 ; wavetable slot, not an address
    BEQ  lp_skip
    CMPI R1, $0C
    BEQ  lp_skip
    ADD  R12, R4, R1
    LB   R2, [R12]
    ADD  R12, R7, R1
    SB   [R12], R2
lp_skip:
    ADDI R1, R1, 1
    CMPI R1, $0F
    BNE  lp_byte

    ; Wavetable: slot -> address, in the ÷16 units VWTB wants.
    LB   R2, [R4 + $0B]
    ANDI R2, R2, $0F
    LI   R12, 16
    MUL  R2, R2, R12             ; 256 bytes per table, ÷16 = 16 units
    LOAD_ADDR R12, snd_wtdiv16
    LW   R12, [R12]
    ADD  R2, R2, R12
    SB   [R7 + $0B], R2          ; VWTBLO
    LI   R12, 8
    SHR  R2, R2, R12
    SB   [R7 + $0C], R2          ; VWTBHI

    ; Ring and sync come from the patch; the gate never does. Loading a
    ; patch must not sound it.
    LB   R2, [R4 + $03]
    ANDI R2, R2, $60
    SB   [R7 + $03], R2

    ADDI R6, R6, 1
    CMPI R6, 4
    BNE  lp_voice

    ; Globals: +$00..+$0A only (see the header note).
    LOAD_ADDR R7, AURG
    LI   R1, 0
lp_glob:
    ADD  R12, R5, R1
    LB   R2, [R12 + $40]
    ADD  R12, R7, R1
    SB   [R12], R2
    ADDI R1, R1, 1
    CMPI R1, $0B
    BNE  lp_glob

    ; …and the five bytes that are NOT chip registers.
    LB   R2, [R5 + $4B]          ; architecture
    LOAD_ADDR R4, snd_arch
    SW   [R4], R2

    LB   R2, [R5 + $4C]          ; transpose, signed semitones
    CMPI R2, $80
    BCC  ld_transpose
    SUBI R2, R2, 256             ; sign-extend into the 20-bit register
ld_transpose:
    LOAD_ADDR R4, snd_transpose
    SW   [R4], R2

    LB   R2, [R5 + $4D]          ; tick divider
    CMPI R2, 0
    BNE  ld_tickdiv
    LI   R2, 1                   ; 0 would stall every mod table forever
ld_tickdiv:
    LOAD_ADDR R4, snd_tickdiv
    SW   [R4], R2
    SW   [R4 + 2], R0            ; restart the frame counter

    LI   R1, 0
    POP  R7
    POP  R6
    POP  R5
    POP  LR
    RET

; ----------------------------------------------------------------------------
; snd_note_on (R1 = voice 0-3, R2 = note 0-95, C0..B7) — set the pitch and
; gate the voice. R1 <- 0, or $FFFF if the transposed note leaves the table.
; Ring and sync survive; only the gate bit changes. Clobbers R1-R4, R12.
; ----------------------------------------------------------------------------
snd_note_on:
    PUSH R5
    LOAD_ADDR R12, snd_transpose
    LW   R12, [R12]
    ADD  R2, R2, R12
    ; One unsigned compare catches both ends: a negative note wraps to a
    ; very large value, so "below 96" is the whole range check.
    CMPI R2, NOTE_COUNT
    BCC  note_in_range
    LI   R1, $FFFF
    POP  R5
    RET
note_in_range:
    LI   R5, (note_table & $FFFF)
    LUI  R5, (note_table >> 16)
    ADD  R2, R2, R2              ; two bytes per entry
    ADD  R5, R5, R2
    LW   R5, [R5]                ; the phase increment

    VOICE_BASE R4, R1
    SB   [R4 + $00], R5          ; VFREQLO
    LI   R12, 8
    SHR  R12, R5, R12
    SB   [R4 + $01], R12         ; VFREQHI

    LB   R12, [R4 + $03]
    ANDI R12, R12, $60           ; keep ring and sync
    LI   R2, $80
    OR   R12, R12, R2
    SB   [R4 + $03], R12         ; gate on — attack starts here
    LI   R1, 0
    POP  R5
    RET

; ----------------------------------------------------------------------------
; snd_note_off (R1 = voice) — release the gate; the envelope's release
; phase runs on. Routing and ring/sync are untouched, so the voice is ready
; to be gated again. Clobbers R1, R4, R12.
; ----------------------------------------------------------------------------
snd_note_off:
    VOICE_BASE R4, R1
    LB   R12, [R4 + $03]
    ANDI R12, R12, $60
    SB   [R4 + $03], R12
    RET

; ----------------------------------------------------------------------------
; snd_stop_all — release all four gates. Deliberately NOT snd_silence: the
; mix stays configured, so the next note sounds without reloading a patch.
; Clobbers R4, R12.
; ----------------------------------------------------------------------------
snd_stop_all:
    LOAD_ADDR R4, AUR
    LB   R12, [R4 + $03]
    ANDI R12, R12, $60
    SB   [R4 + $03], R12
    LB   R12, [R4 + $13]
    ANDI R12, R12, $60
    SB   [R4 + $13], R12
    LB   R12, [R4 + $23]
    ANDI R12, R12, $60
    SB   [R4 + $23], R12
    LB   R12, [R4 + $33]
    ANDI R12, R12, $60
    SB   [R4 + $33], R12
    RET

; ----------------------------------------------------------------------------
; Library state. bss is NOLOAD, so this costs nothing in the .flapp image.
; 20-bit pointers live as two words, low half first — the DISPATCH-table
; convention from the BIOS.
; ----------------------------------------------------------------------------
    SECTION bss
snd_bank:      DS 4             ; .flsnd bank base
snd_patch:     DS 4             ; the patch snd_tick is running
snd_wtdiv16:   DS 2             ; wavetable pool base, pre-divided by 16
snd_arch:      DS 2             ; 0 = 4x mono, 1 = FM 0+1 + mono, 2 = 2x FM
snd_transpose: DS 2             ; signed semitones, applied by snd_note_on
snd_tickdiv:   DS 2             ; frames per mod-table step
snd_tickcnt:   DS 2             ; frames since the last step
