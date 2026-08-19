; ============================================================================
; gfxdemo.asm — drive gfxlib and fmtlib, and check the results
; (Block 17, tasks 17.1-17.4).
;
;   flommodore --rom tests/roms/font.rom examples/gfxdemo.flapp
;
; Runs with the minimal font ROM rather than the BIOS: gfxlib needs glyph
; data at $FE000 and nothing else, so this is the §8.10 combined form —
; a ROM for the font, a .flapp for the program, no firmware in between.
; "FLOMMODORE" uses only glyphs font.rom actually carries.
;
; ASSERTS RESULTS, not a hash. A frame golden catches a change but does not
; say what changed, and it only means anything once the engine is known
; good. The drawing checks read framebuffer bytes back and compare against
; values derived from the font data and the geometry; the formatter checks
; read the ASCII the formatters produced, which needs no font at all — which
; is just as well, since font.rom has no digit glyphs.
;
; Failures report R11 = (check << 8) | observed, so a wrong byte names
; itself.
;
;   $01xx  'F' row 0 pixel 0        $FF   the glyph reached the framebuffer
;   $02xx  'F' row 0 pixel 6        $00   the expansion table's zero bits
;   $03xx  'F' row 1 pixel 0        $FF   the row stride is 320
;   $04xx  'F' row 3 pixel 0        $FF   ...and holds four rows on
;   $05xx  second pen, pixel 0      $40   gfx_pen rebuilt, not left stale
;   $06xx  second pen, pixel 6      $80
;   $07xx  rect top-left            $20   gfx_rect filled
;   $08xx  rect bottom-right        $20   ...to its full extent
;   $09xx  one row BELOW the rect   $00   ...and no further
;   $0Axx  one col RIGHT of it      $00   ...nor wider
;   $0Bxx  frame top-left           $30   gfx_frame drew its outline
;   $0Cxx  frame bottom-right       $30   ...on all four sides
;   $0Dxx  frame interior           $00   ...and left the middle alone
;   $0Exx  fmt_hex16 count          4     fixed width
;   $0Fxx  fmt_hex16 "01EA"[0]      '0'   hex KEEPS its leading zero
;   $10xx  fmt_hex16 "01EA"[2]      'E'   the letter path
;   $11xx  fmt_hex16 "01EA"[4]      $00   NUL-terminated
;   $12xx  fmt_hex8 "2F"[1]         'F'
;   $13xx  fmt_dec(0) count         1     a lone zero still prints
;   $14xx  fmt_dec(0)[0]            '0'
;   $15xx  fmt_dec(65535) count     5     full width
;   $16xx  fmt_dec(65535)[4]        '5'
;   $17xx  fmt_dec(10000)[1]        '0'   interior zeros survive
;
; $0Fxx and $13xx are the pair worth having: hex keeps a leading zero and
; decimal drops one, so a single suppression rule applied to both would
; fail exactly one of them.
; ============================================================================

    SECTION code

MACRO LOAD_ADDR reg, addr
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO

start:
    LI   R1, $1100
    MOV  SP, R1                  ; D12 boot stack; the libraries push

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

    ; ---- the primitives ---------------------------------------------
    ; A filled 8x4 block, and an outlined 10x6 one beside it. The sizes
    ; are small and odd-ish on purpose: a rect that happened to round to
    ; whole words would hide an off-by-one in the width.
    LI   R1, 100
    LI   R2, 100
    LI   R3, 8
    LI   R4, 4
    LI   R5, $20
    CALLA gfx_rect

    LI   R1, 150
    LI   R2, 100
    LI   R3, 10
    LI   R4, 6
    LI   R5, $30
    CALLA gfx_frame

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
    BEQ  ck_rect
    OR   R11, R11, R1
    JMPA fail

    ; gfx_rect(100, 100, 8, 4, $20): the two far corners must be filled
    ; and the two cells just outside must not be. Those bracket both the
    ; width and the height — a rect one too wide or one too tall shows up
    ; in $0Axx or $09xx rather than passing quietly.
ck_rect:
    LOAD_ADDR R4, $4BD64         ; (100, 100)
    LI   R11, $0700
    LB   R1, [R4]
    CMPI R1, $20
    BEQ  ck_rect_far
    OR   R11, R11, R1
    JMPA fail
ck_rect_far:
    LOAD_ADDR R4, $4C12B         ; (107, 103) — last pixel of the fill
    LI   R11, $0800
    LB   R1, [R4]
    CMPI R1, $20
    BEQ  ck_rect_below
    OR   R11, R11, R1
    JMPA fail
ck_rect_below:
    LOAD_ADDR R4, $4C264         ; (100, 104) — one row too far
    LI   R11, $0900
    LB   R1, [R4]
    CMPI R1, $00
    BEQ  ck_rect_right
    OR   R11, R11, R1
    JMPA fail
