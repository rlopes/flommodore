# Flommodore — Phase 8: Developer Toolchain

## Overview

The toolchain is what turns the Flommodore from a machine you can run programs on into a
machine you can write programs for. Without it, the emulator is a black box. With it,
developers have everything they need to write, build, debug, and distribute software for
the Flommodore.

---

## 8.1 — Toolchain Components

The complete toolchain consists of five pieces:

```
Source code (.asm / .fl)
       ↓
   Assembler          .asm → .flobj   (relocatable object file)
       ↓
    Linker            .flobj(s) → .flapp  (executable application)
       ↓
   Emulator           .flapp → running program
       ↑
   Debugger           (built into emulator, Phase 7)
       ↑
  Symbol file         .flsym  (debug symbols, optional)
```

An optional higher-level language compiler (FL) sits above the assembler, emitting `.asm`
files that feed into the same pipeline.

---

## 8.2 — File Extension Family

All Flommodore toolchain files use the `.fl` prefix for consistency and unambiguous namespace
ownership. Assembly source is the only exception — `.asm` is kept as a universal convention
that assembly programmers recognise across all platforms.

| Extension | Magic | Description |
|---|---|---|
| `.asm` | — | Assembly source (plain text, no magic needed) |
| `.flobj` | `$464F` (`FO`) | Relocatable object file |
| `.flapp` | `$4642` (`FB`) | Executable application binary |
| `.flsym` | plain text | Debugger symbol file |
| `.flst` | plain text | Assembler listing file |
| `.flld` | plain text | Linker description script |
| `.fl` | — | FL higher-level language source |

### Naming rationale

- `.flapp` replaces the earlier `.flrom` name. A user program is the opposite of a ROM —
  it runs on the machine rather than being baked into it. `.flapp` is unambiguous and
  matches the autoboot header magic `$4642` (`FB` — Flommodore Boot/application).
- `.flst` replaces the generic `.lst` convention. While `.lst` is the historic assembler
  listing extension, `.flst` keeps the full file family consistent and makes build glob
  patterns (`*.fl*`) unambiguous.
- `.flld` (Flommodore Linker Description) is preferred over `.fld` for the same consistency
  reason.
- All binary formats use ASCII magic numbers readable in hex dumps, following the convention
  established in Phase 6.

---

## 8.3 — Assembly Language Design

The Gab-16 assembler uses a clean, readable syntax inspired by NASM and ARM assembly —
consistent, unambiguous, and straightforward to parse.

### General syntax rules

```asm
; Semicolons begin comments
label:              ; labels end with colon, own line or before an instruction
    MNEMONIC  dest, src1, src2          ; operands comma-separated
    MNEMONIC  dest, [base + offset]     ; memory access with brackets
```

### Literals and constants

```asm
42              ; decimal
$2A             ; hexadecimal  ($ prefix — consistent with address notation)
0b00101010      ; binary
'A'             ; ASCII character literal → 65
"hello"         ; string literal (used with DB directive only)
```

### Directives

| Directive | Description |
|---|---|
| `ORG $addr` | Set the current assembly address |
| `DB value` | Define byte |
| `DW value` | Define word (16-bit) |
| `DD value` | Define double-word (32-bit) — vector tables, 20-bit addresses |
| `DS n` | Define n bytes of zero-filled space |
| `EQU name, value` | Define a named constant |
| `INCLUDE "file"` | Include another source file |
| `INCBIN "file"` | Include raw binary data (e.g. sprite sheets, audio wavetables) |
| `ALIGN n` | Advance to next n-byte boundary |
| `SECTION name` | Declare a named section (code, data, bss) |

**ORG vs SECTION:** a source file is either *absolute* (uses `ORG`; output sections carry
fixed load addresses and link without a script — how ROM images and test ROMs are built) or
*relocatable* (uses `SECTION`; placement comes from the linker script). Mixing `ORG` and
`SECTION` in one file is an assembler error.

### Example program

```asm
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
```

### Macro system

The assembler supports a simple macro system for code reuse:

