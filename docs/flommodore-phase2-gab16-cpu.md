# Flommodore — Phase 2: Gab-16 CPU Specification

## Overview

The Gab-16 is a 16-bit RISC-inspired CPU with a 20-bit address bus, fixed 32-bit instruction
encoding, and a clean, programmer-friendly register file. The goal is simplicity, orthogonality,
and ease of implementation.

---

## 2.1 — Register File

The Gab-16 has **23 registers** in total — 16 general purpose and 7 special purpose.

### Register Width

All registers hold **20 significant bits**, stored in 32-bit slots internally. Every register
write is masked to `$FFFFF` — there is no separate 16-bit write path.

- **Data operations** compute on the full register value, but **flags (Z, N, C, V) are always
  derived from the low 16 bits of the result** — bit 15 is the sign bit for N and V. The
  programmer's mental model stays 16-bit, while pointers above `$FFFF` survive arithmetic
  intact.
- **Address operations** (memory access, jumps) use the full 20 bits, wired directly to the
  address bus.
- Known sharp edge (intended and documented): `CMP` compares only the low 16 bits. Comparing
  two full 20-bit pointers requires also comparing bits 19:16 (e.g. `SHR` both by 16 and
  `CMP` again).

---

### General Purpose Registers (16)

| Register | Alias | Enforcement | Convention |
|---|---|---|---|
| `R0` | `ZERO` | **Hardware** — always reads 0, writes discarded | Source of zero, NOP operand |
| `R1` – `R4` | — | None | Argument / return registers (ABI) |
| `R5` – `R8` | — | None | Caller-saved scratch (ABI) |
| `R9` – `R12` | — | None | Callee-saved (ABI) |
| `R13` | `FP` | Convention only | Frame pointer |
| `R14` | `LR` | **Hardware** — written by `CALL`/`CALLA`, read by `RET` | Link / return address |
| `R15` | `SP` | **Hardware** — used implicitly by `PUSH`, `POP`, `PUSHA`, `POPA`, and interrupt entry | Stack pointer |

**Notes on aliases:**
- Aliases serve two purposes: they signal programmer intent at a glance (`SP` vs `R15`), and
  they give the assembler, compiler, and debugger a stable named contract.
- Hardware-enforced aliases mean the CPU itself uses that register implicitly for specific
  instructions. Convention-only aliases are purely assembler names — the programmer may use
  `R13` as a general register if they manage the frame pointer manually.
- `R0` hardwired to zero simplifies the ISA significantly: comparisons against zero, clearing
  a register, and encoding NOP-like operations all become free without dedicated instructions.

---

### Special Purpose Registers (7)

| Register | Width | Purpose |
|---|---|---|
| `PC` | 20-bit | Program Counter |
| `FLAGS` | 16-bit | Condition flags (see §2.2) |
| `IVT` | 20-bit | Interrupt Vector Table base address |
| `USP` | 20-bit | User Stack Pointer — saved on interrupt entry |
| `SSP` | 20-bit | Supervisor Stack Pointer — loaded into SP on interrupt entry |
| `SYS` | 16-bit | System control register |
| `CYC` | 32-bit | Cycle counter (read-only; wraps every ~298 s at 14.4 MHz — defined behaviour) |

Special registers are read with `MFSR` and written with `MTSR` (see §2.4). Writes to `IVT`,
`SSP`, and `SYS` require supervisor mode. `PC` is not an `MTSR` target — use jumps.

Note: `SP` and `LR` are listed under GP registers (R14, R15) and also function as special
registers by hardware convention.

---

## 2.2 — FLAGS Register

| Bit | Name | Meaning |
|---|---|---|
| 0 | `Z` | Zero — result was zero |
| 1 | `N` | Negative — bit 15 of result was set |
| 2 | `C` | Carry — unsigned overflow or borrow out |
| 3 | `V` | Overflow — signed overflow |
| 4 | `I` | Interrupt enable (1 = enabled) |
| 5 | `S` | Supervisor mode (1 = kernel, 0 = user) |
| 6–15 | — | Reserved, reads as zero |

All flag results reflect **16-bit** arithmetic. Bit 15 is the sign bit for `N` and `V`.

---

## 2.3 — Instruction Encoding

All instructions are **exactly 32 bits wide**. Three primary formats cover all operations.

### Format R — Register-Register (ALU ops)
```
31      26 25    22 21    18 17    14 13       5 4        0
┌──────────┬────────┬────────┬────────┬──────────┬──────────┐
│  OPCODE  │   RD   │   RA   │   RB   │  FUNC    │  FLAGS   │
│  6 bits  │ 4 bits │ 4 bits │ 4 bits │  9 bits  │  5 bits  │
└──────────┴────────┴────────┴────────┴──────────┴──────────┘
```
- `RD`   = destination register
- `RA`   = source register A
- `RB`   = source register B
- `FUNC` = reserved — **must be zero** (nonzero traps as illegal instruction)
- `FLAGS` = reserved — **must be zero**

