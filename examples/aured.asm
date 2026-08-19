; ============================================================================
; aured.asm — the Flommodore sound designer, skeleton (Block 17, 17.6-17.8).
;
;   flommodore --rom rom/flommodore.rom examples/aured.flapp
;
; Needs the BIOS ROM for its full font: gfxlib reads glyphs from $FE000 and
; this page shows letters and digits, which tests/roms/font.rom does not
; carry. It does NOT need the BIOS to have booted — the .flapp loader sets
; up the D12 environment, the jump table is in ROM either way, and the
; syscalls this uses (POLLKEY, and later the storage ones) touch no BIOS RAM.
;
; ----------------------------------------------------------------------------
; NO DAMAGE LIST, which revises the Phase 9 plan's task 17.5.
;
; The plan called for a damage-rectangle list so the app could repaint only
; what changed. Costed against the real page, that optimises the wrong
; thing:
;
;   full repaint of this page   ~14,000 cycles    6% of a frame
;   gfx_clear                   115,200 cycles   48% of a frame
;
; Repainting everything every frame is affordable; CLEARING is what is not.
; And because glyphs paint their own background through the expansion table,
; a repaint overwrites cleanly — so the clear is a one-time startup cost and
; the damage list would buy nothing but invalidation bugs.
;
; The measurement is not left as an argument in a comment: draw_page is
; timed with CYC and the result asserted, so a change that makes a repaint
; expensive fails the build rather than quietly dropping the frame rate.
;
; ----------------------------------------------------------------------------
; Checks, reported as R11 = (check << 8) | observed:
;
;   $01xx  repaint under 40,000 cycles   xx = measured/256, so it reports
;                                        the actual cost when it fails
;   $02xx  repaint over 2,000 cycles     something was really drawn
;   $03xx  frame top-left      $60       the panel outline exists
;   $04xx  just inside it      $00       and is an outline, not a fill
;   $05xx  frame bottom-left   $60       full height
; ============================================================================

    SECTION code

    EQU AUR1, $80100             ; voice 0 register block
    EQU VIC,  $80200

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

    ; ---- time one repaint -------------------------------------------
    MFSR R9, CYC
    CALLA draw_page
    MFSR R1, CYC
    SUB  R1, R1, R9              ; cycles the repaint took
    MOV  R10, R1                 ; keep it for both bounds

    LI   R11, $0100              ; must be affordable…
    LI   R2, 40000
    CMP  R10, R2
    BCC  ck_floor
    LI   R12, 8
    SHR  R1, R10, R12            ; report measured/256 on failure
    ANDI R1, R1, $FF
    OR   R11, R11, R1
    JMPA fail
ck_floor:
    LI   R11, $0200              ; …and must have drawn something
    LI   R2, 2000
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
    BEQ  ck_done
    OR   R11, R11, R1
    JMPA fail
ck_done:

    ; ---- the frame loop ---------------------------------------------
    ; Four frames of the real thing: wait for the vertical blank, repaint
    ; the page, repeat. No clear, no damage tracking.
    LI   R6, 4
frame_loop:
    CALLA wait_vblank
    CALLA draw_page
    SUBI R6, R6, 1
    BNE  frame_loop

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
; draw_page — the whole visible page, every time. Title, panel outline, and
; voice 0's sixteen registers in two columns of eight, each as NAME $XX read
; live off the chip. Clobbers R1-R5, R12; R6-R8 saved.
; ----------------------------------------------------------------------------
draw_page:
    PUSH LR
    PUSH R6
    PUSH R7
    PUSH R8

    LI   R1, PEN_FG
    LI   R2, PEN_BG
    CALLA gfx_pen
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

    POP  R8
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

    SECTION bss

val_buf:
    DS 4                         ; '$', two digits, NUL