```asm
MACRO PUSH_ALL
    PUSHA
ENDMACRO

MACRO LOAD_ADDR reg, addr
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO

; Usage:
    LOAD_ADDR R1, $40000    ; load a full 20-bit address into a register
```

(`LUI` writes only bits 19:16 and **preserves the low 16 bits** — Phase 2 §2.4 — which is
why `LI` comes first in the `LOAD_ADDR` macro.)

---

## 8.4 — Object File Format (.flobj)

The assembler outputs relocatable object files. Each object file contains:

```
Header
  Magic:          2 bytes 'F','O' ($46, $4F)
  Version:        1 byte
  Section count:  1 byte
  Symbol count:   2 bytes
  Reloc count:    2 bytes

Section table (per section)
  Name:           8 bytes  (null-padded)
  Type:           1 byte   (code=0, data=1, bss=2)
  Offset:         4 bytes  (offset into binary payload)
  Size:           4 bytes
  Load address:   4 bytes  (0 = relocatable)

Symbol table (per symbol)
  Name:           32 bytes (null-padded)
  Section:        1 byte   (index into section table)
  Offset:         4 bytes  (offset within section)
  Flags:          1 byte   (global=1, local=0)

Relocation table (per entry)
  Offset:         4 bytes  (where in the section to patch)
  Symbol:         2 bytes  (index into symbol table)
  Type:           1 byte   (see relocation types below)

Binary payload
  Raw assembled bytes for each section, contiguous
```

### Relocation types

| Value | Name | Patches |
|---|---|---|
| 0 | `ABS16` | 16-bit LE word in data (`DW`) |
| 1 | `ABS32` | 32-bit LE word in data (`DD`) |
| 2 | `ABS26` | J-format ADDR26 field — absolute byte address |
| 3 | `PCREL26` | J-format ADDR26 field — `target − (instr_addr + 4)` |
| 4 | `LO16` | I-format IMM18 field ← `addr & $FFFF` |
| 5 | `HI4` | I-format IMM18 field ← `addr >> 16` |

**All multi-byte fields in every Flommodore file format are little-endian. Magic numbers
are defined as byte sequences** (`'F'` then `'O'`) so they read correctly in a hex dump —
the `$464F` notation describes the bytes in file order, not a 16-bit integer.

---

## 8.5 — Linker

The linker takes one or more `.flobj` files and a linker script and produces a single
`.flapp` executable binary.

### Linker script (.flld)

The programmer provides a simple linker script describing where sections land in memory:

```
; program.flld — Flommodore Linker Description

ENTRY start             ; entry point symbol name

SECTION code AT $04100  ; place code section at start of free RAM
SECTION data AFTER code ; place data section immediately after code
SECTION bss  AFTER data ; zero-initialised data after that
```

### What the linker does

1. **Load** all input `.flobj` files and validate their headers
2. **Resolve** symbols — match every reference to its definition across all objects
3. **Report** undefined symbols as errors before producing any output
4. **Relocate** — patch all relocation entries with final resolved addresses
5. **Emit** the `.flapp` binary with the autoboot header prepended
6. **Emit** the `.flsym` symbol file alongside the binary

### Autoboot header injection

The linker automatically prepends the 12-byte autoboot header to the output:

```
'F','B'         Magic bytes ($46, $42 — Flommodore Boot)
version         from linker script or --version command line flag
entry offset    computed from ENTRY symbol address − load base address (≥ 12)
min RAM         declared in linker script, or 0 if omitted
load address    from the code section's AT placement (4 bytes)
```

---

## 8.6 — Executable Format (.flapp)

The final binary loaded by the emulator or BIOS:

```
Offset  Size  Field
+00     2 B   Magic bytes 'F','B' ($46, $42)
+02     2 B   Program version
+04     2 B   Entry point offset from start of file (≥ 12)
+06     2 B   Minimum RAM required (KB)
+08     4 B   Load address (little-endian, masked to 20 bits; $04100 for autoboot)
+0C     N B   Raw binary (code + data sections, contiguous)
```