### Format I — Immediate (loads, stores, ALU with constant)
```
31      26 25    22 21    18 17                              0
┌──────────┬────────┬────────┬──────────────────────────────┐
│  OPCODE  │   RD   │   RA   │         IMM18                │
│  6 bits  │ 4 bits │ 4 bits │         18 bits              │
└──────────┴────────┴────────┴──────────────────────────────┘
```
- `RD`    = destination register
- `RA`    = base register (use R0 for absolute/no-base)
- `IMM18` = signed 18-bit immediate (range: −131,072 to +131,071)

### Format J — Jump / Call (long branch)
```
31      26 25                                               0
┌──────────┬────────────────────────────────────────────────┐
│  OPCODE  │                  ADDR26                        │
│  6 bits  │                  26 bits                       │
└──────────┴────────────────────────────────────────────────┘
```
- `ADDR26` = 26-bit absolute or PC-relative target address
  (covers the full 20-bit address space with room to spare)

---

## 2.4 — Instruction Set

The 6-bit opcode field allows **64 opcodes**; **49 are assigned** below (plus the `MOV`
pseudo-instruction). **Opcode `$00` and every unassigned opcode trap to the BRK vector** —
a `$0000 0000` instruction word (cleared RAM, open bus) must never execute silently.

### Load / Store

| Opcode | Mnemonic | Format | Operation |
|---|---|---|---|
| `$01` | `LW  RD, [RA + IMM]` | I | Load 16-bit word into RD |
| `$02` | `LB  RD, [RA + IMM]` | I | Load 8-bit byte, zero-extend into RD |
| `$03` | `SW  [RA + IMM], RS` | I | Store low 16 bits of RS |
| `$04` | `SB  [RA + IMM], RS` | I | Store low 8 bits of RS |
| `$05` | `LI  RD, IMM18` | I | RD = sign_extend(IMM18) & `$FFFFF` |
| `$06` | `LUI RD, IMM` | I | RD = (RD & `$0FFFF`) \| ((IMM & `$F`) << 16) |

Format I has no RB field, so **stores carry their source register in the RD field**.
`LUI` writes only bits 19:16 and **preserves the low 16 bits** — the canonical 20-bit
address load is `LI` (low half) followed by `LUI` (high nibble), as in the `LOAD_ADDR`
macro (Phase 8).

### ALU — Register-Register

| Opcode | Mnemonic | Format | Operation |
|---|---|---|---|
| `$08` | `ADD RD, RA, RB` | R | RD = RA + RB |
| `$09` | `SUB RD, RA, RB` | R | RD = RA − RB |
| `$0A` | `AND RD, RA, RB` | R | RD = RA & RB |
| `$0B` | `OR  RD, RA, RB` | R | RD = RA \| RB |
| `$0C` | `XOR RD, RA, RB` | R | RD = RA ^ RB |
| `$0D` | `NOT RD, RA` | R | RD = ~RA |
| `$0E` | `SHL RD, RA, RB` | R | RD = RA << RB[3:0] (logical) |
| `$0F` | `SHR RD, RA, RB` | R | RD = RA >> RB[3:0] (logical) |
| `$10` | `ASR RD, RA, RB` | R | RD = RA >> RB[3:0] (arithmetic, sign from bit 15) |
| `$11` | `MUL RD, RA, RB` | R | RD = RA × RB (lower 16 bits) |
| `$12` | `DIV RD, RA, RB` | R | RD = RA ÷ RB (integer quotient) |
| `$13` | `MOD RD, RA, RB` | R | RD = RA mod RB |
| `$14` | `CMP RA, RB` | R | Set FLAGS from RA − RB, discard result |

Shift amounts use RB bits 3:0 (0–15; larger shifts are unencodable).
**Divide by zero: RD ← `$FFFF`, V ← 1, no trap** — for both `DIV` and `MOD`.

### ALU — Immediate

| Opcode | Mnemonic | Format | Operation |
|---|---|---|---|
| `$18` | `ADDI RD, RA, IMM` | I | RD = RA + IMM |
| `$19` | `SUBI RD, RA, IMM` | I | RD = RA − IMM |
| `$1A` | `ANDI RD, RA, IMM` | I | RD = RA & IMM |
| `$1B` | `ORI  RD, RA, IMM` | I | RD = RA \| IMM |
| `$1C` | `XORI RD, RA, IMM` | I | RD = RA ^ IMM |
| `$1D` | `CMPI RA, IMM` | I | Set FLAGS from RA − IMM, discard result |

### Branch & Jump

