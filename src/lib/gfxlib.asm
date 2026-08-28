; ============================================================================
; gfxlib.asm — bitmap drawing for the Flommodore (Block 17, tasks 17.1-17.3).
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
;   gfx_init()                       bitmap mode, grey palette, framebuffer
;   gfx_pen(fg, bg)                  build the glyph expansion table
;   gfx_clear(colour)                fill the framebuffer
;   gfx_glyph(x, y, char)            one 8x8 character
;   gfx_text(x, y, str)              NUL-terminated, 8 px per glyph
;   gfx_plot(x, y, colour)           one pixel
;   gfx_hline(x, y, w, colour)       horizontal run
;   gfx_vline(x, y, h, colour)       vertical run
;   gfx_rect(x, y, w, h, colour)     filled
;   gfx_frame(x, y, w, h, colour)    outline only
;
; NO CLIPPING, anywhere. Callers keep x in 0..319 and y in 0..179, and a run
; that leaves the right edge wraps onto the next scanline rather than
; erroring. AURED lays out fixed panels at compile time, so clipping would
; be code that never runs; a program that computes its coordinates should
; clamp them before calling.
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
; one LB, four LW/SW pairs and its loop, which MEASURES at ~150 cycles per
; glyph — not the ~64 an earlier version of this comment claimed by counting
; the stores and forgetting the address arithmetic and the loop.
;
; At 150 cycles a glyph, a full 40x22 repaint is ~132,000 cycles, or 55% of
; a frame. That is affordable for a panel of a few hundred characters and
; NOT affordable for a full screen of text every frame; an app that wants
; the latter needs the VIC's own text mode, not this.
;
; ONE PEN, REBUILT ON DEMAND — AND NEVER PER FRAME. The Phase 9 plan called
; for 6-8 cached pens at 2 KB each. A rebuild measures ~23,500 cycles, so
; caching eight would spend 16 KB of RAM and a cache-invalidation problem to
; save something that is cheap IF it happens rarely.
;
; The trap is that 23,500 cycles is 10% of a frame, so a gfx_pen call inside
; a repaint loop costs more than everything it draws. AURED hit exactly that
; and its repaint budget check caught it. Call gfx_pen when the colours
; change, at startup or on a page switch — not once per frame, and never
; once per glyph.
;
; X MUST BE EVEN for gfx_glyph and gfx_text. A glyph row is written as four
; 16-bit stores, so an odd x would misalign every one of them. The character
; grid is 8 px anyway, so this costs nothing in practice; it is a real
; constraint on the caller, not an implementation detail. The pixel and line
; routines have no such rule — they store bytes.
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

MACRO GFX_ADDR reg, xr, yr       ; reg <- &framebuffer[yr][xr]; clobbers R12
    LI   R12, FBW
    MUL  \reg, \yr, R12
    ADD  \reg, \reg, \xr
    LOAD_ADDR R12, FB
    ADD  \reg, \reg, R12
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
; current pen. x MUST BE EVEN (see the header). Clobbers R1-R3, R12;
; R5-R7 saved.
; ----------------------------------------------------------------------------
gfx_glyph:
    PUSH R5
    PUSH R6
    PUSH R7
    PUSH R8
    PUSH R9
    GFX_ADDR R5, R1, R2          ; R5 = &framebuffer[y][x]
    ANDI R3, R3, $FF             ; R6 = &font[char]
    LI   R12, 8
    MUL  R6, R3, R12
    LOAD_ADDR R12, FONT
    ADD  R6, R6, R12
    ; Both of these are the same for all eight rows, so they are computed
    ; once. Recomputing them inside the loop cost ~12 cycles a glyph, which
    ; is invisible on one glyph and 2,000 cycles on a page.
    LOAD_ADDR R8, gfx_pentab
    LI   R9, FBW
    LI   R7, 0
gl_row:
    LB   R3, [R6]                ; this row's bit pattern…
    LI   R12, 8
    MUL  R3, R3, R12
    ADD  R3, R3, R8              ; …becomes eight ready-made pixel bytes
    LW   R12, [R3]
    SW   [R5], R12
    LW   R12, [R3 + 2]
    SW   [R5 + 2], R12
    LW   R12, [R3 + 4]
    SW   [R5 + 4], R12
    LW   R12, [R3 + 6]
    SW   [R5 + 6], R12
    ADDI R6, R6, 1
    ADD  R5, R5, R9              ; next scanline
    ADDI R7, R7, 1
    CMPI R7, 8
    BNE  gl_row
    POP  R9
    POP  R8
    POP  R7
    POP  R6
    POP  R5
    RET

