; hello.asm — print "HELLO" to the screen via BIOS system call

    ORG $04100          ; start of free RAM

    EQU SYS_PUTSTR, $FC104
    EQU SYS_GETKEY, $FC118

start:
    LI    R1, msg       ; R1 = address of string
    CALLA SYS_PUTSTR    ; call BIOS print string
    CALLA SYS_GETKEY    ; wait for a keypress
    HLT                 ; halt

msg:
    DB "HELLO, FLOMMODORE!", 0   ; null-terminated string