| Opcode | Mnemonic | Format | Condition / operation |
|---|---|---|---|
| `$20` | `BEQ ADDR` | J | Branch if Z=1 (equal) |
| `$21` | `BNE ADDR` | J | Branch if Z=0 (not equal) |
| `$22` | `BLT ADDR` | J | Branch if N≠V (signed less than) |
| `$23` | `BGT ADDR` | J | Branch if Z=0 and N=V (signed greater than) |
| `$24` | `BLE ADDR` | J | Branch if Z=1 or N≠V (signed less or equal) |
| `$25` | `BGE ADDR` | J | Branch if N=V (signed greater or equal) |
| `$26` | `BCS ADDR` | J | Branch if C=1 (unsigned ≥ after CMP) |
| `$27` | `BCC ADDR` | J | Branch if C=0 (unsigned < after CMP) |
| `$28` | `JMP  RA` | R | PC = RA (register indirect) |
| `$29` | `JMPA ADDR` | J | PC = ADDR26 & `$FFFFF` (absolute) |
| `$2A` | `CALL  RA` | R | LR = address of next instruction; PC = RA |
| `$2B` | `CALLA ADDR` | J | LR = address of next instruction; PC = ADDR |
| `$2C` | `RET` | R | PC = LR |

Branch target = address of the **next** instruction + sign-extended ADDR26, in **bytes**.

### Stack

Stack slots are **4 bytes** — registers hold 20-bit values, and 2-byte slots would truncate
return addresses above `$FFFF`.

| Opcode | Mnemonic | Format | Operation |
|---|---|---|---|
| `$30` | `PUSH RA` | R | SP −= 4 ; [SP]₃₂ = RA |
| `$31` | `POP  RD` | R | RD = [SP]₃₂ & `$FFFFF` ; SP += 4 |
| `$32` | `PUSHA` | R | Push R1–R12 and LR (52 bytes) |
| `$33` | `POPA` | R | Pop LR and R12–R1 (52 bytes) |

### System

| Opcode | Mnemonic | Format | Operation |
|---|---|---|---|
| `$38` | `NOP` | R | No operation |
| `$39` | `HLT` | R | Halt CPU, wake on next **delivered** interrupt |
| `$3A` | `RTI` | R | Return from interrupt (see §2.6) |
| `$3B` | `SEI` | R | Set interrupt enable (FLAGS.I = 1) |
| `$3C` | `CLI` | R | Clear interrupt enable (FLAGS.I = 0) |
| `$3D` | `MFSR RD, sreg` | R | RD = special register (sreg in RA field) |
| `$3E` | `MTSR sreg, RA` | R | Special register = RA (sreg in RD field) |
| — | `MOV RD, RA` | R | Assembler pseudo: `ADD RD, RA, R0` |

The `SYS` instruction of spec v1.0 is **removed** — the BIOS jump table (Phase 6 §6.4) is
the sole system-call mechanism. Its opcode slot is reserved for a future trap design.

### Special register numbers (MFSR / MTSR)

| n | Register | Access |
|---|---|---|
| 0 | `FLAGS` | MFSR always; MTSR in user mode **ignores bits I and S** |
| 1 | `IVT` | MTSR supervisor-only |
| 2 | `USP` | read/write |
| 3 | `SSP` | MTSR supervisor-only |
| 4 | `SYS` | MTSR supervisor-only |
| 5 | `CYC` | read-only (MTSR ignored) |
| 6–15 | — | Reserved |

### Flag semantics (per operation)

Flags are always computed from the **low 16 bits** of the result.

| Operations | Z | N | C | V |
|---|---|---|---|---|
| `ADD`, `ADDI` | result=0 | bit 15 | carry out of bit 15 | `(~(a^b) & (a^r))` bit 15 |
| `SUB`, `SUBI`, `CMP`, `CMPI` | result=0 | bit 15 | **no-borrow (ARM): C=1 iff a ≥ b unsigned** | `((a^b) & (a^r))` bit 15 |
| `AND`/`OR`/`XOR`/`NOT` (+ I forms) | ✓ | ✓ | cleared | cleared |
| `SHL`/`SHR`/`ASR` | ✓ | ✓ | last bit shifted out (0 if shift = 0) | cleared |
| `MUL` | ✓ (low 16) | ✓ | 0 | 0 |
| `DIV`, `MOD` | ✓ | ✓ | 0 | set on divide-by-zero |
| All other instructions | — | — | — | — (flags unaffected) |

---

## 2.5 — Addressing Modes

| Mode | Syntax | Notes |
|---|---|---|
| Immediate | `IMM` | 18-bit signed constant embedded in instruction |
| Register | `RA` | Direct register value |
| Register indirect | `[RA]` | Memory at address in RA |
| Base + offset | `[RA + IMM]` | Memory at RA + signed IMM18 |
| PC-relative | `PC + IMM` | Used by all branch instructions |
| Absolute | `ADDR` | Full address in J-format instruction |

