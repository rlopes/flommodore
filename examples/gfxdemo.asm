; ============================================================================
; gfxdemo.asm — drive gfxlib and check the pixels (Block 17, 17.1-17.2).
;
;   flommodore --rom tests/roms/font.rom examples/gfxdemo.flapp
;
; Runs with the minimal font ROM rather than the BIOS: gfxlib needs glyph
; data at $FE000 and nothing else, so this is the §8.10 combined form —
; a ROM for the font, a .flapp for the program, no firmware in between.
; "FLOMMODORE" uses only glyphs font.rom actually carries.
;
; ASSERTS PIXELS, not just a hash. A frame golden would catch a change but
; would not tell anyone what changed, and pinning one before the engine is
; known-good just enshrines whatever it happens to draw. So the demo reads
; framebuffer bytes back and compares them against values derived from the
; font data: 'F' row 0 is $FC, so with pen fg/bg the first six pixels are
; foreground and the last two background, at addresses fixed by
; $44000 + y*320 + x.
;
; Failures report R11 = (check << 8) | observed, as in sndbank_demo, so a
; wrong byte names itself.
;
;   $01xx  'F' row 0 pixel 0     $FF   the glyph reached the framebuffer
;   $02xx  'F' row 0 pixel 6     $00   the expansion table's zero bits
;   $03xx  'F' row 1 pixel 0     $FF   the row stride is 320
;   $04xx  'F' row 3 pixel 0     $FF   ...and holds for four more rows
;   $05xx  second pen, pixel 0   $40   gfx_pen rebuilt, not cached stale
;   $06xx  second pen, pixel 6   $80
; ============================================================================

    SECTION code

MACRO LOAD_ADDR reg, addr
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO

start:
    LI   R1, $1100
    MOV  SP, R1                  ; D12 boot stack; gfxlib pushes

    CALLA gfx_init               ; bitmap 320x180 8bpp, grey palette

    LI   R1, 0
    CALLA gfx_clear              ; a known black field to draw onto

    ; ---- first pen: white on black ----------------------------------
    LI   R1, $FF
    LI   R2, $00
    CALLA gfx_pen

    LI   R1, 8                   ; x, even as gfx_glyph requires
    LI   R2, 16
    LOAD_ADDR R3, str_title
    CALLA gfx_text

    ; ---- second pen, to prove the table is rebuilt ------------------
    LI   R1, $40
    LI   R2, $80
    CALLA gfx_pen

    LI   R1, 8
    LI   R2, 48
    LOAD_ADDR R3, str_title
    CALLA gfx_text

    ; ---- read the pixels back ---------------------------------------
    ; 'F' row 0 = $FC: pixels 0-5 foreground, 6-7 background.
    LOAD_ADDR R4, $45408         ; $44000 + 16*320 + 8
    LI   R11, $0100
    LB   R1, [R4]
    CMPI R1, $FF
    BEQ  ck_bg
    OR   R11, R11, R1
    JMPA fail
ck_bg:
    LI   R11, $0200
    LB   R1, [R4 + 6]
    CMPI R1, $00
    BEQ  ck_row1
    OR   R11, R11, R1
    JMPA fail

    ; row 1 = $80: only pixel 0 is set. Its address is one scanline on,
    ; so this is really a check that the stride is 320.
ck_row1:
    LOAD_ADDR R4, $45548         ; $44000 + 17*320 + 8
    LI   R11, $0300
    LB   R1, [R4]
    CMPI R1, $FF
    BEQ  ck_row3
    OR   R11, R11, R1
    JMPA fail
ck_row3:
    LOAD_ADDR R4, $457C8         ; $44000 + 19*320 + 8, row 3 = $F8
    LI   R11, $0400
    LB   R1, [R4]
    CMPI R1, $FF
    BEQ  ck_pen2
    OR   R11, R11, R1
    JMPA fail

    ; The second pen's glyphs must use $40/$80, not the first pen's
    ; colours — a cached table would show $FF here.
ck_pen2:
    LOAD_ADDR R4, $47C08         ; $44000 + 48*320 + 8
    LI   R11, $0500
    LB   R1, [R4]
    CMPI R1, $40
    BEQ  ck_pen2bg
    OR   R11, R11, R1
    JMPA fail
ck_pen2bg:
    LI   R11, $0600
    LB   R1, [R4 + 6]
    CMPI R1, $80
    BEQ  ck_done
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

    SECTION data

str_title:
    DB "FLOMMODORE", 0
