; ============================================================================
; storage.inc — FDD-1 system calls for the Flommodore BIOS (Block 15).
;
; Included by bios.asm at kernel scope, so the EQU constants it relies on
; (STOR, FLFS_DIRLBA, FLFS_ENTRIES, FLFS_ENTSZ) and the register conventions
; of decision be are already in force: arguments in R1-R3, result in R1,
; callers may lose R1-R4 and R12.
;
; Implements amendment v1.3 §4.1 ids 29-32; id 33 (SYS_DSKCREAT) and the
; LOAD/SAVE shell commands follow in the next commit.
; ============================================================================

; SYS_DSKSTAT (id 29) — R1 ← STSTAT, R2 ← STERR. Cannot fail: with no media
; STSTAT reads $0000, and any command would then complete with STERR 1.
; Clobbers R1, R2, R4.
sys_dskstat:
    LI   R4, (STOR & $FFFF)
    LUI  R4, (STOR >> 16)
    LW   R1, [R4 + 1]        ; STSTAT
    LW   R2, [R4 + 5]        ; STERR
    RET

; SYS_DSKREAD (id 30) — sector R1 → buffer [R2]. R1 ← 0 ok / $FFFF error.
sys_dskread:
    LI   R3, 1
    JMPA stor_xfer

; SYS_DSKWRITE (id 31) — buffer [R2] → sector R1. R1 ← 0 ok / $FFFF error.
sys_dskwrite:
    LI   R3, 2
    JMPA stor_xfer

; Shared transfer tail: R1 = LBA, R2 = buffer address, R3 = STCMD command.
; Entered by JMPA, not CALL — LR still points at the syscall's own caller, so
; the RET below returns straight there with no PUSH LR bookkeeping.
;
; The buffer must be 16-byte aligned because STBUF counts 16-byte units; a
; misaligned address simply cannot be expressed, and rounding it down would
; silently transfer to the wrong place. Note this returns $FFFF WITHOUT
; setting STERR 4 — the kernel cannot write STERR, which is read-only, so
; v1.3 §4.1's claim that it does is wrong (correction folded into the doc).
; Clobbers R1-R4, R12.
stor_xfer:
    ANDI R12, R2, $000F
    CMPI R12, 0
    BNE  stor_fail
    LI   R4, (STOR & $FFFF)
    LUI  R4, (STOR >> 16)
    SW   [R4 + 2], R1        ; STLBA
    LI   R12, 4
    SHR  R2, R2, R12         ; buffer ÷ 16
    SW   [R4 + 3], R2        ; STBUF
    SW   [R4 + 0], R3        ; STCMD — busy for exactly 2,000 cycles (D52)
stor_wait:
    LW   R12, [R4 + 1]       ; STSTAT
    ANDI R12, R12, 1
    BNE  stor_wait           ; every accepted command completes (§2.5): no hang
    LW   R1, [R4 + 5]        ; STERR
    CMPI R1, 0
    BNE  stor_fail
    LI   R1, 0
    RET
stor_fail:
    LI   R1, $FFFF
    RET

; SYS_DSKFIND (id 32) — look up the NUL-terminated name at [R1] in the FLFS
; directory. R2 = 512-byte, 16-byte-aligned scratch, which receives sector 1.
; R1 ← byte offset of the matching entry within that scratch, or $FFFF.
; Returning an offset rather than copying the entry means the caller reads it
; in place: no second buffer, no fixed-size copy.
;
; Names compare case-insensitively over all 12 bytes, with the wanted name's
; terminator standing in for the entry's trailing spaces — so "AURED" matches
; the stored "AURED       ". Clobbers R1-R6, R12.
sys_dskfind:
    PUSH LR
    PUSH R5
    PUSH R6
    MOV  R5, R2              ; scratch base, must survive the read
    MOV  R6, R1              ; wanted name
    LI   R1, FLFS_DIRLBA
    CALLA sys_dskread
    CMPI R1, 0
    BNE  find_fail
    LI   R3, 0               ; entry index
find_entry:
    LI   R12, FLFS_ENTSZ
    MUL  R4, R3, R12
    ADD  R4, R4, R5          ; R4 = entry address
    LB   R12, [R4]
    CMPI R12, 0
    BEQ  find_fail           ; $00 ends the directory (§3)
    CMPI R12, $E5
    BEQ  find_next           ; deleted slot
    PUSH R6                  ; walking copy of the wanted name
    LI   R1, 0               ; byte index
find_byte:
    LB   R2, [R4]            ; entry character
    LB   R12, [R6]           ; wanted character
    CMPI R12, 0
    BNE  find_have
    LI   R12, $20            ; terminator → space
find_have:
    CMPI R12, $61            ; 'a'
    BCC  find_nolower
    CMPI R12, $7B            ; past 'z'?
    BCS  find_nolower
    SUBI R12, R12, $20       ; fold to upper case
find_nolower:
    CMP  R2, R12
    BNE  find_mismatch
    ADDI R4, R4, 1
    LB   R12, [R6]
    CMPI R12, 0
    BEQ  find_adv            ; name exhausted: keep matching against spaces
    ADDI R6, R6, 1
find_adv:
    ADDI R1, R1, 1
    CMPI R1, 12
    BNE  find_byte
    POP  R6
    LI   R12, FLFS_ENTSZ
    MUL  R1, R3, R12         ; R1 = offset of the match
    JMPA find_done
find_mismatch:
    POP  R6
find_next:
    ADDI R3, R3, 1
    CMPI R3, FLFS_ENTRIES
    BNE  find_entry
find_fail:
    LI   R1, $FFFF
find_done:
    POP  R6
    POP  R5
    POP  LR
    RET