---

## 2.6 — Interrupt Handling

- The `IVT` register holds the base address of the **Interrupt Vector Table**, anywhere in RAM.
- The table holds **16 entries of 4 bytes each** (64 bytes). Each entry is a 32-bit
  little-endian value, masked to 20 bits when loaded into PC. Entry *i* lives at `IVT + 4×i`.
- **Entry sequence** (hardware): if `FLAGS.S = 0` → `USP ← SP`, `SP ← SSP`. (A nested entry
  with S already 1 skips the stack switch and leaves USP untouched.) Then push `PC`
  (4 bytes), push `FLAGS` (4 bytes, upper 16 zero), set `FLAGS.S = 1`, clear `FLAGS.I`,
  load PC from the vector. **Frame size: 8 bytes.**
- `RTI`: pop `FLAGS` (low 16 bits taken), pop `PC`. If the restored `S = 0` → `SSP ← SP`,
  `SP ← USP`.
- `HLT` wakes only on a *delivered* interrupt (unmasked and `FLAGS.I = 1`). `HLT` with I=0
  halts until reset — intentional.

### Interrupt Vector Table

| Offset | Index | Source |
|---|---|---|
| `IVT + $00` | 0 | RESET |
| `IVT + $04` | 1 | NMI (debugger break; no hardware source in v1) |
| `IVT + $08` | 2 | IRQ — **all maskable device interrupts** |
| `IVT + $0C` | 3 | BRK / software trap / illegal instruction |
| `IVT + $10` – `IVT + $3C` | 4–15 | Reserved (contain `$00000000`) |

**Software dispatch:** every device interrupt — timers, keyboard, joystick, VBLANK, raster,
audio — enters through index 2. The handler reads `IRQSTAT` (Phase 5 §5.5) to identify and
service sources. `SYS_IRQSET` installs per-source handlers in a **BIOS-side dispatch table**
keyed by IRQSTAT bit number; that table is BIOS state, not hardware. The per-source hardware
vectors of spec v1.0 (old entries 4–7) are deleted.

---

## 2.7 — Boot Sequence

1. CPU powers on; sets `FLAGS.S = 1` (supervisor mode), `FLAGS.I = 0` (interrupts disabled)
2. `PC` is loaded from the 4-byte RESET vector at `$FFFC0` (top of ROM)
3. ROM boot code runs: initialises SP (`$01100`) and SSP, clears system variables, sets the IVT base (`$FFFC0`) via `MTSR`
4. ROM performs device detection and initialisation (VIC-256, AUR-1, timers)
5. ROM sets `FLAGS.I = 1` (`SEI`) and hands off to the BIOS shell or user program

---

## 2.8 — Calling Convention (ABI)

| Role | Registers | Notes |
|---|---|---|
| Arguments (up to 4) | `R1` – `R4` | Further args passed on stack |
| Return value (16-bit) | `R1` | — |
| Return value (32-bit) | `R1:R2` | High word in R1, low in R2 |
| Caller-saved scratch | `R1` – `R8` | Caller must save if needed across a call |
| Callee-saved | `R9` – `R12`, `FP` | Callee must preserve and restore |
| Frame pointer | `R13 (FP)` | Convention only, not hardware enforced |
| Link register | `R14 (LR)` | Hardware enforced — written by CALL |
| Stack pointer | `R15 (SP)` | Hardware enforced — used by PUSH/POP |

---

## Phase 2 — Key Facts (carry forward to all phases)

| Item | Detail |
|---|---|
| GP registers | 16 (R0–R15), 20 significant bits — flags always from low 16 |
| R0 | Hardwired zero (hardware enforced) |
| R14 / LR | Link register (hardware enforced by CALL/RET) |
| R15 / SP | Stack pointer (hardware enforced by PUSH/POP/interrupt) |
| Instruction width | Fixed 32-bit |
| Instruction formats | R (register), I (immediate), J (jump) |
| Opcode space | 64 slots, 49 assigned (+1 pseudo); `$00` and unassigned trap to BRK |
| Address bus | 20-bit (1MB space) |
| IVT | 16 × 4-byte vectors (64 B), base address in IVT register |
| Supervisor mode | FLAGS.S — set on interrupt, cleared on RTI |
| Boot vector | `$FFFC0` (top of ROM), 4-byte |
| Stack | 4-byte slots; interrupt frame 8 bytes (PC + FLAGS) |
| Special registers | 7 (PC, FLAGS, IVT, USP, SSP, SYS, CYC) via MFSR/MTSR |

---

*Flommodore Fantasy Computer — Design Document*
*Phase 2: Gab-16 CPU Specification — Status: LOCKED (v1.1 — Block 0 amendments applied)*
