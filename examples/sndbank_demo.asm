; ============================================================================
; sndbank_demo.asm — load a .flsnd bank off a disk and play it (16.7).
;
;   flommodore --rom rom/flommodore.rom --autoboot examples/sndbank_demo.flapp
;
; The one path nothing else covers end to end: fldisk formats a volume,
; FLFS holds the file, SYS_DSKFIND finds it, SYS_DSKREAD pulls it into RAM,
; and sndlib plays it. Every earlier sound test embedded its bank in the
; program image.
;
; Unlike sndlib_demo this one needs the BIOS, because the storage syscalls
; are where the FDD-1 lives for applications. It runs the cartridge way
; (decision bu): the image sits at $04100 and the §6.9 autoboot scan calls
; it.
;
; What it asserts, beyond "the bytes arrived":
;
;   VWTB = $1119   the wavetable slot resolved to the pool address. Patch 1
;                  uses waveform 6, so snd_init's wtdiv16 and
;                  snd_load_patch's slot arithmetic both have to be right,
;                  and nothing before this has run either.
;   table bytes    $00 / $80 / $FE at offsets 0, 64 and 128 — the triangle
;                  really is in RAM where VWTB points, not merely somewhere
;
; The pool address is fixed by the layout: the bank lands at $11000, its
; header is 16 bytes, three patches are 384, so the wavetable pool starts
; at $11190 and $11190 / 16 = $1119.
; ============================================================================

    SECTION code

    EQU AUR1,        $80100
    EQU SYS_DSKREAD, $FC178      ; $FC100 + 4*30
    EQU SYS_DSKFIND, $FC180      ; $FC100 + 4*32
    EQU SYS_VBLANK,  $FC134      ; $FC100 + 4*13

    EQU DIRBUF,      $10000      ; 512 B, 16-byte aligned, past the program
    EQU BANK,        $11000      ; where the bank is assembled in RAM
    EQU WTPOOL,      $11190      ; BANK + 16 + 3*128

MACRO LOAD_ADDR reg, addr
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO

start:
    ; ---- find DEMOBANK in the FLFS directory ------------------------
    LI   R11, 10
    LOAD_ADDR R1, bankname
    LOAD_ADDR R2, DIRBUF
    CALLA SYS_DSKFIND
    CMPI R1, $FFFF
    BEQ  fail                    ; no disk, or no such file

    LOAD_ADDR R5, DIRBUF
    ADD  R5, R5, R1              ; R5 = the directory entry, read in place
    LW   R6, [R5 + $0E]          ; start LBA
    LW   R7, [R5 + $10]          ; sector count
    LOAD_ADDR R8, BANK

    ; ---- pull it in a sector at a time ------------------------------
    LI   R11, 11
read_loop:
    CMPI R7, 0
    BEQ  read_done
    MOV  R1, R6
    MOV  R2, R8
    CALLA SYS_DSKREAD
    CMPI R1, 0
    BNE  fail
    ADDI R6, R6, 1
    ADDI R8, R8, 512             ; a multiple of 16, so alignment holds
    SUBI R7, R7, 1
    JMPA read_loop
read_done:

    ; ---- hand it to sndlib ------------------------------------------
    LI   R11, 12
    LOAD_ADDR R1, BANK
    CALLA snd_init               ; also checks the 'FS' magic survived
    CMPI R1, 0
    BNE  fail

    LI   R11, 13
    LI   R1, 1                   ; patch 1 — "WAVE TRIANGLE"
    CALLA snd_load_patch
    CMPI R1, 0
    BNE  fail

    ; ---- the wavetable path, which nothing else reaches -------------
    ;
    ; These checks REPORT THE BYTE THEY SAW. A bare "check 1 failed" says
    ; only that something is wrong; the value says which thing. Each one
    ; fails with R11 = (check << 8) | observed, so the harness prints
    ; check #$01xx and the low byte is the register's actual content.
    ; Checks 10-14 stay plain small numbers, so the two are never confused.
    LOAD_ADDR R4, AUR1
    LI   R11, $0100
    LB   R1, [R4 + $02]          ; VWAVE — waveform 6, from the disk
    CMPI R1, $06
    BEQ  ck_vwtblo
    OR   R11, R11, R1
    JMPA fail
ck_vwtblo:
    LI   R11, $0200
    LB   R1, [R4 + $0B]          ; VWTBLO — slot 0 -> $11190 / 16
    CMPI R1, $19
    BEQ  ck_vwtbhi
    OR   R11, R11, R1
    JMPA fail
ck_vwtbhi:
    LI   R11, $0300
    LB   R1, [R4 + $0C]          ; VWTBHI
    CMPI R1, $11
    BEQ  ck_wt0
    OR   R11, R11, R1
    JMPA fail

    ; …and the table really is there. Three points of the triangle:
    ; the start, the peak's midpoint, and the turn.
ck_wt0:
    LOAD_ADDR R4, WTPOOL
    LI   R11, $0400
    LB   R1, [R4]
    CMPI R1, $00
    BEQ  ck_wt64
    OR   R11, R11, R1
    JMPA fail
ck_wt64:
    LI   R11, $0500
    LB   R1, [R4 + 64]
    CMPI R1, $80
    BEQ  ck_wt128
    OR   R11, R11, R1
    JMPA fail
ck_wt128:
    LI   R11, $0600
    LB   R1, [R4 + 128]
    CMPI R1, $FE
    BEQ  ck_done
    OR   R11, R11, R1
    JMPA fail

    ; Two more, to separate "the copy is wrong" from "the bank is not
    ; where snd_init thinks". Read the patch bytes straight out of RAM:
    ; if these are right but VWAVE was not, the fault is in the copy.
ck_done:
    LOAD_ADDR R4, BANK
    LI   R11, $0700
    LB   R1, [R4 + 146]          ; patch 1 VWAVE, as it sits in RAM
    CMPI R1, $06
    BEQ  ck_ram2
    OR   R11, R11, R1
    JMPA fail
ck_ram2:
    LI   R11, $0800
    LB   R1, [R4 + 4]            ; bank header patch count
    CMPI R1, $03
    BEQ  ck_ram_ok
    OR   R11, R11, R1
    JMPA fail
ck_ram_ok:

    ; ---- sound it ---------------------------------------------------
    LI   R11, 14
    LI   R1, 0                   ; voice 0
    LI   R2, 57                  ; A4
    CALLA snd_note_on
    CMPI R1, 0
    BNE  fail

    LI   R6, 4
hold:
    CALLA SYS_VBLANK
    SUBI R6, R6, 1
    BNE  hold

    LI   R1, 0
    CALLA snd_note_off
    CALLA SYS_VBLANK

    LI   R11, $600D
    SW   [R0 + $80], R11
parked:
    HLT
    JMPA parked                  ; BIOS IRQs wake HLT; re-park

fail:
    SW   [R0 + $84], R11
    LI   R11, $0BAD
    SW   [R0 + $80], R11
fail_parked:
    HLT
    JMPA fail_parked

    SECTION data

bankname:
    DB "DEMOBANK", 0
