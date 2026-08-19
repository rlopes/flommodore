; ============================================================================
; gfxlib.asm — bitmap drawing for the Flommodore (Block 17, tasks 17.1-17.2).
;
; 320x180 at 8bpp, one byte per pixel, framebuffer at $44000. A relocatable
; library like sndlib: assemble with flas, link into any .flapp.
;
; ARGUMENTS IN R1-R5, results in R1. This deliberately widens decision be's
; R1-R3, which is a syscall convention: a rectangle needs five numbers and
; packing two of them into one register to honour a rule written for a
; different purpose would be worse than saying so here. R6-R11, R13, LR and
; SP are preserved as usual.
;
;   gfx_init()                   bitmap mode, grey palette, framebuffer live
;   gfx_pen(fg, bg)              build the glyph expansion table
;   gfx_clear(colour)            fill the framebuffer
;   gfx_glyph(x, y, char)        one 8x8 character
;   gfx_text(x, y, str)          NUL-terminated, advancing 8 px per glyph
;
; ----------------------------------------------------------------------------
; THE EXPANSION TABLE, which is the whole reason this is fast enough.
;
; The ROM font is 1bpp: eight bytes per glyph, bit 7 leftmost. The screen is
; 8bpp. Expanding a bit to a byte one pixel at a time costs ~192
; instructions per glyph, and a full 40x22 repaint would then be 70% of a
; frame — before drawing anything else.
;
; So each pen (a foreground/background pair) gets a 256x8 lookup: entry b is
; the eight ready-made pixel bytes for font row byte b. A glyph row becomes
; one LB and four SW, a glyph is ~64 instructions, and a full repaint is 23%
; of a frame.
;
; ONE PEN, REBUILT ON DEMAND. The Phase 9 plan called for 6-8 cached pens at
; 2 KB each. Measured, a rebuild is ~16k instructions — under 7% of a frame —
; so caching eight would spend 16 KB of RAM and a cache-invalidation problem
; to save something already cheap. AURED changes pen a handful of times per
; repaint, not per glyph.
;
; X MUST BE EVEN. A glyph row is written as four 16-bit stores, so an odd x
; would misalign every one of them. The character grid is 8 px anyway, so
; this costs nothing in practice; it is a real constraint on gfx_glyph's
; caller, not an implementation detail.
;
; NEVER SHIFT BY 16 — a shift count masks to four bits, so SHL/SHR 16 is a
; shift by zero (see the same note in sndlib.asm and bios.asm). Nothing here
; splits a pointer, but the framebuffer at $44000 and the font at $FE000 are
; both above $0FFFF, so their addresses come from LOAD_ADDR and are only
; ever added to.
; ============================================================================

    SECTION code

    EQU VIC,     $80200
    EQU FB,      $44000          ; framebuffer, 320*180 = 57,600 bytes
    EQU FBW,     320
    EQU FBH,     180
    EQU FONT,    $FE000          ; ROM font, 8 bytes per glyph (§6.5)
    EQU PALRAM,  $02100          ; palette RAM, 256 x RGB

    EQU GFX_COLS, 40             ; 320 / 8
    EQU GFX_ROWS, 22             ; 180 / 8, with 4 spare scanlines

MACRO LOAD_ADDR reg, addr
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO

; ----------------------------------------------------------------------------
; gfx_init — 320x180 8bpp bitmap, framebuffer at $44000, a grey-ramp palette
; so colour index N is simply brightness N. Geometry first and mode last,
; the bring-up order the BIOS uses (decision bo). Clobbers R1-R4, R12.
;
; The palette is written here rather than assumed so the library works in a
; bare .flapp with no BIOS. A caller that wants its own colours can call
; gfx_palette afterwards, or just overwrite PALRAM.
; ----------------------------------------------------------------------------
gfx_init:
    PUSH LR
    CALLA gfx_palette
    LOAD_ADDR R4, VIC
    SB   [R4 + $02], R0          ; VRESX = 0 -> 320
    SB   [R4 + $03], R0          ; VRESY = 0 -> 180
    LI   R12, 3
    SB   [R4 + $01], R12         ; VPALETTE = 8bpp
    SB   [R4 + $06], R0          ; VBUFLO — $44000 / 16 = $4400
    LI   R12, $44
    SB   [R4 + $07], R12         ; VBUFHI
    LI   R12, (PALRAM / 16) & $FF
    SB   [R4 + $0B], R12         ; VPALBASE
    LI   R12, (PALRAM / 16) >> 8
    SB   [R4 + $0C], R12
    SB   [R4 + $00], R0          ; VMODE = 0 bitmap — last
    POP  LR
    RET

; ----------------------------------------------------------------------------
; gfx_palette — 256 grey entries, index N = (N, N, N). Clobbers R1, R2.
; ----------------------------------------------------------------------------
gfx_palette:
    LOAD_ADDR R1, PALRAM
    LI   R2, 0
pal_loop:
    SB   [R1], R2
    SB   [R1 + 1], R2
    SB   [R1 + 2], R2
    ADDI R1, R1, 3
    ADDI R2, R2, 1
    CMPI R2, 256
    BNE  pal_loop
    RET

