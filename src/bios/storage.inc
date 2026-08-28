; ============================================================================
; storage.inc — FDD-1 system calls for the Flommodore BIOS (Block 15).
;
; Included by bios.asm at kernel scope, so the EQU constants it relies on
; (STOR, FLFS_DIRLBA, FLFS_ENTRIES, FLFS_ENTSZ) and the register conventions
; of decision be are already in force: arguments in R1-R3, result in R1,
; callers may lose R1-R4 and R12.
;
; Implements amendment v1.3 §4.1 ids 29-33, plus the §4.2 LOAD and §4.3 SAVE
; shell commands (bios.asm's command table dispatches to stor_load and
; stor_save).
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

; ============================================================================
; Directory allocation and the LOAD / SAVE shell commands (v1.3 §4.1 id 33,
; §4.2, §4.3). D57 was reversed once task 13.4 measured the ROM budget: one
; allocator in kernel ROM beats one per application.
; ============================================================================

; The kernel's 512-byte disk buffer. SATRAM is borrowed deliberately: it is
; exactly one sector, 16-byte aligned, and dead at the shell prompt — boot
; leaves VSPRENA = 0 and text mode has no sprites. LOAD does NOT use it (it
; stages through $04100, which the program is about to overwrite anyway),
; but SAVE must not scribble on the data it is saving.
    EQU DIRBUF, SATRAM

; SYS_DSKCREAT (id 33) — allocate a file. R1 = NUL-terminated name,
; R2 = 512-byte 16-byte-aligned scratch, R3 = sector count. R1 ← byte offset
; of the new entry within the scratch, or $FFFF on a duplicate name, a full
; directory, an out-of-space volume, or an I/O error.
;
; FLFS v1 never reclaims deleted space (D55), so allocation is a bump
; allocator: the new run starts immediately above the highest start+count in
; use, with sector 2 as the floor (0 is the volume header, 1 the directory).
; A deleted slot is reused for the ENTRY, but never for its sectors.
;
; The directory is committed before returning, so the caller only has to
; write its data. Clobbers R1-R4, R12; R5-R10 saved.
sys_dskcreat:
    PUSH LR
    PUSH R5
    PUSH R6
    PUSH R7
    PUSH R8
    PUSH R9
    PUSH R10
    MOV  R5, R2              ; scratch
    MOV  R6, R1              ; name
    MOV  R7, R3              ; wanted sector count
    ANDI R12, R5, $000F
    CMPI R12, 0
    BNE  creat_fail          ; scratch must be 16-byte aligned
    CMPI R7, 0
    BEQ  creat_fail          ; a zero-sector file is not a file

    ; Volume header (sector 0) → total sectors, so the space check below is
    ; against the volume rather than the 16-bit LBA ceiling.
    LI   R1, 0
    MOV  R2, R5
    CALLA sys_dskread
    CMPI R1, 0
    BNE  creat_fail
    LW   R8, [R5 + 6]        ; +06 total sectors on the volume

    ; Duplicate name? DSKFIND leaves the directory in the scratch, so this
    ; doubles as the directory read.
    MOV  R1, R6
    MOV  R2, R5
    CALLA sys_dskfind
    CMPI R1, $FFFF
    BNE  creat_fail          ; the name already exists

    ; Scan every slot: remember the first free one, and track the highest
    ; start+count so the new run lands past all live files.
    LI   R9, $FFFF           ; no free slot yet
    LI   R10, 2              ; data floor: past header + directory
    LI   R4, 0
creat_scan:
    LI   R12, FLFS_ENTSZ
    MUL  R1, R4, R12
    ADD  R1, R1, R5          ; R1 = entry address
    LB   R12, [R1]
    CMPI R12, 0
    BEQ  creat_take          ; $00 — never used
    CMPI R12, $E5
    BEQ  creat_take          ; deleted — the slot is reusable
    LW   R2, [R1 + $0E]      ; start LBA
    LW   R3, [R1 + $10]      ; sector count
    ADD  R2, R2, R3          ; one past the end of this file
    CMP  R2, R10
    BCC  creat_next          ; below the high-water mark
    MOV  R10, R2
    JMPA creat_next
creat_take:
    CMPI R9, $FFFF
    BNE  creat_next          ; already have a slot; keep scanning for ends
    LI   R12, FLFS_ENTSZ
    MUL  R9, R4, R12
creat_next:
    ADDI R4, R4, 1
    CMPI R4, FLFS_ENTRIES
    BNE  creat_scan

    CMPI R9, $FFFF
    BEQ  creat_fail          ; directory full
    ADD  R1, R10, R7         ; one past the new run
    ADDI R2, R8, 1
    CMP  R1, R2
    BCS  creat_fail          ; start + count > total sectors

    ; Fill the entry: 12-byte name, space-padded and upper-cased, then the
    ; fixed fields. R4 walks from the name into the rest of the record.
    ADD  R4, R9, R5
    LI   R1, 0