; ----------------------------------------------------------------------------
; gfx_text (R1 = x, R2 = y, R3 = NUL-terminated string) — draw a run of
; glyphs, advancing 8 px each. Clobbers R1-R4, R12; R5-R7 saved.
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
; gfx_plot (R1 = x, R2 = y, R3 = colour) — one pixel. Clobbers R4, R12.
; ----------------------------------------------------------------------------
gfx_plot:
    GFX_ADDR R4, R1, R2
    SB   [R4], R3
    RET

; ----------------------------------------------------------------------------
; gfx_hline (R1 = x, R2 = y, R3 = width, R4 = colour) — a run of `width`
; pixels rightward. Byte stores, so x and width may be odd. A width of 0
; draws nothing. Clobbers R1, R3, R4, R12; R5 saved.
; ----------------------------------------------------------------------------
gfx_hline:
    PUSH R5
    MOV  R5, R4                  ; colour, before GFX_ADDR takes R4
    GFX_ADDR R4, R1, R2
hl_loop:
    CMPI R3, 0
    BEQ  hl_done
    SB   [R4], R5
    ADDI R4, R4, 1
    SUBI R3, R3, 1
    JMPA hl_loop
hl_done:
    POP  R5
    RET

; ----------------------------------------------------------------------------
; gfx_vline (R1 = x, R2 = y, R3 = height, R4 = colour) — a run of `height`
; pixels downward. Clobbers R1, R3, R4, R12; R5 saved.
; ----------------------------------------------------------------------------
gfx_vline:
    PUSH R5
    MOV  R5, R4
    GFX_ADDR R4, R1, R2
vl_loop:
    CMPI R3, 0
    BEQ  vl_done
    SB   [R4], R5
    LI   R12, FBW
    ADD  R4, R4, R12
    SUBI R3, R3, 1
    JMPA vl_loop
vl_done:
    POP  R5
    RET

; ----------------------------------------------------------------------------
; gfx_rect (R1 = x, R2 = y, R3 = w, R4 = h, R5 = colour) — filled, built
; from h horizontal runs. Clobbers R1-R4, R12; R5-R8 saved.
; ----------------------------------------------------------------------------
gfx_rect:
    PUSH LR
    PUSH R6
    PUSH R7
    PUSH R8
    MOV  R6, R1                  ; x, reloaded each row
    MOV  R7, R3                  ; width
    MOV  R8, R4                  ; rows remaining
rc_loop:
    CMPI R8, 0
    BEQ  rc_done
    MOV  R1, R6
    MOV  R3, R7
    MOV  R4, R5
    CALLA gfx_hline              ; leaves R2 and R5 alone
    ADDI R2, R2, 1
    SUBI R8, R8, 1
    JMPA rc_loop
rc_done:
    POP  R8
    POP  R7
    POP  R6
    POP  LR
    RET

; ----------------------------------------------------------------------------
; gfx_frame (R1 = x, R2 = y, R3 = w, R4 = h, R5 = colour) — the outline of
; the same rectangle gfx_rect would fill, one pixel thick, interior
; untouched. Two horizontal runs and two vertical ones; the corners get
; written twice, which is cheaper than avoiding it.
; Clobbers R1-R4, R12; R5-R9 saved.
; ----------------------------------------------------------------------------
gfx_frame:
    PUSH LR
    PUSH R6
    PUSH R7
    PUSH R8
    PUSH R9
    MOV  R6, R1                  ; x
    MOV  R7, R2                  ; y
    MOV  R8, R3                  ; w
    MOV  R9, R4                  ; h

    MOV  R4, R5                  ; top edge — R1/R2/R3 are already right
    CALLA gfx_hline

    MOV  R1, R6                  ; bottom edge
    MOV  R2, R7
    ADD  R2, R2, R9
    SUBI R2, R2, 1
    MOV  R3, R8
    MOV  R4, R5
    CALLA gfx_hline

    MOV  R1, R6                  ; left edge
    MOV  R2, R7
    MOV  R3, R9
    MOV  R4, R5
    CALLA gfx_vline

    MOV  R1, R6                  ; right edge
    ADD  R1, R1, R8
    SUBI R1, R1, 1
    MOV  R2, R7
    MOV  R3, R9
    MOV  R4, R5
    CALLA gfx_vline

    POP  R9
    POP  R8
    POP  R7
    POP  R6
    POP  LR
    RET

; ----------------------------------------------------------------------------
; Library state. bss is NOLOAD, so the 2 KB table costs nothing in the
; .flapp image — it is built at run time by gfx_pen.
; ----------------------------------------------------------------------------
    SECTION bss
gfx_pentab:    DS 2048          ; 256 font row bytes x 8 expanded pixels