; ----------------------------------------------------------------------------
; gfx_pen (R1 = foreground index, R2 = background index) — build the glyph
; expansion table for this pair. Entry b holds the eight pixel bytes that
; font row byte b expands to, bit 7 first. Clobbers R1-R3, R12; R5, R6 saved.
; ----------------------------------------------------------------------------
gfx_pen:
    PUSH R5
    PUSH R6
    ANDI R1, R1, $FF
    ANDI R2, R2, $FF
    LOAD_ADDR R5, gfx_pentab
    LI   R6, 0                   ; the font row byte being expanded
pen_byte:
    LI   R3, 0                   ; bit index, 0 = leftmost
pen_bit:
    LI   R12, $80
    SHR  R12, R12, R3            ; mask for this bit
    AND  R12, R6, R12
    CMPI R12, 0
    BEQ  pen_bg
    SB   [R5], R1
    JMPA pen_advance
pen_bg:
    SB   [R5], R2
pen_advance:
    ADDI R5, R5, 1
    ADDI R3, R3, 1
    CMPI R3, 8
    BNE  pen_bit
    ADDI R6, R6, 1
    CMPI R6, 256
    BNE  pen_byte
    POP  R6
    POP  R5
    RET

; ----------------------------------------------------------------------------
; gfx_clear (R1 = colour index) — fill all 57,600 bytes. Written as words,
; so ~28,800 stores: about half a frame, which is why AURED clears once at
; startup and repaints by damage rather than clearing every frame.
; Clobbers R1-R3, R12.
; ----------------------------------------------------------------------------
gfx_clear:
    ANDI R1, R1, $FF
    LI   R12, 8
    SHL  R2, R1, R12
    OR   R1, R1, R2              ; the colour in both halves of a word
    LOAD_ADDR R2, FB
    LI   R3, ((FBW * FBH) / 2)
clr_loop:
    SW   [R2], R1
    ADDI R2, R2, 2
    SUBI R3, R3, 1
    BNE  clr_loop
    RET

; ----------------------------------------------------------------------------
; gfx_glyph (R1 = x, R2 = y, R3 = character) — blit one 8x8 glyph in the
; current pen. x MUST BE EVEN (see the header). No clipping: the caller
; keeps x in 0..312 and y in 0..172. Clobbers R1-R3, R12; R5-R7 saved.
; ----------------------------------------------------------------------------
gfx_glyph:
    PUSH R5
    PUSH R6
    PUSH R7
    LI   R12, FBW                ; R5 = &framebuffer[y][x]
    MUL  R5, R2, R12
    ADD  R5, R5, R1
    LOAD_ADDR R12, FB
    ADD  R5, R5, R12
    ANDI R3, R3, $FF             ; R6 = &font[char]
    LI   R12, 8
    MUL  R6, R3, R12
    LOAD_ADDR R12, FONT
    ADD  R6, R6, R12
    LI   R7, 0
gl_row:
    LB   R3, [R6]                ; this row's bit pattern…
    LI   R12, 8
    MUL  R3, R3, R12
    LOAD_ADDR R12, gfx_pentab
    ADD  R3, R3, R12             ; …becomes eight ready-made pixel bytes
    LW   R12, [R3]
    SW   [R5], R12
    LW   R12, [R3 + 2]
    SW   [R5 + 2], R12
    LW   R12, [R3 + 4]
    SW   [R5 + 4], R12
    LW   R12, [R3 + 6]
    SW   [R5 + 6], R12
    ADDI R6, R6, 1
    LI   R12, FBW
    ADD  R5, R5, R12             ; next scanline
    ADDI R7, R7, 1
    CMPI R7, 8
    BNE  gl_row
    POP  R7
    POP  R6
    POP  R5
    RET

; ----------------------------------------------------------------------------
; gfx_text (R1 = x, R2 = y, R3 = NUL-terminated string) — draw a run of
; glyphs, advancing 8 px each. Does not wrap: a caller that runs off the
; right edge will scribble into the next scanline, which is the caller's
; problem in the same way gfx_glyph's evenness is. Clobbers R1-R4, R12;
; R5-R7 saved.
; ----------------------------------------------------------------------------
gfx_text:
    PUSH LR
    PUSH R5
    PUSH R6
    PUSH R7
    MOV  R5, R1                  ; x cursor
    MOV  R6, R2                  ; y, fixed
    MOV  R7, R3                  ; string
tx_loop:
    LB   R3, [R7]
    CMPI R3, 0
    BEQ  tx_done
    MOV  R1, R5
    MOV  R2, R6
    CALLA gfx_glyph              ; preserves R5-R7
    ADDI R5, R5, 8
    ADDI R7, R7, 1
    JMPA tx_loop
tx_done:
    POP  R7
    POP  R6
    POP  R5
    POP  LR
    RET

; ----------------------------------------------------------------------------
; Library state. bss is NOLOAD, so the 2 KB table costs nothing in the
; .flapp image — it is built at run time by gfx_pen.
; ----------------------------------------------------------------------------
    SECTION bss
gfx_pentab:    DS 2048          ; 256 font row bytes x 8 expanded pixels
