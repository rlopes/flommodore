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

    JMPA sys_unimpl          ;  0 SYS_PUTCHAR
    JMPA sys_unimpl          ;  1 SYS_PUTSTR
    JMPA sys_unimpl          ;  2 SYS_CLRSCR
    JMPA sys_unimpl          ;  3 SYS_SETCURSOR
    JMPA sys_unimpl          ;  4 SYS_SETCOLOR
    JMPA sys_unimpl          ;  5 SYS_SCROLL
    JMPA sys_unimpl          ;  6 SYS_GETKEY
    JMPA sys_unimpl          ;  7 SYS_POLLKEY
    JMPA sys_unimpl          ;  8 SYS_GETCHAR
    JMPA sys_unimpl          ;  9 SYS_GETLINE
    JMPA sys_unimpl          ; 10 SYS_SETMODE
    JMPA sys_unimpl          ; 11 SYS_SETPAL
    JMPA sys_unimpl          ; 12 SYS_LOADPAL
    JMPA sys_unimpl          ; 13 SYS_VBLANK
    JMPA sys_unimpl          ; 14 SYS_FILLSCR
    JMPA sys_memcpy          ; 15 SYS_MEMCPY
    JMPA sys_memset          ; 16 SYS_MEMSET
    JMPA sys_unimpl          ; 17 SYS_MEMCMP
    JMPA sys_unimpl          ; 18 SYS_SNDINIT
    JMPA sys_unimpl          ; 19 SYS_SNDPLAY
    JMPA sys_unimpl          ; 20 SYS_SNDSTOP
    JMPA sys_unimpl          ; 21 SYS_SNDVOL
    JMPA sys_unimpl          ; 22 SYS_TSET
    JMPA sys_unimpl          ; 23 SYS_TWAIT
    JMPA sys_unimpl          ; 24 SYS_GETID
    JMPA sys_unimpl          ; 25 SYS_RESET
    JMPA sys_unimpl          ; 26 SYS_IRQSET
    JMPA sys_unimpl          ; 27 SYS_RAND
    JMPA sys_unimpl          ; 28 SYS_SEED
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

    ; Stages 5–6 (banner, IRQ enable, autoboot) arrive with tasks 12.5+.
    ; For now the shell entry is a parked halt loop — task 12.1's
    ; acceptance is that the CPU reaches this point with the environment
    ; established. A device IRQ would wake HLT, hence the loop.
shell_entry:
    HLT
    JMPA shell_entry

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

    ; AUR-1: everything silent — master volume 0, no voices routed, all
    ; gates off, envelope IRQ disabled, ASTAT cleared.
    LOAD_ADDR R4, AUR
    SB   [R4 + $40], R0      ; AMVOL  = 0
    SB   [R4 + $43], R0      ; AMVOICE = 0
    SB   [R4 + $4A], R0      ; AIRQEN = 0
    SB   [R4 + $03], R0      ; voice 0 gate off
    SB   [R4 + $13], R0      ; voice 1
    SB   [R4 + $23], R0      ; voice 2
    SB   [R4 + $33], R0      ; voice 3
    LI   R12, $FF
    SB   [R4 + $4B], R12     ; ASTAT w1c

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
    RET

; ----------------------------------------------------------------------------
; System calls (Phase 6 §6.4). Implementations arrive block by block; every
; jump-table slot without one lands on sys_unimpl.
; ----------------------------------------------------------------------------

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

; Unimplemented / reserved syscall: return with R1 = $FFFF (decision bj —
; a caller probing a reserved slot gets a recognisable "no" instead of an
; unchanged register).
sys_unimpl:
    LI   R1, $FFFF
    RET

; ----------------------------------------------------------------------------
; Interrupt entry points (minimal until task 12.11's dispatcher).
; ----------------------------------------------------------------------------

; IRQ — acknowledge every pending source so a level-triggered line cannot
; storm, preserve everything, return. The real dispatch-table walker
; replaces the body in task 12.11.
irq_entry:
    PUSH R1
    PUSH R2
    LOAD_ADDR R1, IRQC
    LW   R2, [R1]            ; IRQSTAT
    SW   [R1 + 2], R2        ; IRQACK ← everything pending
    POP  R2
    POP  R1
    RTI

; BRK / illegal instruction — resume after the trapping word (D36). A real
; monitor hook can come later; silently continuing matches the trap model.
brk_entry:
    RTI

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
