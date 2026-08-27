; ============================================================================
; sndlib.asm — the Flommodore AUR-1 runtime (Block 16, tasks 16.2-16.4).
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
;   snd_store_patch(R1 = index)     chip -> patch, the inverse of load
;   snd_tick()                      advance the mod tables, once a frame
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
; nothing moves, the sentence was just wrong past +$0A. (Fixed in rev. 5.)
;
; The voice blocks have the same shape for a different reason: +$0B/+$0C
; hold a wavetable SLOT, which has to be resolved to an address, and +$03's
; gate bit must not arrive set or loading a patch would sound it.
;
; ----------------------------------------------------------------------------
; A PATCH IS NOT RECOVERABLE FROM THE CHIP, which is why snd_store_patch
; UPDATES a record rather than building one.
;
; Nine bytes of every patch never reach the AUR-1 at all:
;
;   voice +$0C   mod mask     the chip uses that offset for VWTBHI
;   global +$0B  architecture   ) all five sit on ASTAT, AOSCSEL, AOSC and
;   global +$0C  transpose      ) AENV, which a loader must not write —
;   global +$0D  tick divider   ) see the correction note above
;   global +$0E  flags          )
;   global +$0F  reserved       )
;
; A tenth, the wavetable slot at voice +$0B, survives only because it can be
; derived back out of VWTB: slot = (VWTB - pool) / 16.
;
; So a save that snapshotted the registers would silently drop a patch's
; architecture, transpose, tick rate and every mod-table routing — the parts
; that make it a program rather than a chord. snd_store_patch writes back
; only what the chip actually holds and leaves the rest of the record alone.
; ----------------------------------------------------------------------------
;
; ----------------------------------------------------------------------------
; NEVER SHIFT BY 16. The Gab-16 masks a shift count to FOUR BITS
; (cpu.zig's shiftAmount truncates rb to u4), so SHL/SHR by 16 is a shift by
; ZERO — silently, with no trap. Registers are 20 bits wide, so splitting a
; pointer into halves is exactly the operation that wants a 16-shift, and
; exactly the one that cannot have it. Every high half here is done as TWO
; shifts of 8, the idiom tests/genroms.zig spells out as "shift down 8+8".
;
; This cost a full debugging cycle: snd_init stored $11000 unshifted, kept
; its low half, and snd_load_patch then read patches from $01090 instead of
; $11090 — zeroed RAM, so every register came back 0 with no error anywhere.
; A pointer below $10000 hides it completely, which is why the earlier
; embedded-bank demos passed.
; ----------------------------------------------------------------------------
; ============================================================================

; The generated tables come first so the code section can use their EQUs:
; labels resolve across sections, but an EQU wants to exist before its use.
;
; All three are emitted by flsnd (`zig build notes` and `zig build tables`)
; and all three are here rather than in the app because flas resolves an
; INCLUDE relative to the including file — src/lib/ is where they land, so
; src/lib/ is what can include them. Any program that links sndlib gets
; note_table, cutoff_table, adsr_attack_ms and adsr_decay_ms as globals.
    SECTION data
    INCLUDE "notes.inc"
    INCLUDE "cutoff.inc"
    INCLUDE "adsr.inc"

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
; wavetable and mod-table pools start, and leave the chip silent. R1 <- 0,
; or $FFFF if the bank is not a v1 .flsnd. Clobbers R1-R4, R12.
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
    LI   R12, 8                  ; TWO shifts of 8, never one of 16 — see
    SHR  R1, R5, R12             ; the note at the top of this file
    SHR  R1, R1, R12
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

    ; Mod tables follow the wavetables: bank + 16 + patches*128 +
    ; wavetables*256. Kept as a plain address — nothing divides it.
    LB   R1, [R5 + 4]            ; patch count
    LI   R12, 128
    MUL  R1, R1, R12
    ADDI R1, R1, 16
    LB   R12, [R5 + 5]           ; wavetable count
    LI   R2, 256
    MUL  R12, R12, R2
    ADD  R1, R1, R12
    ADD  R1, R1, R5
    LOAD_ADDR R4, snd_modbase
    SW   [R4], R1
    LI   R12, 8
    SHR  R1, R1, R12
    SHR  R1, R1, R12
    SW   [R4 + 2], R1

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
    LI   R12, 8
    SHL  R6, R6, R12
    SHL  R6, R6, R12
    LW   R12, [R4]
    OR   R6, R6, R12
    ADD  R5, R5, R6              ; R5 = patch base

    LOAD_ADDR R4, snd_patch      ; snd_tick needs it later
    SW   [R4], R5
    LI   R2, 8
    SHR  R12, R5, R2
    SHR  R12, R12, R2
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

    ; A new patch restarts every mod table from step 0 with no
    ; accumulated delta — otherwise the previous patch's sweep would
    ; carry into this one.
    LI   R1, 0
lp_modclear:
    LOAD_ADDR R4, snd_modstep
    ADD  R4, R4, R1
    ADD  R4, R4, R1
    SW   [R4], R0
    LOAD_ADDR R4, snd_modcnt
    ADD  R4, R4, R1
    ADD  R4, R4, R1
    SW   [R4], R0
    LOAD_ADDR R4, snd_modacc
    ADD  R4, R4, R1
    ADD  R4, R4, R1
    SW   [R4], R0
    ADDI R1, R1, 1
    CMPI R1, 4
    BNE  lp_modclear

    LI   R1, 0
    POP  R7
    POP  R6
    POP  R5
    POP  LR
    RET

; ----------------------------------------------------------------------------
; snd_store_patch (R1 = patch index) — write the chip's live state back into
; patch `index` of the loaded bank, in place. R1 <- 0. Clobbers R1-R4, R12;
; R5-R7 saved.
;
; The exact inverse of snd_load_patch for the bytes the chip holds, and a
; deliberate no-op for the nine it does not (see the header). The gate is
; masked off on the way out for the same reason it is masked on the way in:
; a saved patch that sounds the moment it is loaded is a broken patch.
;
; The bank must be writable. An embedded bank in a program's data section is;
; one still sitting in a disk buffer is too, but a caller that wants the
; result persisted has to write the sectors itself afterwards.
; ----------------------------------------------------------------------------
snd_store_patch:
    PUSH LR
    PUSH R5
    PUSH R6
    PUSH R7
    ANDI R1, R1, $1F
    LI   R12, 128
    MUL  R5, R1, R12
    ADDI R5, R5, 16
    LOAD_ADDR R4, snd_bank
    LW   R6, [R4 + 2]
    LI   R12, 8
    SHL  R6, R6, R12             ; two shifts of 8, never one of 16
    SHL  R6, R6, R12
    LW   R12, [R4]
    OR   R6, R6, R12
    ADD  R5, R5, R6              ; R5 = patch base

    LI   R6, 0                   ; voice index
sp_voice:
    MOV  R1, R6
    VOICE_BASE R7, R1            ; R7 = chip voice base
    LI   R12, 16
    MUL  R4, R6, R12
    ADD  R4, R4, R5              ; R4 = patch voice block

    LI   R1, 0
sp_byte:
    CMPI R1, $03                 ; gate is masked, below
    BEQ  sp_skip
    CMPI R1, $0B                 ; slot is derived, below
    BEQ  sp_skip
    CMPI R1, $0C                 ; mod mask: the chip has VWTBHI here, so
    BEQ  sp_skip                 ; copying it would destroy the routing
    ADD  R12, R7, R1
    LB   R2, [R12]
    ADD  R12, R4, R1
    SB   [R12], R2
sp_skip:
    ADDI R1, R1, 1
    CMPI R1, $0F
    BNE  sp_byte

    LB   R2, [R7 + $03]          ; ring and sync keep; the gate does not
    ANDI R2, R2, $60
    SB   [R4 + $03], R2

    ; VWTB back to a slot number. Both are in 16-byte units, and a table is
    ; 256 bytes, so the difference divides by 16 exactly.
    LB   R2, [R7 + $0B]
    LB   R12, [R7 + $0C]
    LI   R1, 8
    SHL  R12, R12, R1
    OR   R2, R2, R12
    LOAD_ADDR R12, snd_wtdiv16
    LW   R12, [R12]
    SUB  R2, R2, R12
    LI   R1, 4
    SHR  R2, R2, R1
    ANDI R2, R2, $0F
    SB   [R4 + $0B], R2

    ADDI R6, R6, 1
    CMPI R6, 4
    BNE  sp_voice

    ; Globals +$00..+$0A only. +$0B..+$0F are the patch's own metadata and
    ; the chip has never held them.
    LOAD_ADDR R7, AURG
    LI   R1, 0
sp_glob:
    ADD  R12, R7, R1
    LB   R2, [R12]
    ADD  R12, R5, R1
    SB   [R12 + $40], R2
    ADDI R1, R1, 1
    CMPI R1, $0B
    BNE  sp_glob

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

    ; Remember the note the voice is sounding: arpeggio and vibrato are
    ; offsets FROM it, and the chip only stores a phase increment.
    LI   R12, 1
    SHR  R2, R2, R12             ; back from byte index to note index
    ANDI R12, R1, 3
    LOAD_ADDR R3, snd_note
    ADD  R3, R3, R12
    ADD  R3, R3, R12
    SW   [R3], R2

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
; snd_tick — advance every armed mod table one frame. Call once per frame,
; after SYS_VBLANK or your own frame edge. Clobbers R1-R4, R12; R5-R9 saved.
;
; This is the routine that makes a patch a PROGRAM. The AUR-1 has no LFO,
; no pulse-width sweep and no envelope-to-filter routing, so every moving
; parameter is a CPU write; a patch that sounds like anything is a
; per-frame register script (v1.3 §5.2).
;
; Two dividers, deliberately. The patch-wide tick divider sets how often
; anything moves at all — one knob to halve a whole sound's motion — and
; each table's own speed then counts those steps, so an arpeggio can run
; four times faster than a filter sweep inside the same patch.
;
; SIGNEDNESS, which the amendment leaves open: a table byte is always
; signed in delta mode, since a sweep that cannot go down is not a sweep.
; In absolute mode it is signed for arpeggio and pitch (offsets from the
; sounding note, useless one-way) and unsigned for pulse width and cutoff
; (register values, which have no negative). Recorded as SND-d.
; ----------------------------------------------------------------------------
snd_tick:
    PUSH LR
    PUSH R5
    PUSH R6
    PUSH R7
    PUSH R8
    PUSH R9

    LOAD_ADDR R4, snd_tickdiv
    LW   R1, [R4]
    LW   R2, [R4 + 2]
    ADDI R2, R2, 1
    CMP  R2, R1
    BCC  tick_wait               ; the patch-wide divider says not yet
    SW   [R4 + 2], R0
    JMPA tick_run
tick_wait:
    SW   [R4 + 2], R2
    JMPA tick_exit

tick_run:
    LOAD_ADDR R4, snd_patch      ; R7 = the patch being played
    LW   R7, [R4 + 2]
    LI   R12, 8
    SHL  R7, R7, R12
    SHL  R7, R7, R12
    LW   R12, [R4]
    OR   R7, R7, R12
    CMPI R7, 0
    BEQ  tick_exit               ; nothing loaded yet

    LI   R5, 0                   ; table index
tick_table:
    LI   R12, 8
    MUL  R6, R5, R12
    ADD  R6, R6, R7
    ADDI R6, R6, $60             ; R6 = this table's descriptor
    LB   R1, [R6]                ; target
    CMPI R1, 0
    BEQ  tick_next               ; table off

    LOAD_ADDR R4, snd_modcnt     ; its own speed counter
    ADD  R4, R4, R5
    ADD  R4, R4, R5
    LW   R2, [R4]
    ADDI R2, R2, 1
    LB   R3, [R6 + 4]            ; speed
    CMPI R3, 0
    BNE  tick_speed
    LI   R3, 1                   ; speed 0 reads as every step
tick_speed:
    CMP  R2, R3
    BCC  tick_hold
    SW   [R4], R0
    JMPA tick_step
tick_hold:
    SW   [R4], R2
    JMPA tick_next

tick_step:
    LOAD_ADDR R4, snd_modstep    ; R8 = the step to play
    ADD  R4, R4, R5
    ADD  R4, R4, R5
    LW   R8, [R4]

    LOAD_ADDR R12, snd_modbase   ; R9 = the byte at that step
    LW   R9, [R12 + 2]
    LI   R3, 8
    SHL  R9, R9, R3
    SHL  R9, R9, R3
    LW   R3, [R12]
    OR   R9, R9, R3
    LB   R3, [R6 + 1]            ; table slot
    ANDI R3, R3, $0F
    LI   R12, 32
    MUL  R3, R3, R12
    ADD  R9, R9, R3
    ADD  R9, R9, R8
    LB   R9, [R9]

    LB   R3, [R6 + 5]            ; mode
    CMPI R3, 0
    BNE  tick_delta

    ; Absolute: signed for arpeggio (1) and pitch (4), unsigned for the
    ; register targets (SND-d).
    LB   R3, [R6]
    CMPI R3, 2
    BEQ  tick_apply
    CMPI R3, 3
    BEQ  tick_apply
    CMPI R9, $80
    BCC  tick_apply
    SUBI R9, R9, 256
    JMPA tick_apply

tick_delta:
    CMPI R9, $80                 ; delta steps are always signed
    BCC  tick_accum
    SUBI R9, R9, 256
tick_accum:
    LOAD_ADDR R4, snd_modacc
    ADD  R4, R4, R5
    ADD  R4, R4, R5
    LW   R3, [R4]
    ADD  R3, R3, R9
    ANDI R3, R3, $FFFF
    SW   [R4], R3
    MOV  R9, R3

tick_apply:
    LB   R3, [R6]
    CMPI R3, 3
    BEQ  tick_filter             ; the filter is shared, not per-voice

    LI   R2, 0                   ; voice index
tick_voice:
    LI   R12, 16                 ; does this table drive this voice?
    MUL  R3, R2, R12
    ADD  R3, R3, R7
    LB   R3, [R3 + $0C]          ; the voice's mod mask
    LI   R12, 1
    SHL  R12, R12, R5
    AND  R3, R3, R12
    CMPI R3, 0
    BEQ  tick_voice_next

    LI   R12, 16
    MUL  R4, R2, R12
    LI   R12, (AUR & $FFFF)
    ADD  R4, R4, R12
    LUI  R4, (AUR >> 16)         ; R4 = chip voice base

    LB   R3, [R6]
    CMPI R3, 2
    BEQ  tick_pulse
    CMPI R3, 4
    BEQ  tick_pitch

    ; Target 1 — arpeggio: retune to the sounding note plus R9 semitones.
    LOAD_ADDR R12, snd_note
    ADD  R12, R12, R2
    ADD  R12, R12, R2
    LW   R3, [R12]
    ADD  R3, R3, R9
    CMPI R3, NOTE_COUNT
    BCS  tick_voice_next         ; off the end of the table: leave it be
    LI   R12, (note_table & $FFFF)
    LUI  R12, (note_table >> 16)
    ADD  R3, R3, R3
    ADD  R12, R12, R3
    LW   R3, [R12]
    SB   [R4 + $00], R3
    LI   R12, 8
    SHR  R3, R3, R12
    SB   [R4 + $01], R3
    JMPA tick_voice_next

tick_pulse:
    ; Target 2 — pulse width straight into VPULSE.
    SB   [R4 + $06], R9
    JMPA tick_voice_next

tick_pitch:
    ; Target 4 — vibrato: the sounding note's increment, plus R9. Fine
    ; detune rather than semitones, so it moves smoothly.
    LOAD_ADDR R12, snd_note
    ADD  R12, R12, R2
    ADD  R12, R12, R2
    LW   R3, [R12]
    LI   R12, (note_table & $FFFF)
    LUI  R12, (note_table >> 16)
    ADD  R3, R3, R3
    ADD  R12, R12, R3
    LW   R3, [R12]
    ADD  R3, R3, R9
    ANDI R3, R3, $FFFF
    SB   [R4 + $00], R3
    LI   R12, 8
    SHR  R3, R3, R12
    SB   [R4 + $01], R3

tick_voice_next:
    ADDI R2, R2, 1
    CMPI R2, 4
    BNE  tick_voice
    JMPA tick_advance

tick_filter:
    ; Target 3 — cutoff. The table byte is the top 8 of the 12-bit
    ; AFCUT, so value<<4 lands as AFCUTHI = value, AFCUTLO = 0. The mod
    ; mask is ignored: there is one filter, and AMFILT already decides
    ; which voices reach it (v1.1 §6.1).
    LOAD_ADDR R4, AURG
    SB   [R4 + $05], R0          ; AFCUTLO
    SB   [R4 + $06], R9          ; AFCUTHI

tick_advance:
    LOAD_ADDR R4, snd_modstep
    ADD  R4, R4, R5
    ADD  R4, R4, R5
    ADDI R8, R8, 1
    LB   R3, [R6 + 2]            ; length
    CMPI R3, 0
    BNE  tick_len
    LI   R3, 1
tick_len:
    CMP  R8, R3
    BCC  tick_store
    LB   R12, [R6 + 3]           ; loop point
    CMPI R12, $FF
    BNE  tick_loop
    SUBI R8, R3, 1               ; one-shot: hold the last step
    JMPA tick_store
tick_loop:
    MOV  R8, R12
tick_store:
    SW   [R4], R8

tick_next:
    ADDI R5, R5, 1
    CMPI R5, 4
    BNE  tick_table

tick_exit:
    POP  R9
    POP  R8
    POP  R7
    POP  R6
    POP  R5
    POP  LR
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
snd_modbase:   DS 4             ; mod-table pool base
snd_note:      DS 8             ; 4 x the note each voice is sounding
snd_modstep:   DS 8             ; 4 x current step index
snd_modcnt:    DS 8             ; 4 x frames since this table stepped
snd_modacc:    DS 8             ; 4 x accumulated value, delta mode
