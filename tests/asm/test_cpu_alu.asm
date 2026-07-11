; test_cpu_alu.asm — Block 10 end-to-end acceptance: a source rewrite of
; the genroms buildAlu ROM (plan tasks 3.6–3.8), assembled by flas and
; byte-compared against the generated original (tests/cmprom.zig).
;
; Layout mirrors the genroms Kit: main code at $FC200, the shared FAIL
; stub at $FD000, the vector table at $FFFC0 (RESET -> start, BRK ->
; fail). Kit.assertTaken(op) is "op over a JMPA fail" (raw offset +4);
; Kit.assertNotTaken(op) branches to fail directly. R11 carries the
; check number; R12 is scratch.

    EQU RESULT,  $00080
    EQU FAILNUM, $00084

    ORG $FC200
start:
    ; 1: ADD.
    LI   R1, 2
    LI   R2, 3
    ADD  R3, R1, R2
    LI   R11, 1
    CMPI R3, 5
    BEQ  ok1
    JMPA fail
ok1:
    ; 2: ADD carry keeps bit 16 in the 20-bit register.
    LI   R1, $FFFF
    ADD  R3, R1, R1          ; $1FFFE, C=1
    LI   R11, 2
    BCS  ok2
    JMPA fail
ok2:
    LI   R11, 3
    CMPI R3, -2              ; low16 $FFFE
    BEQ  ok3
    JMPA fail
ok3:
    LI   R12, 8
    SHR  R4, R3, R12
    SHR  R4, R4, R12
    LI   R11, 4
    CMPI R4, 1               ; bit 16 survived
    BEQ  ok4
    JMPA fail
ok4:
    ; 3: SUB borrow (1-2): C=0, result low16 $FFFF.
    LI   R1, 1
    SUBI R3, R1, 2
    LI   R11, 5
    BCS  fail
    LI   R11, 6
    CMPI R3, -1
    BEQ  ok6
    JMPA fail
ok6:
    ; 4: logic + NOT.
    LI   R1, $0F0F
    LI   R2, $00FF
    AND  R3, R1, R2
    LI   R11, 7
    CMPI R3, $000F
    BEQ  ok7
    JMPA fail
ok7:
    OR   R3, R1, R2
    LI   R11, 8
    CMPI R3, $0FFF
    BEQ  ok8
    JMPA fail
ok8:
    XOR  R3, R1, R1
    LI   R11, 9
    BEQ  ok9                 ; Z set
    JMPA fail
ok9:
    LI   R1, 0
    NOT  R3, R1
    LI   R11, 10
    CMPI R3, -1              ; low16 $FFFF (full value $FFFFF)
    BEQ  ok10
    JMPA fail
ok10:
    ; 5: MUL low 16: $100 * $300 -> 0, Z=1.
    LI   R1, $100
    LI   R2, $300
    MUL  R3, R1, R2
    LI   R11, 11
    BEQ  ok11
    JMPA fail
ok11:
    ; 6: DIV/MOD.
    LI   R1, 100
    LI   R2, 7
    DIV  R3, R1, R2
    LI   R11, 12
    CMPI R3, 14
    BEQ  ok12
    JMPA fail
ok12:
    MOD  R3, R1, R2
    LI   R11, 13
    CMPI R3, 2
    BEQ  ok13
    JMPA fail
ok13:
    ; 7: divide by zero -> $FFFF, V=1.
    DIV  R3, R1, R0
    LI   R11, 14
    CMPI R3, -1
    BEQ  ok14
    JMPA fail
ok14:
    ; 8: shifts - SHL carry, ASR sign behaviour.
    LI   R1, $8000
    LI   R2, 1
    SHL  R3, R1, R2          ; $10000: C=1, low16 0 -> Z=1
    LI   R11, 15
    BCS  ok15
    JMPA fail
ok15:
    LI   R11, 16
    BEQ  ok16
    JMPA fail
ok16:
    LI   R1, -4              ; $FFFFC
    ASR  R3, R1, R2          ; 16-bit signed: $FFFC asr 1 = $FFFE
    LI   R11, 17
    CMPI R3, -2
    BEQ  ok17
    JMPA fail
ok17:
    ; PASS: write $600D and halt in a loop (device IRQs wake HLT).
    LI   R11, $600D
    SW   [R0 + RESULT], R11
pass_hlt:
    HLT
    JMPA pass_hlt

    ORG $FD000
fail:
    SW   [R0 + FAILNUM], R11
    LI   R11, $0BAD
    SW   [R0 + RESULT], R11
fail_hlt:
    HLT
    JMPA fail_hlt

    ORG $FFFC0               ; system vectors (raw 32-bit LE addresses)
    DD start                 ; 0: RESET
    DD 0, 0                  ; 1: NMI, 2: IRQ (unset)
    DD fail                  ; 3: BRK -> visible $0BAD, not a trap storm