The file image (header + payload) is loaded verbatim at the **load address** — taken from
the linker script's `SECTION code AT` placement (`ENTRY` only names the entry symbol).
Execution begins at `load_address + entry_offset`. The format is intentionally minimal —
no dynamic linking, no runtime loader complexity.

---

## 8.7 — Symbol File (.flsym)

A plain-text file emitted alongside every `.flapp`, consumed by the emulator's built-in
debugger:

```
; hello.flsym
$04100  start
$04112  msg
$04200  some_subroutine
```

One symbol per line: hex address then name, space-separated. The debugger loads this
automatically if a `.flsym` file with the same base name exists alongside the loaded
`.flapp`. When loaded:

- The disassembler displays symbol names instead of raw addresses
- Breakpoints can be set by name: `break start`
- The memory viewer annotates known addresses with their symbol names

---

## 8.8 — Listing File (.flst)

The assembler can emit a `.flst` listing file — a human-readable view of the assembly
showing addresses, encoded instruction bytes, and source lines side by side:

```
$04100  10 41 40 14   start:  LI    R1, msg
$04104  04 C1 0F AC           CALLA SYS_PUTSTR
$04108  18 C1 0F AC           CALLA SYS_GETKEY
$0410C  00 00 00 E4           HLT
$04110              msg:
$04110  48 45 4C 4C           DB "HELLO, FLOMMODORE!", 0
$04114  4F 2C 20 46
...
```

Bytes are shown in file/memory order (little-endian words). Worked example: `HLT` is opcode
`$39` → instruction word `$39 << 26 = $E4000000` → bytes `00 00 00 E4`. `LI R1, msg` with
msg = `$04110` → `($05 << 26) | (1 << 22) | $04110 = $14404110` → bytes `10 41 40 14`.

The `.flst` extension replaces the generic `.lst` convention to keep the full Flommodore
file family consistent and build glob patterns (`*.fl*`) unambiguous.

---

## 8.9 — Toolchain Implementation

Like the emulator, the toolchain is written in **Zig 0.16**, building with `build.zig`. The
assembler, linker, and emulator are all part of the same repository and build in one step.

### Source layout

```
flommodore/
├── build.zig
├── build.zig.zon
├── src/
│   ├── ...                  (emulator sources — Phase 7)
│   └── tools/
│       ├── assembler/
│       │   ├── main.zig     Entry point — argument parsing, file I/O
│       │   ├── lexer.zig    Tokeniser — source text → token stream
│       │   ├── parser.zig   Token stream → AST
│       │   ├── codegen.zig  AST → .flobj object file
│       │   └── macro.zig    Macro expansion
│       └── linker/
│           ├── main.zig     Entry point — argument parsing, script loading
│           ├── loader.zig   Load and validate .flobj files
│           ├── resolver.zig Symbol resolution across all input objects
│           ├── relocator.zig Apply relocation patches with final addresses
│           └── emitter.zig  Write .flapp and .flsym output files
└── tests/
    ├── asm/                 Assembly source test cases
    └── link/                Linker test cases and scripts
```

### Build targets

```bash
zig build                              # build emulator + assembler + linker (host)
zig build asm                          # assembler only
zig build link                         # linker only
zig build -Dtarget=x86_64-windows-gnu  # cross-compile everything for Windows
zig build -Dtarget=x86_64-macos        # cross-compile for macOS
zig build test                         # run all toolchain unit and integration tests
```

### Assembler pipeline

```
Source text (.asm)
    ↓  lexer.zig      tokenise: identifiers, numbers, strings, directives, punctuation
Token stream
    ↓  parser.zig     build AST: instructions, directives, labels, macro definitions
AST
    ↓  macro.zig      expand all macro invocations in place
Expanded AST
    ↓  codegen.zig    pass 1: collect all symbols and compute section sizes
                      pass 2: emit opcodes, record relocation entries
.flobj file
```

### Two-pass assembly

The assembler uses the classic **two-pass** approach:

- **Pass 1** — scan all labels, record names and offsets, build the symbol table. No code
  emitted yet.
- **Pass 2** — emit instruction encodings, resolving all forward references using the
  symbol table from pass 1.

This allows labels to be referenced before they are defined — essential for
`CALLA forward_label` style forward-branch code.

