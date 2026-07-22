; bios_hello.asm — hello, the BIOS-era way (Block 12 follow-up).
;
; Where examples/hello.asm predates the firmware and drives the VIC-256
; registers itself, this one is an ordinary Flommodore PROGRAM: it talks
; to the machine through the §6.4 system-call jump table and lets the
; BIOS own the screen. Build and run it the way a player would — insert
; the cartridge, power on:
;
;   zig build examples
;   ./zig-out/bin/flommodore --rom rom/flommodore.rom --autoboot examples/bios_hello.flapp
;
; The BIOS boots, prints its banner, finds this program's FB header at
; $04100 (§6.9), and CALLs the entry point. The program prints through
; SYS_PUTSTR and ends with RET — dropping straight back to the READY.
; shell (decision bs). You can also start it by hand: boot the bare ROM
; is not enough (nothing loads it into RAM), but under --autoboot the
; shell is still yours after the program returns — try RUN 4100 to run
; it again.
;
; Syscall convention (decision be): arguments in R1–R3, result in R1;
; a program may clobber R1–R4 and R12 and must preserve the rest. One
; thing it MUST save is its own return address: CALLA writes LR, so a
; program that was CALLed (autoboot, RUN) and calls anything itself has
; to PUSH LR first or its final RET jumps back into itself.

    SECTION code

    ; The permanent public ABI (§6.4): entry for syscall id N sits at
    ; exactly $FC100 + 4×N. These two are all this program needs.
    EQU SYS_PUTSTR, $FC104   ; id 1: print the NUL-terminated string at [R1]

start:
    PUSH  LR                 ; CALLA below clobbers LR — keep the way home
    LI    R1, (msg & $FFFF)  ; 20-bit address of the string, two halves
    LUI   R1, (msg >> 16)    ; (amendment §1.2 register-load idiom)
    CALLA SYS_PUTSTR
    POP   LR
    RET                      ; back to the BIOS: READY.

    SECTION data
msg:
    DB "HELLO FROM AUTOBOOT!", $0A
    DB "THIS PROGRAM RETURNED TO THE SHELL - TRY: RUN 4100", $0A, 0
