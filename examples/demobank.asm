; ============================================================================
; demobank.asm — the starter .flsnd bank (Block 16, task 16.7).
;
; Assembled absolute and framed by `fll --raw`, so the output is the bank
; file itself, byte for byte — no header, no relocation. fldisk then puts
; it on a volume as DEMOBANK, and examples/sndbank_demo.asm reads it back
; through the BIOS storage syscalls.
;
; WHY ORG $01000 AND NOT $00000. The bank is pure data; the address it is
; assembled at is arbitrary and never appears in the output. It cannot be
; zero, though: fll's raw emitter treats `load_addr == 0` as the marker for
; "relocatable section" (loader.zig's Section comment says so outright), so
; an honest ORG $00000 is indistinguishable from an unplaced one and gets
; rejected. Address 0 is a legal ORG target — it is the vector page — so
; that sentinel is a real limitation rather than a rule. Fixing it needs a
; mode field in .flobj, and the v1.1 header has no spare byte, which is a
; disproportionate change for something no real program wants. Recorded
; here because this file is where the next person will meet it.
;
; Written as assembly rather than emitted by a tool so the bank stays
; reviewable and diffable in the repository: a patch is 128 bytes of
; register values, and a byte changing in a code review is exactly the
; thing you want to see.
;
; Three patches, chosen for what they cover rather than for breadth:
;
;   0  SQUARE LEAD    the plain baseline, so a failure here means the disk
;                     path is broken rather than the patch
;   1  WAVE TRIANGLE  waveform 6 with a wavetable slot — the ONLY thing
;                     that exercises snd_init's wtdiv16 and the slot ->
;                     VWTB resolution in snd_load_patch, neither of which
;                     any test has touched
;   2  FILTER SAW     routed through the shared filter with resonance, so
;                     AMFILT and the filter globals come off the disk too
;
; The plan's original eight-patch survey is deliberately not here. AURED
; is about to become the tool for authoring patches, and hand-writing five
; more in DB lines now would be five more to re-author later.
; ============================================================================

    ORG $01000

; ---------------------------------------------------------------------------
; Bank header (v1.3 §5.3)
; ---------------------------------------------------------------------------
    DB $46, $53                  ; magic 'F','S'
    DB $01, $00                  ; version 1
    DB 3                         ; patch count
    DB 1                         ; wavetable count
    DB 0                         ; mod-table count
    DB 0, 0, 0, 0, 0, 0, 0, 0, 0 ; reserved

; ---------------------------------------------------------------------------
; Patch 0 — "SQUARE LEAD"
; ---------------------------------------------------------------------------
    DB $00, $00                  ; VFREQ  — snd_note_on overwrites
    DB $01                       ; VWAVE  square
    DB $00                       ; VCTRL
    DB $00                       ; VADSR0 instant attack, fastest decay
    DB $F4                       ; VADSR1 sustain 15, release 114 ms
    DB $00                       ; VPULSE
    DB $FF                       ; VVOL
    DB $00, $00                  ; VMOD
    DB $00                       ; VFBK
    DB $00                       ; wavetable slot — unused
    DB $00                       ; mod mask
    DB $0F, $0F                  ; VVOLR, VVOLL
    DB $00                       ; reserved
    DS 48                        ; voices 1-3 silent
    DB $FF, $0F, $0F             ; AMVOL, AMVOLL, AMVOLR
    DB $01                       ; AMVOICE — voice 0
    DB $00                       ; AMFILT  — dry
    DB $00, $00, $00, $00        ; AFCUTLO, AFCUTHI, AFRESON, AFMODE
    DB $00                       ; ASRATE
    DB $00                       ; AIRQEN — chip image ends here (§5.2)
    DB $00, $00, $01, $00, $00   ; arch, transpose, tickdiv, flags, reserved
    DB "SQUARE LEAD     "
    DS 32                        ; no mod tables

; ---------------------------------------------------------------------------
; Patch 1 — "WAVE TRIANGLE". Waveform 6 reads its shape from the wavetable
; pool; slot 0 is the table at the end of this file. snd_load_patch turns
; that slot into a VWTB pair, which is the only place that arithmetic runs.
; ---------------------------------------------------------------------------
    DB $00, $00                  ; VFREQ
    DB $06                       ; VWAVE  wavetable
    DB $00                       ; VCTRL
    DB $00                       ; VADSR0
    DB $F8                       ; VADSR1 sustain 15, release 300 ms
    DB $00                       ; VPULSE
    DB $FF                       ; VVOL
    DB $00, $00                  ; VMOD
    DB $00                       ; VFBK
    DB $00                       ; wavetable slot 0
    DB $00                       ; mod mask
    DB $0F, $0F                  ; VVOLR, VVOLL
    DB $00                       ; reserved
    DS 48
    DB $FF, $0F, $0F
    DB $01                       ; AMVOICE
    DB $00                       ; AMFILT
    DB $00, $00, $00, $00
    DB $00                       ; ASRATE
    DB $00                       ; AIRQEN
    DB $00, $00, $01, $00, $00
    DB "WAVE TRIANGLE   "
    DS 32

; ---------------------------------------------------------------------------
; Patch 2 — "FILTER SAW". Voice 0 through the shared low-pass with some
; resonance, so the filter globals travel on the disk with everything else.
; ---------------------------------------------------------------------------
    DB $00, $00                  ; VFREQ
    DB $03                       ; VWAVE  sawtooth
    DB $00                       ; VCTRL
    DB $00                       ; VADSR0
    DB $F6                       ; VADSR1 sustain 15, release 204 ms
    DB $00                       ; VPULSE
    DB $FF                       ; VVOL
    DB $00, $00                  ; VMOD
    DB $00                       ; VFBK
    DB $00                       ; wavetable slot
    DB $00                       ; mod mask
    DB $0F, $0F                  ; VVOLR, VVOLL
    DB $00                       ; reserved
    DS 48
    DB $FF, $0F, $0F
    DB $01                       ; AMVOICE
    DB $01                       ; AMFILT — voice 0 is routed
    DB $00, $60                  ; AFCUT = $600, mid sweep
    DB $08                       ; AFRESON
    DB $00                       ; AFMODE low-pass
    DB $00                       ; ASRATE
    DB $00                       ; AIRQEN
    DB $00, $00, $01, $00, $00
    DB "FILTER SAW      "
    DS 32

; ---------------------------------------------------------------------------
; Wavetable slot 0 — a symmetric triangle. Unsigned samples with $80 as the
; zero crossing (v1.1 §6.2): rises 0 -> $FE across the first half, falls
; back across the second. Deliberately not the chip's built-in triangle —
; if patch 1 sounds like patch 0's square, the slot never resolved.
; ---------------------------------------------------------------------------
    DB $00, $02, $04, $06, $08, $0A, $0C, $0E
    DB $10, $12, $14, $16, $18, $1A, $1C, $1E
    DB $20, $22, $24, $26, $28, $2A, $2C, $2E
    DB $30, $32, $34, $36, $38, $3A, $3C, $3E
    DB $40, $42, $44, $46, $48, $4A, $4C, $4E
    DB $50, $52, $54, $56, $58, $5A, $5C, $5E
    DB $60, $62, $64, $66, $68, $6A, $6C, $6E
    DB $70, $72, $74, $76, $78, $7A, $7C, $7E
    DB $80, $82, $84, $86, $88, $8A, $8C, $8E
    DB $90, $92, $94, $96, $98, $9A, $9C, $9E
    DB $A0, $A2, $A4, $A6, $A8, $AA, $AC, $AE
    DB $B0, $B2, $B4, $B6, $B8, $BA, $BC, $BE
    DB $C0, $C2, $C4, $C6, $C8, $CA, $CC, $CE
    DB $D0, $D2, $D4, $D6, $D8, $DA, $DC, $DE
    DB $E0, $E2, $E4, $E6, $E8, $EA, $EC, $EE
    DB $F0, $F2, $F4, $F6, $F8, $FA, $FC, $FE
    DB $FE, $FC, $FA, $F8, $F6, $F4, $F2, $F0
    DB $EE, $EC, $EA, $E8, $E6, $E4, $E2, $E0
    DB $DE, $DC, $DA, $D8, $D6, $D4, $D2, $D0
    DB $CE, $CC, $CA, $C8, $C6, $C4, $C2, $C0
    DB $BE, $BC, $BA, $B8, $B6, $B4, $B2, $B0
    DB $AE, $AC, $AA, $A8, $A6, $A4, $A2, $A0
    DB $9E, $9C, $9A, $98, $96, $94, $92, $90
    DB $8E, $8C, $8A, $88, $86, $84, $82, $80
    DB $7E, $7C, $7A, $78, $76, $74, $72, $70
    DB $6E, $6C, $6A, $68, $66, $64, $62, $60
    DB $5E, $5C, $5A, $58, $56, $54, $52, $50
    DB $4E, $4C, $4A, $48, $46, $44, $42, $40
    DB $3E, $3C, $3A, $38, $36, $34, $32, $30
    DB $2E, $2C, $2A, $28, $26, $24, $22, $20
    DB $1E, $1C, $1A, $18, $16, $14, $12, $10
    DB $0E, $0C, $0A, $08, $06, $04, $02, $00