creat_name:
    LB   R12, [R6]
    CMPI R12, 0
    BNE  creat_name_have
    LI   R12, $20            ; terminator → pad with spaces
    JMPA creat_name_store
creat_name_have:
    CMPI R12, $61            ; 'a'
    BCC  creat_name_store
    CMPI R12, $7B            ; past 'z'?
    BCS  creat_name_store
    SUBI R12, R12, $20
creat_name_store:
    SB   [R4], R12
    ADDI R4, R4, 1
    LB   R12, [R6]
    CMPI R12, 0
    BEQ  creat_name_next     ; name exhausted: keep padding, stop advancing
    ADDI R6, R6, 1
creat_name_next:
    ADDI R1, R1, 1
    CMPI R1, 12
    BNE  creat_name
    ; R4 now points at +$0C of the entry.
    LI   R12, $5444          ; 'D','T' little-endian — raw data by default
    SW   [R4], R12           ; +$0C type
    SW   [R4 + 2], R10       ; +$0E start LBA
    SW   [R4 + 4], R7        ; +$10 sector count
    LI   R12, 9
    SHL  R1, R7, R12
    SW   [R4 + 6], R1        ; +$12 byte length = count × 512, low half
    LI   R12, 7
    SHR  R1, R7, R12
    SW   [R4 + 8], R1        ;     …and high half
    SW   [R4 + 10], R0       ; +$16 flags: writable
    SW   [R4 + 12], R0       ; +$18 reserved — a reused slot may be dirty
    SW   [R4 + 14], R0
    SW   [R4 + 16], R0
    SW   [R4 + 18], R0

    LI   R1, FLFS_DIRLBA     ; commit the directory before returning
    MOV  R2, R5
    CALLA sys_dskwrite
    CMPI R1, 0
    BNE  creat_fail
    MOV  R1, R9
    JMPA creat_done
creat_fail:
    LI   R1, $FFFF
creat_done:
    POP  R10
    POP  R9
    POP  R8
    POP  R7
    POP  R6
    POP  R5
    POP  LR
    RET

; token_end — NUL-terminate the token at the shell cursor R5, leaving the
; cursor on the terminator so parse_hex can carry on from there. Destructive
; on LINEBUF, which is the shell's own scratch. Clobbers R3.
token_end:
    LB   R3, [R5]
    CMPI R3, 0
    BEQ  te_done
    CMPI R3, $20
    BEQ  te_cut
    ADDI R5, R5, 1
    JMPA token_end
te_cut:
    SB   [R5], R0
te_done:
    RET

; LOAD name (v1.3 §4.2) — find the file, read it to $04100, validate the
; §6.9 FB header, and CALL it. A program ending in RET drops back to READY,
; exactly as RUN and autoboot do (decision bs).
;
; The directory is staged through $04100 itself: it is 16-byte aligned and
; about to be overwritten by the program, so LOAD costs the kernel no RAM.
; The start LBA and sector count are pulled into registers BEFORE the first
; sector read, because that read overwrites the directory they came from.
;
; DECISION: LOAD requires the header's load address to be the canonical
; $04100 (D10) — the address fll's default script produces and the only one
; autoboot can use either. Reading a file to $04100 and then jumping to some
; other load address would execute whatever happened to be there, so a
; mismatch earns a diagnostic instead.
stor_load:
    CALLA skip_spaces
    LB   R1, [R5]
    CMPI R1, 0
    BEQ  shell_syntax        ; LOAD with no name
    MOV  R6, R5
    CALLA token_end
    MOV  R1, R6
    LI   R2, $4100
    CALLA sys_dskfind
    CMPI R1, $FFFF
    BEQ  load_notfound
    LI   R12, $4100
    ADD  R6, R1, R12         ; R6 = the entry, read in place
    LW   R1, [R6 + $0C]
    CMPI R1, $5041           ; 'A','P' little-endian
    BNE  load_badtype
    LW   R7, [R6 + $0E]      ; start LBA
    LW   R8, [R6 + $10]      ; sector count
    LI   R6, $4100           ; destination cursor (512 is a multiple of 16)
load_sector:
    CMPI R8, 0
    BEQ  load_check
    MOV  R1, R7
    MOV  R2, R6
    CALLA sys_dskread
    CMPI R1, 0
    BNE  load_ioerr
    ADDI R7, R7, 1
    ADDI R6, R6, 512
    SUBI R8, R8, 1
    JMPA load_sector
load_check:
    LI   R6, $4100
    LB   R1, [R6]
    CMPI R1, $46             ; 'F'
    BNE  load_badhdr
    LB   R1, [R6 + 1]
    CMPI R1, $42             ; 'B'
    BNE  load_badhdr
    LW   R1, [R6 + 4]        ; entry offset
    CMPI R1, 12
    BCC  load_badhdr         ; inside the header
    LW   R2, [R6 + 8]        ; load address, 32-bit LE
    LW   R3, [R6 + 10]
    CMPI R3, 0
    BNE  load_badaddr
    CMPI R2, $4100
    BNE  load_badaddr
    ADD  R1, R1, R2
    CALL R1
    JMPA shell_loop