---

## 8.10 — Command Line Interface

### Assembler (`flas`)

```bash
flas input.asm -o output.flobj
flas input.asm -o output.flobj -I include/path    # add include search path
flas input.asm --listing output.flst              # emit listing file
flas input.asm --listing output.flst -o out.flobj # both outputs together
```

### Linker (`fll`)

```bash
fll main.flobj lib.flobj -s program.flld -o program.flapp
fll *.flobj -s program.flld -o program.flapp -v   # verbose: print memory map
fll *.flobj -s program.flld -o program.flapp --version 1  # set app version field
fll boot.flobj -o flommodore.rom --raw --base $FC000 --size 16K
                          # raw ROM image: no header, padded to 16KB,
                          # fails if the vector slots at $FFFC0 are empty
```

### Emulator (`flommodore`)

```bash
flommodore program.flapp                          # run a program
flommodore program.flapp --debug                  # start in debugger
flommodore program.flapp --sym program.flsym      # load symbols explicitly
flommodore --rom custom.rom program.flapp         # use a custom ROM image
```

---

## 8.11 — Optional: Higher-Level Language (FL)

A minimal higher-level language — named **FL** — is a planned future addition above the
assembler layer. It is not required for the initial Flommodore release but gives the platform
long-term appeal and accessibility beyond assembly programming.

FL requires a dedicated design phase of its own before any implementation begins. That plan
must cover at minimum:

- **Type system** — primitive types (`u8`, `u16`, `i16`, pointers, arrays), structs, type safety
- **Memory model** — stack only, explicit heap, or programmer-managed arenas
- **Calling convention** — must match the Gab-16 ABI defined in Phase 2 exactly
- **Scope and modules** — single file or multi-file with imports
- **Compiler architecture** — direct to `.asm`, or intermediate representation
- **Error model** — return codes, result types, or something else
- **Standard library** — what ships with FL vs what lives in the BIOS

### Sketch of FL syntax

```c
// fl_hello.fl

extern fn sys_putstr(s: *u8) void @ $FC104;
extern fn sys_getkey() u16    @ $FC118;

fn main() void {
    sys_putstr("HELLO, FLOMMODORE!");
    sys_getkey();
}
```

The `@ $FC104` syntax binds an extern declaration to a fixed BIOS jump table address —
no linker script entry needed for system calls.

FL compiles to `.asm` which feeds into the existing assembler → linker pipeline unchanged.
The rest of the toolchain is unaffected by FL's existence.

---

## Phase 8 — Key Facts (carry forward)

### Tools

| Tool | Binary | Input | Output |
|---|---|---|---|
| Assembler | `flas` | `.asm` | `.flobj`, `.flst` |
| Linker | `fll` | `.flobj` + `.flld` | `.flapp`, `.flsym` |
| Emulator | `flommodore` | `.flapp` | Running machine |

### File formats

| Extension | Magic | Description |
|---|---|---|
| `.asm` | — | Assembly source (plain text) |
| `.flobj` | `$464F` (`FO`) | Relocatable object — sections, symbols, relocations |
| `.flapp` | `$4642` (`FB`) | Executable application with autoboot header |
| `.flsym` | plain text | Debugger symbols — address → name |
| `.flst` | plain text | Assembler listing — address, bytes, source |
| `.flld` | plain text | Linker description — section placement, entry point |
| `.fl` | — | FL higher-level language source |

### Implementation

| Item | Detail |
|---|---|
| Language | Zig 0.16 — same as emulator, one repo, one build |
| Assembly syntax | NASM/ARM inspired, `$` hex prefix, `[]` for memory |
| Macro system | `MACRO` / `ENDMACRO` with `\param` substitution |
| Assembly strategy | Two-pass — symbols first, code second |
| Cross-compilation | `zig build -Dtarget=...` — any platform from any host |
| FL language | Future phase — requires its own design plan before implementation |

---

*Flommodore Fantasy Computer — Design Document*
*Phase 8: Developer Toolchain — Status: LOCKED (v1.1 — Block 0 amendments applied)*