ck_rect_right:
    LOAD_ADDR R4, $4BD6C         ; (108, 100) — one column too far
    LI   R11, $0A00
    LB   R1, [R4]
    CMPI R1, $00
    BEQ  ck_frame
    OR   R11, R11, R1
    JMPA fail

    ; gfx_frame(150, 100, 10, 6, $30): opposite corners drawn, interior
    ; clear. The interior check is the one that distinguishes a frame from
    ; a fill.
ck_frame:
    LOAD_ADDR R4, $4BD96         ; (150, 100)
    LI   R11, $0B00
    LB   R1, [R4]
    CMPI R1, $30
    BEQ  ck_frame_far
    OR   R11, R11, R1
    JMPA fail
ck_frame_far:
    LOAD_ADDR R4, $4C3DF         ; (159, 105)
    LI   R11, $0C00
    LB   R1, [R4]
    CMPI R1, $30
    BEQ  ck_frame_in
    OR   R11, R11, R1
    JMPA fail
ck_frame_in:
    LOAD_ADDR R4, $4BED7         ; (151, 101) — inside the outline
    LI   R11, $0D00
    LB   R1, [R4]
    CMPI R1, $00
    BEQ  ck_hex16
    OR   R11, R11, R1
    JMPA fail

    ; ---- the formatters, checked as text not pixels -----------------
    ; $01EA is E4's phase increment, which is why it is the value here:
    ; it has a leading zero, a letter, and a digit above 9.
ck_hex16:
    LOAD_ADDR R1, fmt_buf
    LI   R2, $01EA
    CALLA fmt_hex16
    LI   R11, $0E00
    CMPI R1, 4
    BEQ  ck_hex16_0
    OR   R11, R11, R1
    JMPA fail
ck_hex16_0:
    LOAD_ADDR R4, fmt_buf
    LI   R11, $0F00
    LB   R1, [R4]
    CMPI R1, $30                 ; '0' — hex keeps its leading zero
    BEQ  ck_hex16_2
    OR   R11, R11, R1
    JMPA fail
ck_hex16_2:
    LI   R11, $1000
    LB   R1, [R4 + 2]
    CMPI R1, $45                 ; 'E'
    BEQ  ck_hex16_nul
    OR   R11, R11, R1
    JMPA fail
ck_hex16_nul:
    LI   R11, $1100
    LB   R1, [R4 + 4]
    CMPI R1, $00
    BEQ  ck_hex8
    OR   R11, R11, R1
    JMPA fail

ck_hex8:
    LOAD_ADDR R1, fmt_buf
    LI   R2, $2F
    CALLA fmt_hex8
    LOAD_ADDR R4, fmt_buf
    LI   R11, $1200
    LB   R1, [R4 + 1]
    CMPI R1, $46                 ; 'F'
    BEQ  ck_dec0
    OR   R11, R11, R1
    JMPA fail

    ; Zero must print as "0", not as nothing. This is the case the
    ; suppression rule gets wrong if it only looks at a flag.
ck_dec0:
    LOAD_ADDR R1, fmt_buf
    LI   R2, 0
    CALLA fmt_dec
    LI   R11, $1300
    CMPI R1, 1
    BEQ  ck_dec0_0
    OR   R11, R11, R1
    JMPA fail
ck_dec0_0:
    LOAD_ADDR R4, fmt_buf
    LI   R11, $1400
    LB   R1, [R4]
    CMPI R1, $30                 ; '0'
    BEQ  ck_dec_max
    OR   R11, R11, R1
    JMPA fail

ck_dec_max:
    LOAD_ADDR R1, fmt_buf
    LI   R2, 65535
    CALLA fmt_dec
    LI   R11, $1500
    CMPI R1, 5
    BEQ  ck_dec_max_last
    OR   R11, R11, R1
    JMPA fail
ck_dec_max_last:
    LOAD_ADDR R4, fmt_buf
    LI   R11, $1600
    LB   R1, [R4 + 4]
    CMPI R1, $35                 ; '5'
    BEQ  ck_dec_interior
    OR   R11, R11, R1
    JMPA fail

    ; 10000: the leading digit is 1 and the rest are zeros, so this
    ; separates "suppress leading zeros" from "suppress all zeros".
ck_dec_interior:
    LOAD_ADDR R1, fmt_buf
    LI   R2, 10000
    CALLA fmt_dec
    LOAD_ADDR R4, fmt_buf
    LI   R11, $1700
    LB   R1, [R4 + 1]
    CMPI R1, $30                 ; '0'
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

    SECTION bss

fmt_buf:
    DS 8                         ; five digits, four hex, and a NUL to spare