load_notfound:
    LOAD_ADDR R1, str_nofile
    CALLA sys_putstr
    JMPA shell_loop
load_badtype:
    LOAD_ADDR R1, str_notprog
    CALLA sys_putstr
    JMPA shell_loop
load_badhdr:
    LOAD_ADDR R1, str_badboot
    CALLA sys_putstr
    JMPA shell_loop
load_badaddr:
    LOAD_ADDR R1, str_badaddr
    CALLA sys_putstr
    JMPA shell_loop
load_ioerr:
    LOAD_ADDR R1, str_diskerr
    CALLA sys_putstr
    JMPA shell_loop

; SAVE name addr len (v1.3 §4.3) — allocate through SYS_DSKCREAT, then write
; the data. The final sector is staged through DIRBUF so it is zero-padded
; rather than carrying whatever followed the data in RAM.
;
; The source address must be 16-byte aligned: whole sectors are written
; straight from it, and STBUF counts 16-byte units. R9 holds the new entry
; across the DSKWRITE calls — decision be preserves R5-R11 through syscalls.
stor_save:
    CALLA skip_spaces
    LB   R1, [R5]
    CMPI R1, 0
    BEQ  shell_syntax        ; SAVE with no name
    MOV  R6, R5
    CALLA token_end
    CALLA parse_hex          ; source address
    CMPI R2, 0
    BEQ  shell_syntax
    MOV  R7, R1
    CALLA parse_hex          ; byte length
    CMPI R2, 0
    BEQ  shell_syntax
    CMPI R1, 0
    BEQ  shell_syntax        ; a zero-length file is not a file
    MOV  R8, R1
    ANDI R12, R7, $000F
    CMPI R12, 0
    BNE  save_badaddr
    ADDI R1, R8, 511         ; sectors = ceil(len / 512)
    LI   R12, 9
    SHR  R3, R1, R12
    MOV  R1, R6
    LI   R2, DIRBUF
    CALLA sys_dskcreat
    CMPI R1, $FFFF
    BEQ  save_failed
    LI   R12, DIRBUF
    ADD  R9, R1, R12         ; R9 = the new entry, still in DIRBUF
    LW   R6, [R9 + $0E]      ; R6 = start LBA; the name is done with
    ; A file that starts with an FB header is a program: retype the entry
    ; 'AP' and re-commit, so SAVE and LOAD round-trip. Without this every
    ; saved file would be type 'DT' and LOAD would refuse all of them.
    LB   R1, [R7]
    CMPI R1, $46             ; 'F'
    BNE  save_loop
    LB   R1, [R7 + 1]
    CMPI R1, $42             ; 'B'
    BNE  save_loop
    LI   R1, $5041           ; 'A','P' little-endian
    SW   [R9 + $0C], R1
    LI   R1, FLFS_DIRLBA
    LI   R2, DIRBUF
    CALLA sys_dskwrite
    CMPI R1, 0
    BNE  save_ioerr
save_loop:
    CMPI R8, 512
    BCC  save_tail           ; a partial sector is left
    MOV  R1, R6
    MOV  R2, R7
    CALLA sys_dskwrite
    CMPI R1, 0
    BNE  save_ioerr
    ADDI R6, R6, 1
    ADDI R7, R7, 512
    SUBI R8, R8, 512
    CMPI R8, 0
    BEQ  save_report
    JMPA save_loop
save_tail:
    CMPI R8, 0
    BEQ  save_report
    LI   R1, DIRBUF          ; zero-pad the tail (the directory is committed)
    LI   R2, 0
    LI   R3, 512
    CALLA sys_memset
    MOV  R1, R7
    LI   R2, DIRBUF
    MOV  R3, R8
    CALLA sys_memcpy
    MOV  R1, R6
    LI   R2, DIRBUF
    CALLA sys_dskwrite
    CMPI R1, 0
    BNE  save_ioerr
save_report:
    LOAD_ADDR R1, str_saved
    CALLA sys_putstr
    JMPA shell_loop
save_badaddr:
    LOAD_ADDR R1, str_align
    CALLA sys_putstr
    JMPA shell_loop
save_failed:
    LOAD_ADDR R1, str_nospace
    CALLA sys_putstr
    JMPA shell_loop
save_ioerr:
    LOAD_ADDR R1, str_diskerr
    CALLA sys_putstr
    JMPA shell_loop

; Storage diagnostics (uppercase, in the house style of ?SYNTAX ERROR).
str_nofile:
    DB "?FILE NOT FOUND", $0A, 0
str_notprog:
    DB "?NOT A PROGRAM", $0A, 0
str_badaddr:
    DB "?LOAD ADDRESS NOT $04100", $0A, 0
str_align:
    DB "?ADDRESS NOT 16-BYTE ALIGNED", $0A, 0
str_nospace:
    DB "?DIRECTORY FULL OR DISK FULL", $0A, 0
str_diskerr:
    DB "?DISK ERROR", $0A, 0
str_saved:
    DB "SAVED.", $0A, 0
