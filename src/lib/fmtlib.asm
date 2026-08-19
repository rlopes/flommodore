; ============================================================================
; fmtlib.asm — number to text for the Flommodore (Block 17, task 17.4).
;
; A relocatable library. Deliberately separate from gfxlib: these routines
; produce STRINGS and touch no pixels, so they are testable without a font,
; a framebuffer or a palette — a formatter bug shows up as wrong characters
; in a buffer rather than as wrong-looking dots on a screen.
;
; Arguments in R1-R3, result in R1, per decision be. Every routine writes a
; NUL-terminated string into the caller's buffer and returns the number of
; characters written, not counting the terminator.
;
;   fmt_hex8(buf, value)     two hex digits, always      -> R1 = 2
;   fmt_hex16(buf, value)    four hex digits, always     -> R1 = 4
;   fmt_dec(buf, value)      1-5 digits, no leading zeros -> R1 = count
;
; Hex is fixed-width because register values line up in columns and a
; two-digit field that sometimes prints one digit is worse than useless in a
; register editor. Decimal suppresses leading zeros because milliseconds and
; hertz read as quantities, not as fields.
;
; ----------------------------------------------------------------------------
; WHY DIV AND MOD, AND WHY THAT IS NEW HERE.
;
; Every earlier assembly file in this project used only the 38 mnemonics
; bios.asm happens to use, which turns out to be a subset: codegen.zig
; derives the accepted set from encode.Opcode by reflection, so SUB, DIV,
; MOD, NOT, ORI, XORI, ASR and the signed branches have been available all
; along. fmt_dec uses DIV and MOD against a powers-of-ten table rather than
; the repeated subtraction it would otherwise have needed.
;
; The filter's cutoff-to-hertz curve is NOT here, and cannot be. §4.5 gives
; fc = 30 + (c/4095)^2 * 11970, and c^2 for c = 4095 is 16,769,025 — which
; needs 24 bits and does not fit a 20-bit register at any point in the
; expression. A 12-bit cutoff cannot be converted to hertz by arithmetic on
; this machine; it needs a generated lookup, the way the note table is
; generated. Recorded here because this is where someone will come looking
; for it.
; ============================================================================

    SECTION code

MACRO LOAD_ADDR reg, addr
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO

; ----------------------------------------------------------------------------
; fmt_nib (R1 = value, low nibble) -> R1 = the ASCII digit. Internal.
; ----------------------------------------------------------------------------
fmt_nib:
    ANDI R1, R1, $0F
    CMPI R1, 10
    BCC  nib_digit
    ADDI R1, R1, 55              ; 10 -> 'A'
    RET
nib_digit:
    ADDI R1, R1, $30             ; 0 -> '0'
    RET

; ----------------------------------------------------------------------------
; fmt_hex8 (R1 = buffer, R2 = value) — two hex digits and a NUL.
; R1 <- 2. Clobbers R1-R3, R12; R5, R6 saved.
; ----------------------------------------------------------------------------
fmt_hex8:
    PUSH LR
    PUSH R5
    PUSH R6
    MOV  R5, R1
    MOV  R6, R2
    LI   R12, 4
    SHR  R1, R6, R12
    CALLA fmt_nib
    SB   [R5], R1
    MOV  R1, R6
    CALLA fmt_nib
    SB   [R5 + 1], R1
    SB   [R5 + 2], R0            ; NUL
    LI   R1, 2
    POP  R6
    POP  R5
    POP  LR
    RET

; ----------------------------------------------------------------------------
; fmt_hex16 (R1 = buffer, R2 = value) — four hex digits and a NUL.
; R1 <- 4. Clobbers R1-R3, R12; R5-R7 saved.
;
; The shift walks 12, 8, 4, 0 — all inside the four-bit shift field, so this
; needs none of the 8+8 care that splitting a 20-bit pointer does.
; ----------------------------------------------------------------------------
fmt_hex16:
    PUSH LR
    PUSH R5
    PUSH R6
    PUSH R7
    MOV  R5, R1
    MOV  R6, R2
    LI   R7, 12
fh_loop:
    MOV  R1, R6
    SHR  R1, R1, R7
    CALLA fmt_nib
    SB   [R5], R1
    ADDI R5, R5, 1
    CMPI R7, 0
    BEQ  fh_done
    SUBI R7, R7, 4
    JMPA fh_loop
fh_done:
    SB   [R5], R0
    LI   R1, 4
    POP  R7
    POP  R6
    POP  R5
    POP  LR
    RET

; ----------------------------------------------------------------------------
; fmt_dec (R1 = buffer, R2 = value 0-65535) — decimal, no leading zeros, and
; a NUL. R1 <- the number of digits. Clobbers R1-R3, R12; R5-R9 saved.
;
; Zero prints as "0", not as nothing: the lone-zero case is why the
; suppression test looks at the NEXT power rather than just at a flag.
; ----------------------------------------------------------------------------
fmt_dec:
    PUSH R5
    PUSH R6
    PUSH R7
    PUSH R8
    PUSH R9
    MOV  R5, R1                  ; buffer cursor
    ANDI R6, R2, $FFFF           ; the value being consumed
    LOAD_ADDR R7, fmt_pow10
    LI   R8, 0                   ; have we emitted a digit yet?
    LI   R9, 0                   ; digits written
fd_loop:
    LW   R3, [R7]                ; this power of ten; 0 ends the table
    CMPI R3, 0
    BEQ  fd_end
    DIV  R1, R6, R3              ; the digit
    MOD  R6, R6, R3              ; what is left for the next power
    CMPI R1, 0
    BNE  fd_emit                 ; a nonzero digit always prints
    CMPI R8, 0
    BNE  fd_emit                 ; and so does a zero after the first digit
    LW   R12, [R7 + 2]
    CMPI R12, 0
    BNE  fd_next                 ; leading zero, and more powers to come
fd_emit:
    ADDI R1, R1, $30
    SB   [R5], R1
    ADDI R5, R5, 1
    ADDI R9, R9, 1
    LI   R8, 1
fd_next:
    ADDI R7, R7, 2
    JMPA fd_loop
fd_end:
    SB   [R5], R0
    MOV  R1, R9
    POP  R9
    POP  R8
    POP  R7
    POP  R6
    POP  R5
    RET

    SECTION data

; Powers of ten, largest first, zero-terminated. 65535 is five digits, so
; five entries is the whole range of a 16-bit value.
fmt_pow10:
    DW 10000
    DW 1000
    DW 100
    DW 10
    DW 1
    DW 0
