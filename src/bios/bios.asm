; ============================================================================
; bios.asm — the Flommodore BIOS ROM (Block 12).
;
; Assembled in absolute mode (ORG) by flas and emitted as the 16KB ROM image
; by `fll --raw --base $FC000 --size 16K` (task 12.16) — the toolchain builds
; the machine's own firmware.
;
; ROM layout (Phase 6 §6.2):
;   $FC000  ROM header (32 B)                    §6.3
;   $FC100  System call jump table (64 × JMPA)   §6.4
;   $FC200  BIOS kernel code (to $FDFFF)
;   $FE000  Font (INCLUDE "font.inc")            §6.5
;   $FF800  Default palette (INCLUDE "palette.inc") §6.6
;   $FFFC0  System vectors (16 × DD)             §6.7
;
; Register conventions (decision be): system calls take arguments in R1–R3,
; return results in R1 (R2 for SYS_GETID's second value), and may clobber
; R1–R4 and R12. R5–R11, R13 (FP), R14 (LR — via CALLA), and R15 (SP) are
; preserved. Interrupt handlers preserve everything.
;
; Console geometry (decision bd): the BIOS text console is 80×43 cells.
; 640×360 text mode scans 45 rows, but the full 80×45 matrix (7200 B) from
; the G17 base $02600 would end at $0421F — 288 bytes past the Kernel
; Workspace into the $04100 program area, so SYS_CLRSCR/SYS_SCROLL would
; corrupt a loaded program. The BIOS matrix is $02600–$040DF (80×43×2 =
; 6880 B) and the BIOS never writes rows 43–44. (Amendment candidate.)
;
; ROM header checksum (decision bh): the CRC-32 field holds $00000000 in
; v1 — "not populated". Nothing verifies it, and the assembler cannot hash
; its own output; a nonzero value would be a lie.
;
; Console semantics (decision bl — the spec names the calls but not the
; edge behaviour): SYS_PUTCHAR renders every byte as its font glyph except
; $0A (LF: column 0, row advance), $0D (CR: column 0), and $08 (BS:
; non-destructive column−1, stopping at column 0). Column 80 wraps like LF;
; a row advance past row 42 scrolls one line and holds the cursor on row
; 42. Cells freed by CLRSCR or scrolling become $20 (space) with the
; current CUR_ATTR. SYS_SETCURSOR clamps out-of-range values to the last
; column/row; SYS_SETCOLOR masks both indices to 4 bits; SYS_SCROLL clamps
; R1 to 43 — anything more is already a fully cleared screen.
;
; Keyboard semantics (decision bn — the spec pins echo/terminator/R1 for
; GETLINE and shift-via-KMOD for GETCHAR; the rest is defined here):
; blocking calls busy-poll KSTAT bit 0 — polling works whether or not the
; caller has keyboard IRQs unmasked, where an HLT-wait would deadlock one
; that masked them. SYS_GETKEY consumes and discards release events and
; returns the press event word (bit 15 clear ⇒ equal to the HID code).
; SYS_POLLKEY returns raw event words, presses and releases alike. The
; HID-to-ASCII table lives in kernel ROM as two 128-byte maps (unshifted,
; shifted) indexed by HID code; unmapped codes read 0. SYS_GETCHAR swallows
; unmapped presses and applies shift only — caps lock is not applied in v1.
; SYS_GETLINE treats R2 as the maximum character count (the buffer must
; hold R2+1 bytes for the NUL), edits with destructive backspace (BS ' '
; BS on screen), swallows input beyond R2, and handles Enter (HID $28) and
; Backspace (HID $2A) by scancode before ASCII mapping.
;
; Video syscall semantics (decision bo): SYS_SETPAL cannot take "R2=RGB24"
; literally — registers are 20-bit (§1.1) — so R2 carries (G<<8)|B and R3
; carries R. (Amendment candidate.) SYS_SETMODE writes geometry first
; (VRESX=VRESY=R2, VPALETTE=R3), mode last, and mirrors the mode into
; VMODE_CUR. SYS_VBLANK waits for a 0→1 edge of VSTAT bit 0 — if called
; during VBLANK it waits for the NEXT one. SYS_FILLSCR fills the current
; framebuffer (VBUF×16, size from live VRESX/VRESY/VPALETTE) with the fill
; byte formed from the colour index per depth: 8bpp the index, 4bpp the
; low nibble replicated, 1bpp $FF/$00 for nonzero/zero; the reserved
; VPALETTE value 2 fills as 8bpp (the §3.8 fallback depth). In text mode
; there is no framebuffer: FILLSCR returns R1=$FFFF and touches nothing.
;
; Sound syscall semantics (decision bp): SYS_SNDINIT is the single silent-
; default routine — boot's dev_init calls it — and leaves AMVOLL/AMVOLR at
; $0F so SYS_SNDVOL alone unmutes. SYS_SNDPLAY gives voice R1 audible
; defaults: freq R2, waveform R3 (bits 2:0), full pre-mixer volume ($FF),
; centre pan ($0F/$0F), snappy ADSR ($00/$F4 — instant attack, sustain 15,
; 114 ms release), routes the voice in AMVOICE, then gates on (VCTRL bit
; 7) — one call, one note. SYS_SNDSTOP clears the gate (release phase) and
; keeps the routing. SYS_SNDVOL writes AMVOL only.
;
; System syscall semantics (decision bq): SYS_GETID returns the SYSID
; register in R1 and the ROM HEADER version word ($FC002) in R2 — GETID
; reports the firmware image; the SYSVER register reports the machine.
; SYS_TSET clears a stale expired flag before writing CTRL last (so the
; 0→1 enable loads the counter); SYS_TWAIT on an armed timer consumes the
; expiry it waited for, and its poll loop treats a one-shot that disarmed
; itself as having fired (v1.1 §3.2) — no lost-expiry hang. SYS_TWAIT
; returns R1=0 on expiry, $FFFF on a disabled timer (amendment G18).
; SYS_RESET is JMPA boot: the full §6.8 sequence runs again.
;
; IRQ dispatch contract (decision br): the BIOS dispatcher saves R1–R4,
; R12 and LR, walks IRQSTAT∧IRQMASK bit 0→7, ACKNOWLEDGES each pending
; source BEFORE its handler runs (an edge during the handler re-pends
; rather than vanishing), CALLs the installed DISPATCH-table entry (zero =
; none: the ack alone quiets the line), and executes the RTI itself
; (amendment G18). Handlers may therefore clobber R1–R4 and R12 freely,
; must preserve anything else they touch, must end with RET, and have a
; handful of supervisor stack slots ($020B0–$020F0 minus the frame and the
; dispatcher's own eight). SYS_IRQSET only manages the table — IRQMASK
; stays software-controlled (boot's stage 6 unmasks timer A, keyboard, and
; VBLANK; anything else is the program's own write).
;
; Shell & autoboot conventions (decision bs — §6.10 lists the commands,
; not their grammar): commands match case-insensitively as whole tokens;
; numeric arguments are hexadecimal with an optional '$' prefix (the
; machine's own notation); a missing argument is a syntax error. RUN and
; autoboot transfer control with CALL, so a program that ends in RET drops
; back to the READY prompt (HLT works as published too — §8.3). MEM dumps
; 16×16 bytes with live bus reads — peeking KDATA dequeues, as on the
; machines this imitates. LOAD prints its reserved-for-storage
; diagnostic. Autoboot validates magic, entry offset ≥ 12, and min-RAM ≤
; 512; a present-but-invalid header earns the diagnostic, a silent
; absence goes straight to the shell (§6.9).
; ============================================================================

; ----------------------------------------------------------------------------
; I/O registers (Phase 5; Phase 3 §3.8; Phase 4 §4.8–§4.10).
; ----------------------------------------------------------------------------
    EQU SYSCFG,   $80000
    EQU SYSID,    $80001
    EQU SYSVER,   $80002
    EQU SYSPWR,   $80003

    EQU TIMER_A,  $80010     ; +0 LOADLO +1 LOADHI +2/3 CNT +4 CTRL +5 DIV +6 STAT
    EQU TIMER_B,  $80018

    EQU KBD,      $80020     ; +0 KSTAT +1 KDATA +2 KMOD +3 KCTRL
    EQU JOYP,     $80030     ; +0 JOY1 +1 JOY2 +2 JCTRL
    EQU IRQC,     $80040     ; +0 IRQSTAT +1 IRQMASK +2 IRQACK

    EQU AUR,      $80100     ; voice n at n*$10; master block at +$40
    EQU VIC,      $80200     ; register offsets per Phase 3 §3.8

; ----------------------------------------------------------------------------
; BIOS RAM (decision bi — System Variables layout, $01100–$020FF).
; The supervisor stack (SSP = $020F0) grows down from the top of the region.
; ----------------------------------------------------------------------------
    EQU CUR_COL,   $01100    ; 2 B  cursor column (0–79)
    EQU CUR_ROW,   $01102    ; 2 B  cursor row (0–42)
    EQU CUR_ATTR,  $01104    ; 2 B  text attribute: fg[3:0] | bg[7:4]
    EQU RNG_STATE, $01106    ; 2 B  SYS_RAND Galois LFSR state (never 0)
    EQU VMODE_CUR, $01108    ; 2 B  current video mode (SYS_SETMODE)
    EQU DISPATCH,  $01110    ; 32 B IRQ dispatch table: 8 × 4 B handler addrs
    EQU LINEBUF,   $01140    ; 84 B shell line buffer (SYS_GETLINE target)

; Kernel Workspace conventions (amendment G17 + decision bd).
    EQU PALRAM,    $02100    ; 768 B  palette RAM (VPALBASE → here)
    EQU SATRAM,    $02400    ; 512 B  sprite attribute table
    EQU TEXTMAT,   $02600    ; 6880 B text matrix, 80×43 cells (dec. bd)

    EQU CONS_COLS, 80
    EQU CONS_ROWS, 43

; Boot environment (D12).
    EQU BOOT_SP,   $01100
    EQU BOOT_SSP,  $020F0
    EQU ROM_VECS,  $FFFC0

; ----------------------------------------------------------------------------
; Macros.
; ----------------------------------------------------------------------------
MACRO LOAD_ADDR reg, addr            ; amendment §1.2: full 20-bit load
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO

MACRO VICW reg_off, value            ; VIC register byte write via R4/R12
    LI   R12, \value
    SB   [R4 + \reg_off], R12
ENDMACRO

; ============================================================================
; ROM header — Phase 6 §6.3 (32 bytes at $FC000).
; ============================================================================
    ORG $FC000

    DB $46, $4C              ; +00 magic 'F','L'
    DB 1, 0                  ; +02 ROM version 1.0
    DW 1                     ; +04 build number
    DW 0                     ; +06 feature flags (reserved)
    DD 0                     ; +08 checksum — $00000000, not populated (bh)
    DD boot                  ; +0C BIOS kernel entry point
    DD $FE000                ; +10 font data start
    DD $FF800                ; +14 default palette start
    DD 0                     ; +18 reserved
    DD 0                     ; +1C reserved

; ============================================================================
; System call jump table — Phase 6 §6.4 (64 × 4 B at $FC100).
; The addresses are the permanent public ABI: entry for syscall id N is at
; exactly $FC100 + 4×N. Programs CALLA the table entry; the entry JMPAs the
; implementation, whose RET returns to the caller.
; ============================================================================
    ORG $FC100

    JMPA sys_putchar         ;  0 SYS_PUTCHAR
    JMPA sys_putstr          ;  1 SYS_PUTSTR
    JMPA sys_clrscr          ;  2 SYS_CLRSCR
    JMPA sys_setcursor       ;  3 SYS_SETCURSOR
    JMPA sys_setcolor        ;  4 SYS_SETCOLOR
    JMPA sys_scroll          ;  5 SYS_SCROLL
    JMPA sys_getkey          ;  6 SYS_GETKEY
    JMPA sys_pollkey         ;  7 SYS_POLLKEY
    JMPA sys_getchar         ;  8 SYS_GETCHAR
    JMPA sys_getline         ;  9 SYS_GETLINE
    JMPA sys_setmode         ; 10 SYS_SETMODE
    JMPA sys_setpal          ; 11 SYS_SETPAL
    JMPA sys_loadpal         ; 12 SYS_LOADPAL
    JMPA sys_vblank          ; 13 SYS_VBLANK
    JMPA sys_fillscr         ; 14 SYS_FILLSCR
    JMPA sys_memcpy          ; 15 SYS_MEMCPY
    JMPA sys_memset          ; 16 SYS_MEMSET
    JMPA sys_memcmp          ; 17 SYS_MEMCMP
    JMPA sys_sndinit         ; 18 SYS_SNDINIT
    JMPA sys_sndplay         ; 19 SYS_SNDPLAY
    JMPA sys_sndstop         ; 20 SYS_SNDSTOP
    JMPA sys_sndvol          ; 21 SYS_SNDVOL
    JMPA sys_tset            ; 22 SYS_TSET
    JMPA sys_twait           ; 23 SYS_TWAIT
    JMPA sys_getid           ; 24 SYS_GETID
    JMPA sys_reset           ; 25 SYS_RESET
    JMPA sys_irqset          ; 26 SYS_IRQSET
    JMPA sys_rand            ; 27 SYS_RAND
    JMPA sys_seed            ; 28 SYS_SEED
    JMPA sys_unimpl          ; 29 — reserved
    JMPA sys_unimpl          ; 30
    JMPA sys_unimpl          ; 31
    JMPA sys_unimpl          ; 32
    JMPA sys_unimpl          ; 33
    JMPA sys_unimpl          ; 34
    JMPA sys_unimpl          ; 35
    JMPA sys_unimpl          ; 36
    JMPA sys_unimpl          ; 37
    JMPA sys_unimpl          ; 38
    JMPA sys_unimpl          ; 39
    JMPA sys_unimpl          ; 40
    JMPA sys_unimpl          ; 41
    JMPA sys_unimpl          ; 42
    JMPA sys_unimpl          ; 43
    JMPA sys_unimpl          ; 44
    JMPA sys_unimpl          ; 45
    JMPA sys_unimpl          ; 46
    JMPA sys_unimpl          ; 47
    JMPA sys_unimpl          ; 48
    JMPA sys_unimpl          ; 49
    JMPA sys_unimpl          ; 50
    JMPA sys_unimpl          ; 51
    JMPA sys_unimpl          ; 52
    JMPA sys_unimpl          ; 53
    JMPA sys_unimpl          ; 54
    JMPA sys_unimpl          ; 55
    JMPA sys_unimpl          ; 56
    JMPA sys_unimpl          ; 57
    JMPA sys_unimpl          ; 58
    JMPA sys_unimpl          ; 59
    JMPA sys_unimpl          ; 60
    JMPA sys_unimpl          ; 61
    JMPA sys_unimpl          ; 62
    JMPA sys_unimpl          ; 63

; ============================================================================
; BIOS kernel — $FC200 onward (must stay below $FE000).
; ============================================================================
    ORG $FC200

; ----------------------------------------------------------------------------
; Boot — Phase 6 §6.8 (task 12.1). RESET vector points here.
; ----------------------------------------------------------------------------
boot:
    ; Stage 1 — CPU & stack initialisation. Hardware reset already gave us
    ; S=1, I=0 (Phase 2 §2.7); condition flags start clear.
    LI   R1, BOOT_SP
    MOV  SP, R1              ; SP = $01100 (empty-descending)
    LI   R1, BOOT_SSP
    MTSR SSP, R1             ; SSP = $020F0 (16-slot supervisor stack)
    MTSR USP, SP             ; USP mirrors the boot SP (D12 environment)
    LOAD_ADDR R1, ROM_VECS
    MTSR IVT, R1             ; IVT → ROM system vectors ($FFFC0)

    ; Stage 2 — RAM clear (task 12.2).
    LI   R1, $0000           ; Zero Page $00000–$000FF
    LI   R2, $0100
    CALLA zero_region
    LI   R1, $1100           ; System Variables $01100–$020FF
    LI   R2, $2100
    CALLA zero_region
    LI   R1, $2100           ; Kernel Workspace $02100–$040FF
    LI   R2, $4100
    CALLA zero_region

    ; Stage 3 — device initialisation (task 12.3): safe defaults everywhere.
    CALLA dev_init

    ; Stage 4 — data setup (task 12.4): default palette ROM → RAM, then the
    ; three VIC base registers (÷16 convention).
    LOAD_ADDR R1, $FF800     ; src: ROM default palette
    LOAD_ADDR R2, PALRAM     ; dst: palette RAM ($02100)
    LI   R3, 768
    CALLA sys_memcpy

    LOAD_ADDR R4, VIC
    VICW $0B, (PALRAM / 16) & $FF          ; VPALBASE  = $0210
    VICW $0C, (PALRAM / 16) >> 8
    VICW $0D, (SATRAM / 16) & $FF          ; VSATBASE  = $0240
    VICW $0E, (SATRAM / 16) >> 8
    VICW $0F, (TEXTMAT / 16) & $FF         ; VTMAPBASE = $0260
    VICW $10, (TEXTMAT / 16) >> 8

    ; Default text attribute: white on black (palette 1 on palette 0).
    LI   R1, $01
    SW   [R0 + CUR_ATTR], R1

    ; Seed the PRNG (amendment G18: LFSR seeded $0001 at boot).
    SW   [R0 + RNG_STATE], R1

    ; Stage 5 — display initialisation (task 12.12): a clean screen and
    ; the banner. The console syscalls are live by now.
    CALLA sys_clrscr
    LOAD_ADDR R1, str_banner
    CALLA sys_putstr

    ; Stage 6 — IRQ enable and handoff (§6.8): unmask timer A, keyboard,
    ; and VBLANK; enable interrupts; probe $04100 for an autoboot header.
    LOAD_ADDR R4, IRQC
    LI   R12, $15            ; bit 0 timer A | bit 2 keyboard | bit 4 VBLANK
    SW   [R4 + 1], R12
    SEI

    ; Autoboot (task 12.15, §6.9 / bs): 'F','B' at $04100, entry ≥ 12,
    ; min-RAM ≤ 512KB → CALL load_address + entry_offset. Present-but-
    ; invalid earns a diagnostic; a quiet $04100 goes straight to READY.
    LOAD_ADDR R5, $04100
    LB   R1, [R5]
    CMPI R1, $46             ; 'F'
    BNE  shell_loop
    LB   R1, [R5 + 1]
    CMPI R1, $42             ; 'B'
    BNE  shell_loop
    LW   R1, [R5 + 4]        ; entry point offset
    CMPI R1, 12
    BCC  autoboot_bad        ; inside the header — invalid
    LW   R2, [R5 + 6]        ; minimum RAM (KB)
    CMPI R2, 513
    BCS  autoboot_bad        ; more than the machine has
    LW   R2, [R5 + 8]        ; load address, 32-bit LE masked to 20
    LW   R3, [R5 + 10]
    LI   R12, 16
    SHL  R3, R3, R12
    OR   R2, R2, R3
    ADD  R1, R1, R2
    CALL R1                  ; a program ending in RET drops to READY (bs)
    JMPA shell_loop
autoboot_bad:
    LOAD_ADDR R1, str_badboot
    CALLA sys_putstr

; ----------------------------------------------------------------------------
; The BIOS shell (tasks 12.13–12.14, §6.10, decision bs). Top-level code:
; R5 is the parse cursor; R6–R8 are command scratch — all of them survive
; the syscalls (decision be).
; ----------------------------------------------------------------------------
shell_loop:
    LOAD_ADDR R1, str_ready
    CALLA sys_putstr
    LI   R1, LINEBUF
    LI   R2, 80
    CALLA sys_getline
    LI   R5, LINEBUF
    CALLA skip_spaces
    LB   R1, [R5]
    CMPI R1, 0
    BEQ  shell_loop          ; an empty line just earns another READY.
    LOAD_ADDR R6, str_cmd_mem
    CALLA match_cmd
    CMPI R1, 1
    BEQ  do_mem
    LOAD_ADDR R6, str_cmd_poke
    CALLA match_cmd
    CMPI R1, 1
    BEQ  do_poke
    LOAD_ADDR R6, str_cmd_peek
    CALLA match_cmd
    CMPI R1, 1
    BEQ  do_peek
    LOAD_ADDR R6, str_cmd_run
    CALLA match_cmd
    CMPI R1, 1
    BEQ  do_run
    LOAD_ADDR R6, str_cmd_load
    CALLA match_cmd
    CMPI R1, 1
    BEQ  do_load
    LOAD_ADDR R6, str_cmd_reset
    CALLA match_cmd
    CMPI R1, 1
    BEQ  sys_reset           ; RESET: the whole §6.8 sequence again
    LOAD_ADDR R6, str_cmd_ver
    CALLA match_cmd
    CMPI R1, 1
    BEQ  do_ver
    LOAD_ADDR R6, str_cmd_help
    CALLA match_cmd
    CMPI R1, 1
    BEQ  do_help
shell_syntax:
    LOAD_ADDR R1, str_syntax
    CALLA sys_putstr
    JMPA shell_loop

; MEM addr — 16 rows of 16 bytes: "AAAAA: XX XX … XX". Live bus reads
; (bs): dumping KDATA dequeues, exactly like the machines this imitates.
do_mem:
    CALLA parse_hex
    CMPI R2, 0
    BEQ  shell_syntax
    MOV  R6, R1              ; running address
    LI   R7, 16              ; rows
mem_row:
    MOV  R1, R6
    CALLA print_hex20
    LI   R1, $3A             ; ':'
    CALLA sys_putchar
    LI   R8, 16              ; bytes per row
mem_col:
    LI   R1, $20
    CALLA sys_putchar
    LB   R1, [R6]
    CALLA print_hex_byte
    ADDI R6, R6, 1
    SUBI R8, R8, 1
    BNE  mem_col
    LI   R1, $0A
    CALLA sys_putchar
    SUBI R7, R7, 1
    BNE  mem_row
    JMPA shell_loop

; POKE addr val — one byte, straight onto the bus.
do_poke:
    CALLA parse_hex
    CMPI R2, 0
    BEQ  shell_syntax
    MOV  R6, R1
    CALLA parse_hex
    CMPI R2, 0
    BEQ  shell_syntax
    SB   [R6], R1
    JMPA shell_loop

; PEEK addr — read and print one byte.
do_peek:
    CALLA parse_hex
    CMPI R2, 0
    BEQ  shell_syntax
    MOV  R6, R1
    LB   R1, [R6]
    CALLA print_hex_byte
    LI   R1, $0A
    CALLA sys_putchar
    JMPA shell_loop

; RUN addr — CALL, so a RETting program returns to READY (bs).
do_run:
    CALLA parse_hex
    CMPI R2, 0
    BEQ  shell_syntax
    CALL R1
    JMPA shell_loop

do_load:
    LOAD_ADDR R1, str_noload
    CALLA sys_putstr
    JMPA shell_loop

do_ver:
    LOAD_ADDR R1, str_ver
    CALLA sys_putstr
    JMPA shell_loop

do_help:
    LOAD_ADDR R1, str_help
    CALLA sys_putstr
    JMPA shell_loop

; ----------------------------------------------------------------------------
; Shell helpers.
; ----------------------------------------------------------------------------

; skip_spaces — advance the parse cursor R5 past ' '. Clobbers R3.
skip_spaces:
    LB   R3, [R5]
    CMPI R3, $20
    BNE  ss_done
    ADDI R5, R5, 1
    JMPA skip_spaces
ss_done:
    RET

; match_cmd — case-insensitively match the whole token at [R5] against
; the ROM string [R6] (stored uppercase). On a match the cursor advances
; past the token and R1=1; otherwise the cursor rewinds and R1=0.
; Clobbers R1–R4.
match_cmd:
    MOV  R4, R5              ; rewind point
mc_loop:
    LB   R2, [R6]
    CMPI R2, 0
    BEQ  mc_endcmd
    LB   R3, [R5]
    ANDI R3, R3, $DF         ; fold input letters to uppercase
    CMP  R3, R2
    BNE  mc_fail
    ADDI R5, R5, 1
    ADDI R6, R6, 1
    JMPA mc_loop
mc_endcmd:
    LB   R3, [R5]            ; a whole token: NUL or space follows
    CMPI R3, 0
    BEQ  mc_ok
    CMPI R3, $20
    BEQ  mc_ok
mc_fail:
    MOV  R5, R4
    LI   R1, 0
    RET
mc_ok:
    LI   R1, 1
    RET

; parse_hex — hex number at the cursor, optional '$' prefix (bs).
; R1 ← value, R2 ← digit count (0 = no number found). Clobbers R1–R3, R12.
parse_hex:
    PUSH LR
    CALLA skip_spaces
    LI   R1, 0
    LI   R2, 0
    LB   R3, [R5]
    CMPI R3, $24             ; optional '$'
    BNE  ph_loop
    ADDI R5, R5, 1
ph_loop:
    LB   R3, [R5]
    CMPI R3, $30
    BCC  ph_done             ; below '0'
    CMPI R3, $3A
    BCC  ph_dig              ; '0'–'9'
    ANDI R3, R3, $DF
    CMPI R3, $41
    BCC  ph_done             ; between '9' and 'A'
    CMPI R3, $47
    BCS  ph_done             ; past 'F'
    SUBI R3, R3, 55          ; 'A' → 10
    JMPA ph_acc
ph_dig:
    SUBI R3, R3, $30
ph_acc:
    LI   R12, 4
    SHL  R1, R1, R12
    OR   R1, R1, R3
    ADDI R2, R2, 1
    ADDI R5, R5, 1
    JMPA ph_loop
ph_done:
    POP  LR
    RET

; print_nibble — R1 bits 3:0 as one hex digit through SYS_PUTCHAR.
; Clobbers R1–R4, R12.
print_nibble:
    PUSH LR
    ANDI R1, R1, $0F
    CMPI R1, 10
    BCC  pn_digit
    ADDI R1, R1, 55          ; 10 → 'A'
    JMPA pn_put
pn_digit:
    ADDI R1, R1, $30
pn_put:
    CALLA sys_putchar
    POP  LR
    RET

; print_hex_byte — R1 as two hex digits. Clobbers R1–R4, R12; R5 saved.
print_hex_byte:
    PUSH LR
    PUSH R5
    MOV  R5, R1
    LI   R12, 4
    SHR  R1, R1, R12
    CALLA print_nibble
    MOV  R1, R5
    CALLA print_nibble
    POP  R5
    POP  LR
    RET

; print_hex20 — R1 as five hex digits (a full address). Clobbers R1–R4,
; R12; R5, R6 saved.
print_hex20:
    PUSH LR
    PUSH R5
    PUSH R6
    MOV  R5, R1
    LI   R6, 16              ; shifts 16, 12, 8, 4, 0
ph20_loop:
    MOV  R1, R5
    SHR  R1, R1, R6
    CALLA print_nibble
    CMPI R6, 0
    BEQ  ph20_done
    SUBI R6, R6, 4
    JMPA ph20_loop
ph20_done:
    POP  R6
    POP  R5
    POP  LR
    RET

; ----------------------------------------------------------------------------
; Shell strings (stored uppercase — match_cmd folds input to match).
; ----------------------------------------------------------------------------
str_banner:
    DB "**** FLOMMODORE BIOS V1.0 ****", $0A
    DB "GAB-16 CPU  512K RAM  VIC-256  AUR-1", $0A, $0A, 0
str_ready:
    DB "READY.", $0A, 0
str_syntax:
    DB "?SYNTAX ERROR", $0A, 0
str_badboot:
    DB "?BAD BOOT HEADER", $0A, 0
str_noload:
    DB "?LOAD NOT SUPPORTED", $0A, 0
str_ver:
    DB "FLOMMODORE BIOS V1.0  ROM 16K  GAB-16", $0A, 0
str_help:
    DB "MEM POKE PEEK RUN LOAD RESET VER HELP", $0A, 0
str_cmd_mem:
    DB "MEM", 0
str_cmd_poke:
    DB "POKE", 0
str_cmd_peek:
    DB "PEEK", 0
str_cmd_run:
    DB "RUN", 0
str_cmd_load:
    DB "LOAD", 0
str_cmd_reset:
    DB "RESET", 0
str_cmd_ver:
    DB "VER", 0
str_cmd_help:
    DB "HELP", 0

; ----------------------------------------------------------------------------
; zero_region — zero [R1, R2) with 16-bit stores. R1/R2 must be word-even
; and below $10000 (all boot regions are). Clobbers R1.
; ----------------------------------------------------------------------------
zero_region:
    CMP  R1, R2
    BEQ  zero_done
    SW   [R1], R0
    ADDI R1, R1, 2
    JMPA zero_region
zero_done:
    RET

; ----------------------------------------------------------------------------
; dev_init — Stage 3 safe defaults (task 12.3). Clobbers R4, R12.
; ----------------------------------------------------------------------------
dev_init:
    PUSH LR
    ; Timers: both disabled, status flags cleared (w1c).
    LOAD_ADDR R4, TIMER_A
    SW   [R4 + 4], R0        ; TACTRL = 0
    SW   [R4 + 12], R0       ; TBCTRL = 0 (TIMER_B = TIMER_A + 8)
    LI   R12, 1
    SW   [R4 + 6], R12       ; TASTAT w1c
    SW   [R4 + 14], R12      ; TBSTAT w1c

    ; IRQ controller: mask all sources, acknowledge anything pending.
    LOAD_ADDR R4, IRQC
    SW   [R4 + 1], R0        ; IRQMASK = 0
    LI   R12, $FF
    SW   [R4 + 2], R12       ; IRQACK all

    ; Keyboard: flush the queue and enable the key-event device gate
    ; (KCTRL bit 0 = IRQ enable, bit 1 = flush, self-clearing).
    LOAD_ADDR R4, KBD
    LI   R12, $03
    SW   [R4 + 3], R12

    ; Joystick: reads enabled (passive), transition IRQ off.
    LOAD_ADDR R4, JOYP
    SW   [R4 + 2], R0        ; JCTRL = 0

    ; AUR-1: one silent-default routine for boot and SYS_SNDINIT alike
    ; (decision bp) — SNDINIT is the implementation, dev_init a caller.
    CALLA sys_sndinit

    ; VIC-256: no VIC IRQs, no sprites, background colour 0, no scroll;
    ; text mode 640×360 pointed at the default palette (§6.8 stage 3).
    LOAD_ADDR R4, VIC
    VICW $16, 0              ; VIRQEN  = 0
    VICW $13, 0              ; VSPRENA = 0
    VICW $04, 0              ; VBGCOL  = 0
    VICW $11, 0              ; VSCROLLX = 0
    VICW $12, 0              ; VSCROLLY = 0
    VICW $02, 1              ; VRESX = 640
    VICW $03, 1              ; VRESY = 360
    VICW $00, 3              ; VMODE = text — mode last, geometry first
    POP  LR
    RET

; ----------------------------------------------------------------------------
; System calls (Phase 6 §6.4). Implementations arrive block by block; every
; jump-table slot without one lands on sys_unimpl.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
; Console (tasks 12.5–12.6, decision bl). Cursor state lives in CUR_COL/
; CUR_ROW/CUR_ATTR; the matrix is the 80×43 window at TEXTMAT (decision bd).
; ----------------------------------------------------------------------------

; cursor_addr — R4 ← TEXTMAT + CUR_ROW*160 + CUR_COL*2. Clobbers R4, R12.
cursor_addr:
    LW   R4, [R0 + CUR_ROW]
    LI   R12, (CONS_COLS * 2)
    MUL  R4, R4, R12
    LW   R12, [R0 + CUR_COL]
    ADD  R4, R4, R12
    ADD  R4, R4, R12
    LI   R12, TEXTMAT
    ADD  R4, R4, R12
    RET

; advance_row — cursor down one row, scrolling when it would leave the
; 43-row console (bl). Clobbers R1–R4, R12.
advance_row:
    PUSH LR
    LW   R12, [R0 + CUR_ROW]
    ADDI R12, R12, 1
    CMPI R12, CONS_ROWS
    BCC  advrow_store
    CALLA scroll1
    LI   R12, (CONS_ROWS - 1)
advrow_store:
    SW   [R0 + CUR_ROW], R12
    POP  LR
    RET

; scroll1 — scroll the console up one line: rows 1–42 copy over rows 0–41
; (forward byte copy with dst < src, so the overlap is safe), and the
; freed bottom row clears to ' ' with the current attribute (bl).
; Clobbers R1–R4, R12.
scroll1:
    PUSH LR
    LI   R1, (TEXTMAT + CONS_COLS * 2)
    LI   R2, TEXTMAT
    LI   R3, ((CONS_ROWS - 1) * CONS_COLS * 2)
    CALLA sys_memcpy
    LI   R1, (TEXTMAT + (CONS_ROWS - 1) * CONS_COLS * 2)
    LI   R4, CONS_COLS
    LI   R2, $20
    LW   R12, [R0 + CUR_ATTR]
scroll1_clear:
    SB   [R1], R2
    SB   [R1 + 1], R12
    ADDI R1, R1, 2
    SUBI R4, R4, 1
    BNE  scroll1_clear
    POP  LR
    RET

; SYS_PUTCHAR (id 0) — print the byte in R1 at the cursor (bl): $0A
; newline, $0D carriage return, $08 non-destructive backspace; every other
; value renders as its font glyph. Column 80 wraps; a row advance past row
; 42 scrolls one line and holds the cursor on row 42. Clobbers R1–R4, R12.
sys_putchar:
    PUSH LR
    ANDI R1, R1, $FF
    CMPI R1, $0A
    BEQ  putchar_lf
    CMPI R1, $0D
    BEQ  putchar_cr
    CMPI R1, $08
    BEQ  putchar_bs
    CALLA cursor_addr        ; glyph: char + attribute at the cursor cell
    SB   [R4], R1
    LW   R12, [R0 + CUR_ATTR]
    SB   [R4 + 1], R12
    LW   R12, [R0 + CUR_COL] ; advance the column, wrapping at 80
    ADDI R12, R12, 1
    CMPI R12, CONS_COLS
    BCC  putchar_setcol
putchar_lf:
    SW   [R0 + CUR_COL], R0  ; column home, then row advance (shared with wrap)
    CALLA advance_row
    JMPA putchar_done
putchar_cr:
    SW   [R0 + CUR_COL], R0
    JMPA putchar_done
putchar_bs:
    LW   R12, [R0 + CUR_COL]
    CMPI R12, 0
    BEQ  putchar_done
    SUBI R12, R12, 1
putchar_setcol:
    SW   [R0 + CUR_COL], R12
putchar_done:
    POP  LR
    RET

; SYS_PUTSTR (id 1) — print the NUL-terminated string at [R1] through
; SYS_PUTCHAR, so control characters behave identically. Clobbers R1–R4,
; R12; R5 is saved around use as the walking pointer.
sys_putstr:
    PUSH LR
    PUSH R5
    MOV  R5, R1
putstr_loop:
    LB   R1, [R5]
    CMPI R1, 0
    BEQ  putstr_done
    CALLA sys_putchar
    ADDI R5, R5, 1
    JMPA putstr_loop
putstr_done:
    POP  R5
    POP  LR
    RET

; SYS_CLRSCR (id 2) — every cell becomes ' ' with the current attribute,
; cursor homes to (0,0) (bl). Clobbers R1, R2, R4, R12.
sys_clrscr:
    LI   R1, TEXTMAT
    LI   R4, (CONS_COLS * CONS_ROWS)
    LI   R2, $20
    LW   R12, [R0 + CUR_ATTR]
clrscr_loop:
    SB   [R1], R2
    SB   [R1 + 1], R12
    ADDI R1, R1, 2
    SUBI R4, R4, 1
    BNE  clrscr_loop
    SW   [R0 + CUR_COL], R0
    SW   [R0 + CUR_ROW], R0
    RET

; SYS_SETCURSOR (id 3) — R1=col, R2=row; out-of-range values clamp to the
; last column/row (bl). Inputs mask to 16 bits first so the clamp compare
; and the stored 16-bit variable agree on the value. Clobbers R1, R2.
sys_setcursor:
    ANDI R1, R1, $FFFF
    CMPI R1, CONS_COLS
    BCC  setcur_col
    LI   R1, (CONS_COLS - 1)
setcur_col:
    SW   [R0 + CUR_COL], R1
    ANDI R2, R2, $FFFF
    CMPI R2, CONS_ROWS
    BCC  setcur_row
    LI   R2, (CONS_ROWS - 1)
setcur_row:
    SW   [R0 + CUR_ROW], R2
    RET

; SYS_SETCOLOR (id 4) — CUR_ATTR ← bg(R2)<<4 | fg(R1), both masked to
; palette entries 0–15 (§3.6 text attribute format). Clobbers R1, R2, R12.
sys_setcolor:
    ANDI R1, R1, $0F
    ANDI R2, R2, $0F
    LI   R12, 4
    SHL  R2, R2, R12
    OR   R1, R1, R2
    SW   [R0 + CUR_ATTR], R1
    RET

; SYS_SCROLL (id 5) — scroll up R1 lines; values ≥ 43 clamp to 43, beyond
; which the result (a fully cleared screen) is identical (bl). Clobbers
; R1–R4, R12; R5 is saved around use as the line counter.
sys_scroll:
    PUSH LR
    PUSH R5
    ANDI R1, R1, $FFFF
    CMPI R1, CONS_ROWS
    BCC  sysscroll_clamped
    LI   R1, CONS_ROWS
sysscroll_clamped:
    MOV  R5, R1
sysscroll_loop:
    CMPI R5, 0
    BEQ  sysscroll_done
    CALLA scroll1
    SUBI R5, R5, 1
    JMPA sysscroll_loop
sysscroll_done:
    POP  R5
    POP  LR
    RET

; ----------------------------------------------------------------------------
; Keyboard (task 12.7, decision bn). The queue lives behind KSTAT/KDATA
; (§5.3); KDATA dequeues on ANY read width, so every read here is
; deliberate. Blocking calls busy-poll KSTAT bit 0.
; ----------------------------------------------------------------------------

; SYS_GETKEY (id 6) — block until a key PRESS; release events are consumed
; and discarded (bn). R1 ← the press event word (bit 15 clear, bits 7:0
; the USB HID code). Clobbers R1, R4, R12.
sys_getkey:
    LOAD_ADDR R4, KBD
getkey_wait:
    LW   R12, [R4]           ; KSTAT
    ANDI R12, R12, 1
    BEQ  getkey_wait         ; queue empty — keep polling
    LW   R1, [R4 + 1]        ; KDATA — dequeues
    LI   R12, $8000
    AND  R12, R1, R12
    BNE  getkey_wait         ; bit 15: a release — discard, poll again
    RET

; SYS_POLLKEY (id 7) — R1 ← next raw event word (press or release), or 0
; when the queue is empty (bn). Clobbers R1, R4, R12.
sys_pollkey:
    LOAD_ADDR R4, KBD
    LW   R12, [R4]           ; KSTAT
    ANDI R12, R12, 1
    BNE  pollkey_read
    LI   R1, 0
    RET
pollkey_read:
    LW   R1, [R4 + 1]        ; KDATA — dequeues
    RET

; hid_to_ascii — map the HID code in R1 through the ROM table (bn), the
; shifted half selected live from KMOD bit 0 (amendment G18). R1 ← ASCII,
; or 0 for codes with no mapping. Clobbers R1, R4, R12.
hid_to_ascii:
    ANDI R1, R1, $7F         ; table covers HID 0–127
    LOAD_ADDR R4, KBD
    LW   R12, [R4 + 2]       ; KMOD
    ANDI R12, R12, 1         ; shift held?
    LOAD_ADDR R4, hid_ascii
    BEQ  hidmap_load
    ADDI R4, R4, 128         ; the shifted map sits right behind
hidmap_load:
    ADD  R4, R4, R1
    LB   R1, [R4]
    RET

; SYS_GETCHAR (id 8) — block until a press that maps to a character;
; unmapped presses (F-keys, arrows, modifiers) are swallowed (bn).
; R1 ← ASCII. Clobbers R1, R4, R12.
sys_getchar:
    PUSH LR
getchar_wait:
    CALLA sys_getkey
    CALLA hid_to_ascii
    CMPI R1, 0
    BEQ  getchar_wait
    POP  LR
    RET

; SYS_GETLINE (id 9) — read an edited line into [R1], at most R2
; characters plus the terminating NUL (the buffer must hold R2+1 bytes).
; Printable input echoes through SYS_PUTCHAR; Backspace (HID $2A) erases
; buffer and screen (BS ' ' BS); Enter (HID $28) terminates, echoes a
; newline, NUL-terminates, and returns the length in R1 (amendment G18).
; Input beyond R2 is swallowed (bn). Clobbers R1–R4, R12; R5–R7 saved.
sys_getline:
    PUSH LR
    PUSH R5                  ; buffer base
    PUSH R6                  ; length so far
    PUSH R7                  ; maximum length
    MOV  R5, R1
    LI   R6, 0
    ANDI R7, R2, $FFFF
getline_wait:
    CALLA sys_getkey         ; press event word
    ANDI R1, R1, $7F         ; HID code
    CMPI R1, $28             ; Enter — terminate
    BEQ  getline_done
    CMPI R1, $2A             ; Backspace — edit
    BEQ  getline_bs
    CALLA hid_to_ascii
    CMPI R1, 0
    BEQ  getline_wait        ; unmapped — swallow
    CMP  R6, R7
    BCS  getline_wait        ; line full (unsigned ≥) — swallow
    ADD  R4, R5, R6          ; store, then echo
    SB   [R4], R1
    ADDI R6, R6, 1
    CALLA sys_putchar
    JMPA getline_wait
getline_bs:
    CMPI R6, 0
    BEQ  getline_wait        ; nothing to erase
    SUBI R6, R6, 1
    LI   R1, $08             ; erase on screen: BS ' ' BS
    CALLA sys_putchar
    LI   R1, $20
    CALLA sys_putchar
    LI   R1, $08
    CALLA sys_putchar
    JMPA getline_wait
getline_done:
    ADD  R4, R5, R6
    SB   [R4], R0            ; NUL-terminate
    LI   R1, $0A
    CALLA sys_putchar        ; echo the newline
    MOV  R1, R6              ; R1 ← length
    POP  R7
    POP  R6
    POP  R5
    POP  LR
    RET

; ----------------------------------------------------------------------------
; Video & palette (task 12.9, decision bo).
; ----------------------------------------------------------------------------

; SYS_SETMODE (id 10) — R1=mode, R2=resolution index (both axes), R3=depth.
; Geometry first, mode last (the established bring-up order); the mode is
; mirrored into VMODE_CUR. Clobbers R1–R4, R12.
sys_setmode:
    LOAD_ADDR R4, VIC
    ANDI R2, R2, 3
    SB   [R4 + $02], R2      ; VRESX
    SB   [R4 + $03], R2      ; VRESY
    ANDI R3, R3, 3
    SB   [R4 + $01], R3      ; VPALETTE
    ANDI R1, R1, 3
    SB   [R4 + $00], R1      ; VMODE — last
    SW   [R0 + VMODE_CUR], R1
    RET

; SYS_SETPAL (id 11) — palette entry R1 ← R:G:B from R3:R2 (bo: registers
; are 20-bit, so red rides in R3 and R2 carries (G<<8)|B). Entries live in
; palette RAM; the VIC reads them per frame, no re-copy needed.
; Clobbers R1–R4, R12.
sys_setpal:
    ANDI R1, R1, $FF
    LI   R12, 3
    MUL  R1, R1, R12
    LI   R12, PALRAM
    ADD  R4, R1, R12         ; &palette[R1]
    SB   [R4], R3            ; R
    LI   R12, 8
    SHR  R1, R2, R12
    SB   [R4 + 1], R1        ; G
    SB   [R4 + 2], R2        ; B
    RET

; SYS_LOADPAL (id 12) — copy a full 768-byte palette from [R1] into
; palette RAM. Clobbers R1–R4, R12.
sys_loadpal:
    PUSH LR
    LI   R2, PALRAM          ; dst; src stays in R1 (memcpy: R1→R2)
    LI   R3, 768
    CALLA sys_memcpy
    POP  LR
    RET

; SYS_VBLANK (id 13) — block until the NEXT VBLANK: wait out any VBLANK in
; progress (VSTAT bit 0 is a level flag — set at the first blank line,
; cleared at line 0), then wait for the rising edge. Clobbers R1, R4, R12.
sys_vblank:
    LOAD_ADDR R4, VIC
vblank_drain:
    LW   R12, [R4 + $17]     ; VSTAT
    ANDI R12, R12, 1
    BNE  vblank_drain        ; currently blanking — wait for line 0
vblank_wait:
    LW   R12, [R4 + $17]
    ANDI R12, R12, 1
    BEQ  vblank_wait         ; drawing — wait for the blank to start
    RET

; SYS_FILLSCR (id 14) — fill the current framebuffer with the colour index
; in R1 (bo). Text mode has no framebuffer: R1 ← $FFFF, nothing written.
; The fill byte forms per depth; the byte count from live geometry; the
; base from VBUF×16. Fills by 16-bit words (every legal size is even).
; Clobbers R1–R4, R12.
sys_fillscr:
    LOAD_ADDR R4, VIC
    LW   R12, [R4 + $00]     ; VMODE
    CMPI R12, 3
    BNE  fillscr_go
    LI   R1, $FFFF           ; text mode — no framebuffer (bo)
    RET
fillscr_go:
    ; R3 ← pixel count = 320·(VRESX+1) × 180·(VRESY+1)
    LW   R3, [R4 + $02]      ; VRESX index
    ADDI R3, R3, 1
    LI   R12, 320
    MUL  R3, R3, R12
    LW   R12, [R4 + $03]     ; VRESY index
    ADDI R12, R12, 1
    MUL  R3, R3, R12
    LI   R12, 180
    MUL  R3, R3, R12
    ; depth: form the fill byte in R1, scale pixels → bytes in R3.
    LW   R2, [R4 + $01]      ; VPALETTE
    CMPI R2, 0
    BEQ  fillscr_1bpp
    CMPI R2, 1
    BEQ  fillscr_4bpp
    ANDI R1, R1, $FF         ; 8bpp (and the reserved value 2, bo)
    JMPA fillscr_base
fillscr_1bpp:
    LI   R12, 3              ; bytes = pixels / 8
    SHR  R3, R3, R12
    CMPI R1, 0
    BEQ  fillscr_base        ; index 0 → fill byte $00 (R1 already 0)
    LI   R1, $FF
    JMPA fillscr_base
fillscr_4bpp:
    LI   R12, 1              ; bytes = pixels / 2
    SHR  R3, R3, R12
    ANDI R1, R1, $0F         ; low nibble replicated
    LI   R12, 4
    SHL  R12, R1, R12
    OR   R1, R1, R12
fillscr_base:
    ; R2 ← VBUF × 16 (done with the VIC pointer in R4 after these reads).
    LW   R2, [R4 + $06]      ; VBUFLO
    LW   R12, [R4 + $07]     ; VBUFHI
    LI   R4, 8
    SHL  R12, R12, R4
    OR   R2, R2, R12
    LI   R12, 4
    SHL  R2, R2, R12         ; ×16 — the framebuffer base
    LI   R12, 8              ; R1 ← fill byte replicated into a word
    SHL  R4, R1, R12
    OR   R1, R1, R4
    LI   R12, 1              ; R3 ← word count (every legal size is even)
    SHR  R3, R3, R12
fillscr_loop:
    CMPI R3, 0
    BEQ  fillscr_done
    SW   [R2], R1
    ADDI R2, R2, 2
    SUBI R3, R3, 1
    JMPA fillscr_loop
fillscr_done:
    LI   R1, 0               ; success ($FFFF is the text-mode refusal)
    RET

; ----------------------------------------------------------------------------
; Sound (task 12.10, decision bp).
; ----------------------------------------------------------------------------

; SYS_SNDINIT (id 18) — the silent default state, shared with boot's
; dev_init: master volume 0, no voices routed, filter empty, envelope IRQ
; off, all four gates released, ASTAT cleared — and AMVOLL/AMVOLR at $0F
; so SYS_SNDVOL alone unmutes (bp). Clobbers R4, R12.
sys_sndinit:
    LOAD_ADDR R4, AUR
    SB   [R4 + $40], R0      ; AMVOL   = 0
    SB   [R4 + $43], R0      ; AMVOICE = 0
    SB   [R4 + $44], R0      ; AMFILT  = 0
    SB   [R4 + $4A], R0      ; AIRQEN  = 0
    SB   [R4 + $03], R0      ; voice 0 gate off
    SB   [R4 + $13], R0      ; voice 1
    SB   [R4 + $23], R0      ; voice 2
    SB   [R4 + $33], R0      ; voice 3
    LI   R12, $0F
    SB   [R4 + $41], R12     ; AMVOLL = $0F
    SB   [R4 + $42], R12     ; AMVOLR = $0F
    LI   R12, $FF
    SB   [R4 + $4B], R12     ; ASTAT w1c
    RET

; SYS_SNDPLAY (id 19) — one call, one note (bp): voice R1 gets freq R2,
; waveform R3 (bits 2:0), full pre-mixer volume, centre pan, the default
; snappy ADSR, a route into the mix, and the gate. Clobbers R1–R4, R12.
sys_sndplay:
    ANDI R1, R1, 3
    LI   R12, 16
    MUL  R4, R1, R12
    LI   R12, (AUR & $FFFF)
    ADD  R4, R4, R12
    LUI  R4, (AUR >> 16)     ; R4 ← voice base (AUR + 16·voice)
    SB   [R4 + $00], R2      ; VFREQLO
    LI   R12, 8
    SHR  R12, R2, R12
    SB   [R4 + $01], R12     ; VFREQHI
    ANDI R3, R3, 7
    SB   [R4 + $02], R3      ; VWAVE (bits 2:0; FM stays a register affair)
    LI   R12, $FF
    SB   [R4 + $07], R12     ; VVOL — full pre-mixer volume
    LI   R12, $0F
    SB   [R4 + $0E], R12     ; VVOLL — centre pan
    SB   [R4 + $0D], R12     ; VVOLR
    SB   [R4 + $04], R0      ; VAD  = $00 — instant attack, fastest decay
    LI   R12, $F4
    SB   [R4 + $05], R12     ; VSR  = sustain 15, release 4 (114 ms)
    ; route the voice into the mix: AMVOICE |= 1 << voice
    LI   R12, 1
    SHL  R12, R12, R1
    LOAD_ADDR R2, AUR
    LB   R3, [R2 + $43]
    OR   R3, R3, R12
    SB   [R2 + $43], R3
    LI   R12, $80
    SB   [R4 + $03], R12     ; VCTRL gate on — attack starts now
    RET

; SYS_SNDSTOP (id 20) — clear voice R1's gate: the release phase begins;
; the routing stays (bp). Clobbers R1, R4, R12.
sys_sndstop:
    ANDI R1, R1, 3
    LI   R12, 16
    MUL  R4, R1, R12
    LI   R12, (AUR & $FFFF)
    ADD  R4, R4, R12
    LUI  R4, (AUR >> 16)
    SB   [R4 + $03], R0      ; VCTRL gate off
    RET

; SYS_SNDVOL (id 21) — master volume: AMVOL ← R1 (8-bit), nothing else
; (bp: AMVOLL/AMVOLR were parked at $0F by SNDINIT). Clobbers R1, R4.
sys_sndvol:
    ANDI R1, R1, $FF
    LOAD_ADDR R4, AUR
    SB   [R4 + $40], R1
    RET

; ----------------------------------------------------------------------------
; Timers & system (task 12.11, decisions bq/br).
; ----------------------------------------------------------------------------

; SYS_TSET (id 22) — configure timer R1 (0=A, 1=B): reload R2, control
; flags R3. A stale expired flag is cleared first, CTRL written last so
; the 0→1 enable loads the counter (§5.2). Clobbers R1–R4, R12.
sys_tset:
    ANDI R1, R1, 1
    LI   R12, 8
    MUL  R4, R1, R12
    LI   R12, (TIMER_A & $FFFF)
    ADD  R4, R4, R12
    LUI  R4, (TIMER_A >> 16)
    SB   [R4 + 0], R2        ; TxLOADLO
    LI   R12, 8
    SHR  R12, R2, R12
    SB   [R4 + 1], R12       ; TxLOADHI
    LI   R12, 1
    SW   [R4 + 6], R12       ; TxSTAT w1c — a stale flag would fake a TWAIT
    SW   [R4 + 4], R3        ; TxCTRL — last
    RET

; SYS_TWAIT (id 23) — block until timer R1 expires once; consume that
; expiry. Disabled timer: R1 ← $FFFF immediately (amendment G18). The
; poll also watches the enable bit: a one-shot that disarmed itself has
; fired (bq) — no lost-expiry hang. R1 ← 0 on expiry. Clobbers R1, R4, R12.
sys_twait:
    ANDI R1, R1, 1
    LI   R12, 8
    MUL  R4, R1, R12
    LI   R12, (TIMER_A & $FFFF)
    ADD  R4, R4, R12
    LUI  R4, (TIMER_A >> 16)
    LW   R12, [R4 + 4]       ; TxCTRL
    ANDI R12, R12, 1
    BNE  twait_armed
    LI   R1, $FFFF
    RET
twait_armed:
    LI   R12, 1
    SW   [R4 + 6], R12       ; start from a clean flag
twait_poll:
    LW   R12, [R4 + 6]       ; TxSTAT
    ANDI R12, R12, 1
    BNE  twait_done
    LW   R12, [R4 + 4]       ; still armed? (one-shot self-disarm = fired)
    ANDI R12, R12, 1
    BNE  twait_poll
twait_done:
    LI   R12, 1
    SW   [R4 + 6], R12       ; consume the expiry
    LI   R1, 0
    RET

; SYS_GETID (id 24) — R1 ← SYSID register; R2 ← the ROM header version
; word at $FC002 (bq). Clobbers R1, R2, R4.
sys_getid:
    LOAD_ADDR R4, SYSID
    LW   R1, [R4]
    LOAD_ADDR R4, $FC002
    LW   R2, [R4]
    RET

; SYS_RESET (id 25) — soft reset: the full §6.8 boot sequence, again.
; Never returns.
sys_reset:
    JMPA boot

; SYS_IRQSET (id 26) — DISPATCH[R1 & 7] ← R2 (a 20-bit handler address in
; a 4-byte slot); zero uninstalls. Table only — IRQMASK is the program's
; own write (br). Clobbers R1–R4, R12.
sys_irqset:
    ANDI R1, R1, 7
    LI   R12, 2
    SHL  R4, R1, R12
    LI   R12, DISPATCH
    ADD  R4, R4, R12
    SW   [R4], R2            ; bits 15:0
    LI   R12, 16
    SHR  R12, R2, R12
    SW   [R4 + 2], R12       ; bits 19:16
    RET

; SYS_RAND (id 27) — one step of the 16-bit Galois LFSR, taps $B400
; (amendment G18). R1 ← the new state. Clobbers R1, R4, R12.
sys_rand:
    LW   R1, [R0 + RNG_STATE]
    ANDI R12, R1, 1
    LI   R4, 1
    SHR  R1, R1, R4
    CMPI R12, 0
    BEQ  rand_store
    LI   R12, $B400
    XOR  R1, R1, R12
rand_store:
    SW   [R0 + RNG_STATE], R1
    RET

; SYS_SEED (id 28) — seed the LFSR; 0 is coerced to $0001 (a zero LFSR
; never leaves zero — amendment G18). Clobbers R1.
sys_seed:
    ANDI R1, R1, $FFFF
    CMPI R1, 0
    BNE  seed_store
    LI   R1, 1
seed_store:
    SW   [R0 + RNG_STATE], R1
    RET

; SYS_MEMCPY (id 15) — copy R3 bytes from [R1] to [R2]. Forward, byte-wise;
; overlapping moves with dst > src are the caller's problem (as on the real
; machines this imitates). Clobbers R1–R3, R12.
sys_memcpy:
    CMPI R3, 0
    BEQ  memcpy_done
memcpy_loop:
    LB   R12, [R1]
    SB   [R2], R12
    ADDI R1, R1, 1
    ADDI R2, R2, 1
    SUBI R3, R3, 1
    BNE  memcpy_loop
memcpy_done:
    RET

; SYS_MEMSET (id 16) — fill R3 bytes at [R1] with the byte in R2.
; Clobbers R1, R3.
sys_memset:
    CMPI R3, 0
    BEQ  memset_done
memset_loop:
    SB   [R1], R2
    ADDI R1, R1, 1
    SUBI R3, R3, 1
    BNE  memset_loop
memset_done:
    RET

; SYS_MEMCMP (id 17) — compare R3 bytes at [R1] against [R2], unsigned,
; byte-wise. R1 ← 0 equal, 1 first difference greater ([R1] > [R2]),
; $FFFF first difference less (amendment G18). Clobbers R1–R4, R12.
sys_memcmp:
    CMPI R3, 0
    BEQ  memcmp_eq
memcmp_loop:
    LB   R4, [R1]
    LB   R12, [R2]
    CMP  R4, R12
    BNE  memcmp_diff
    ADDI R1, R1, 1
    ADDI R2, R2, 1
    SUBI R3, R3, 1
    BNE  memcmp_loop
memcmp_eq:
    LI   R1, 0
    RET
memcmp_diff:                 ; flags still hold the byte CMP
    BCS  memcmp_gt           ; unsigned ≥ and ≠ ⇒ greater
    LI   R1, $FFFF
    RET
memcmp_gt:
    LI   R1, 1
    RET

; Unimplemented / reserved syscall: return with R1 = $FFFF (decision bj —
; a caller probing a reserved slot gets a recognisable "no" instead of an
; unchanged register).
sys_unimpl:
    LI   R1, $FFFF
    RET

; ----------------------------------------------------------------------------
; Interrupt entry points (minimal until task 12.11's dispatcher).
; ----------------------------------------------------------------------------

; IRQ — the task-12.11 dispatcher (decision br). Saves the handler-
; clobberable set, walks IRQSTAT∧IRQMASK bit 0→7, acks each pending
; source BEFORE calling its DISPATCH-table handler (an edge during the
; handler re-pends instead of vanishing), CALLs installed handlers (they
; end with RET), skips empty slots (the ack alone quiets the line), and
; executes the RTI itself.
irq_entry:
    PUSH R1
    PUSH R2
    PUSH R3
    PUSH R4
    PUSH R12
    PUSH LR
    LOAD_ADDR R4, IRQC
    LW   R1, [R4]            ; IRQSTAT — raw pending
    LW   R12, [R4 + 1]       ; IRQMASK
    AND  R1, R1, R12         ; only the sources asserting the line
    LI   R2, 0               ; source index
irq_scan:
    CMPI R2, 8
    BEQ  irq_done
    LI   R12, 1
    SHL  R12, R12, R2
    AND  R3, R1, R12
    BEQ  irq_next
    LOAD_ADDR R4, IRQC       ; reloaded — handlers may clobber R4
    SW   [R4 + 2], R12       ; IRQACK this source, before its handler
    LI   R3, 2
    SHL  R3, R2, R3
    LI   R12, DISPATCH
    ADD  R3, R3, R12
    LW   R4, [R3 + 2]        ; handler bits 19:16
    LW   R3, [R3]            ; handler bits 15:0
    LI   R12, 16
    SHL  R4, R4, R12
    OR   R3, R3, R4
    CMPI R3, 0
    BEQ  irq_next            ; no handler installed
    PUSH R1                  ; loop state across the user handler
    PUSH R2
    CALL R3
    POP  R2
    POP  R1
irq_next:
    ADDI R2, R2, 1
    JMPA irq_scan
irq_done:
    POP  LR
    POP  R12
    POP  R4
    POP  R3
    POP  R2
    POP  R1
    RTI

; BRK / illegal instruction — resume after the trapping word (D36). A real
; monitor hook can come later; silently continuing matches the trap model.
brk_entry:
    RTI

; ============================================================================
; HID-to-ASCII table (decision bn) — two 128-byte maps, unshifted then
; shifted, indexed by USB HID code (usage page $07). Unmapped codes hold 0.
; Enter ($28) maps to CR so SYS_GETCHAR returns a character for it;
; SYS_GETLINE intercepts Enter and Backspace by scancode before mapping.
; ============================================================================
hid_ascii:
    DB 0, 0, 0, 0                        ; $00–$03 reserved/error codes
    DB "abcdefghijklmnopqrstuvwxyz"      ; $04–$1D
    DB "123456789"                       ; $1E–$26
    DB "0"                               ; $27
    DB $0D, $1B, $08, $09, $20           ; $28 Enter  $29 Esc  $2A BS  $2B Tab  $2C Space
    DB "-=[]"                            ; $2D–$30
    DB $5C                               ; $31 backslash
    DB 0                                 ; $32 Non-US # — unmapped
    DB ";"                               ; $33
    DB $27                               ; $34 apostrophe
    DB "`,./"                            ; $35–$38
    DS 71                                ; $39–$7F unmapped (F-keys, arrows, pad)
hid_ascii_shift:
    DB 0, 0, 0, 0
    DB "ABCDEFGHIJKLMNOPQRSTUVWXYZ"      ; $04–$1D
    DB "!@#$%^&*("                       ; $1E–$26
    DB ")"                               ; $27
    DB $0D, $1B, $08, $09, $20           ; control keys shift-invariant
    DB "_+{}"                            ; $2D–$30
    DB "|"                               ; $31
    DB 0                                 ; $32
    DB ":"                               ; $33
    DB $22                               ; $34 double quote
    DB "~<>?"                            ; $35–$38
    DS 71                                ; $39–$7F unmapped

; ============================================================================
; Embedded data.
; ============================================================================
    INCLUDE "font.inc"
    INCLUDE "palette.inc"

; ============================================================================
; System vectors — Phase 6 §6.7 (16 × 4 B at $FFFC0).
; ============================================================================
    ORG $FFFC0

    DD boot                  ;  0 RESET
    DD 0                     ;  1 NMI (debugger; no hardware source in v1)
    DD irq_entry             ;  2 IRQ (software dispatch, D13)
    DD brk_entry             ;  3 BRK / illegal / privilege
    DD 0, 0, 0, 0            ;  4–7  reserved
    DD 0, 0, 0, 0            ;  8–11 reserved
    DD 0, 0, 0, 0            ; 12–15 reserved
