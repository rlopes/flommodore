; hello.asm — the first real Flommodore program (Block 11, task 11.12).
;
; The relocatable, script-linked hello: SECTION-based source assembled by
; flas, placed by examples/hello.flld, linked by fll into hello.flapp.
; It deliberately exercises every cross-section mechanism the linker
; resolves: LO16/HI4 register loads into data and bss, an ABS26 CALLA,
; an ABS32 data pointer back into code, and folded same-section branches.
;
; The BIOS syscalls (SYS_PUTSTR et al.) arrive with the Block 12 ROM, so
; this program prints the pre-BIOS way: it configures the VIC-256 for
; 640x360 text mode and writes 2-byte cells (char, attr) into the text
; matrix directly. Text mode fetches its font from the ROM at $FE000
; (Phase 6 6.1), which a bare .flapp cannot provide - run it with the
; font companion image, the 8.10 combined invocation:
;
;   flommodore --rom tests/roms/font.rom examples/hello.flapp
;
; (The absolute, syscall-based hello of Phase 8 8.3 lives on unchanged
; in tests/asm/hello.asm as the Block 10 listing fixture; it runs as
; published once the Block 12 BIOS ROM exists.)

    SECTION code

    ; VIC-256 register base (Phase 3) and the BIOS RAM conventions the
    ; toolchain examples follow (amendment G17): palette $02100, text
    ; matrix $02600.
    EQU VIC,   $80200
    EQU PAL,   $02100
    EQU CELL0, $02748        ; $02600 + 2*(row 2 * 80 cols + col 4)

start:
    ; R1 = VIC register base. VIC is an EQU constant, so both halves
    ; fold at assembly - no relocation.
    LI   R1, (VIC & $FFFF)
    LUI  R1, (VIC >> 16)

    ; Base registers hold address/16 in a lo/hi byte pair.
    LI   R4, $10
    SB   [R1 + $0B], R4      ; VPALBASE lo   ($02100/16 = $0210)
    LI   R4, $02
    SB   [R1 + $0C], R4      ; VPALBASE hi
    LI   R4, $60
    SB   [R1 + $0F], R4      ; VTMAPBASE lo  ($02600/16 = $0260)
    LI   R4, $02
    SB   [R1 + $10], R4      ; VTMAPBASE hi
    LI   R4, 1
    SB   [R1 + $02], R4      ; VRESX = 640
    SB   [R1 + $03], R4      ; VRESY = 360  (80x45 text cells)
    LI   R4, 3
    SB   [R1 + $00], R4      ; VMODE = text - mode last, bases first

    ; Palette entry 0 = (0, 0, 96) deep blue, entry 1 = (255, 255, 255)
    ; white. Cells are (char, attr) with fg = attr[3:0], bg = attr[7:4];
    ; RAM powers up zeroed, so every untouched cell shows entry 0.
    LI   R2, PAL
    LI   R4, 0
    SB   [R2 + 0], R4
    SB   [R2 + 1], R4
    LI   R4, 96
    SB   [R2 + 2], R4
    LI   R4, 255
    SB   [R2 + 3], R4
    SB   [R2 + 4], R4
    SB   [R2 + 5], R4

    ; Print msg at row 2, col 4. The two register loads are the LO16 and
    ; HI4 relocations into the data section; the CALLA is an ABS26 (J-
    ; format targets are absolute, so even a same-section call relocates).
    LI   R2, (msg & $FFFF)
    LUI  R2, (msg >> 16)
    LI   R3, CELL0
    CALLA puts

    ; Raise the done flag in bss (LO16/HI4 into a NOLOAD section), halt.
    ; A late device IRQ wakes HLT, so park in a loop (the genroms idiom).
    LI   R2, (done & $FFFF)
    LUI  R2, (done >> 16)
    LI   R4, 1
    SB   [R2], R4
parked:
    HLT
    JMPA parked

; puts - write the NUL-terminated string at R2 into 2-byte text cells at
; R3, attribute $01 (fg = palette 1, bg = palette 0). Clobbers R2-R5.
; The BEQ folds at assembly (same-section, PC-relative); the JMPA back
; is another ABS26 for the relocator.
puts:
    LI   R5, $01
puts_loop:
    LB   R4, [R2]
    CMPI R4, 0
    BEQ  puts_done
    SB   [R3 + 0], R4
    SB   [R3 + 1], R5
    ADDI R2, R2, 1
    ADDI R3, R3, 2
    JMPA puts_loop
puts_done:
    RET

    SECTION data
msg:
    DB "HELLO, FLOMMODORE!", 0
entry_ptr:
    DD start                 ; ABS32 - a data-to-code reference

    SECTION bss
done:
    DS 4
