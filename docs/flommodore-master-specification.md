# Flommodore Fantasy Computer
## Master Specification Document

**Version 1.1 — All Phases Locked (Block 0 amendments applied)**

---

## About This Document

This is the complete design specification for the Flommodore fantasy computer. It covers
all eight design phases — from memory architecture through to the developer toolchain —
and serves as the single authoritative reference for the entire project.

The specification was developed phase by phase, with each phase building on the decisions
locked in the previous ones. The emulator is the definitive runtime reference: where this
document is ambiguous, what the emulator does is what the Flommodore does.

---

## Machine Summary

| Component | Name | Key Specs |
|---|---|---|
| **CPU** | Gab-16 | 16-bit RISC, 20-bit address bus, 32-bit fixed instruction encoding |
| **Video** | VIC-256 | 256KB VRAM, 4 display modes, 64 sprites, raster interrupts |
| **Audio** | AUR-1 | 4 voices, ADSR, FM synthesis, wavetable, stereo 16-bit @ 44.1KHz |
| **RAM** | — | 512KB total (256KB general + 256KB VRAM) |
| **ROM** | — | 16KB, 29 system calls, BIOS shell |
| **I/O** | — | Timers × 2, keyboard, joystick × 2, IRQ controller |
| **Emulator** | — | Zig 0.16 + SDL3, cross-platform |
| **Toolchain** | — | Assembler (flas), Linker (fll), optional FL language |

---

## Table of Contents

1. [Memory Map Architecture](#phase-1--memory-map-architecture)
2. [Gab-16 CPU Specification](#phase-2--gab-16-cpu-specification)
3. [VIC-256 Video Chip Specification](#phase-3--vic-256-video-chip-specification)
4. [AUR-1 Sound Chip Specification](#phase-4--aur-1-sound-chip-specification)
5. [I/O & Peripherals Specification](#phase-5--io--peripherals-specification)
6. [ROM & Boot Sequence](#phase-6--rom--boot-sequence)
7. [Emulator / Reference Implementation](#phase-7--emulator--reference-implementation)
8. [Developer Toolchain](#phase-8--developer-toolchain)

---

---

# Phase 1 — Memory Map Architecture

## Overview

With a 20-bit address bus, the Gab-16 CPU has a clean **1MB address space** (`$00000 – $FFFFF`).
Everything maps linearly — no bank switching, no segmentation, no tricks.

---

## 1.1 — Physical Memory Summary

```
Total address space   1 MB        ($00000 – $FFFFF)
Physical RAM          512 KB      ($00000 – $7FFFF)
VRAM (VIC-256)        256 KB      ($40000 – $7FFFF)  ← top half of RAM
General RAM           256 KB      ($00000 – $3FFFF)
I/O Region            ~4 KB       ($80000 – $80FFF)
Reserved              ~unch.      ($81000 – $FBFFF)
ROM                   16 KB       ($FC000 – $FFFFF)
System Vectors        64 B        (top of ROM)
```

The 512KB of physical RAM is split cleanly in two:
- **Lower 256KB** — general purpose RAM for CPU, stack, program, data
- **Upper 256KB** — dedicated VRAM for the VIC-256

---

## 1.2 — Full Memory Map

```
$FFFFF ┤
       │  System Vectors          64 B      ($FFFC0 – $FFFFF)
       │─────────────────────────────────────────────────────
       │  ROM (BIOS / Kernel)     16 KB     ($FC000 – $FFFFF)
       │  · Boot code
       │  · System call library
       │  · Font data
       │  · ROM ID & version
$FC000 ┤─────────────────────────────────────────────────────
       │
       │  Reserved                ~unch.    ($81000 – $FBFFF)
       │  (future expansion, cartridge port, etc.)
       │
$81000 ┤─────────────────────────────────────────────────────
       │  I/O Region              4 KB      ($80000 – $80FFF)
       │  · Bank ctrl / sys cfg   16 B      ($80000 – $8000F)
       │  · Timers A & B          16 B      ($80010 – $8001F)
       │  · Keyboard              16 B      ($80020 – $8002F)
       │  · Joystick ports A & B  16 B      ($80030 – $8003F)
       │  · IRQ control           16 B      ($80040 – $8004F)
       │  · Reserved I/O          176 B     ($80050 – $800FF)
       │  · AUR-1 Sound registers 256 B     ($80100 – $801FF)
       │  · VIC-256 ctrl regs     256 B     ($80200 – $802FF)
       │  · Reserved              3.5 KB    ($80300 – $80FFF)
$80000 ┤─────────────────────────────────────────────────────
       │  VRAM (VIC-256)          256 KB    ($40000 – $7FFFF)
       │  · Framebuffer(s)
       │  · Tile / sprite data
       │  · Palette tables
$40000 ┤─────────────────────────────────────────────────────
       │  General RAM             256 KB    ($00000 – $3FFFF)
       │  · Zero Page             256 B     ($00000 – $000FF)
       │  · Default Stack         4 KB      ($00100 – $010FF)
       │  · System Variables      4 KB      ($01100 – $020FF)
       │  · Kernel Workspace      8 KB      ($02100 – $040FF)
       │  · Free RAM              ~240 KB   ($04100 – $3FFFF)
$00000 ┘─────────────────────────────────────────────────────
```

---

## 1.3 — General RAM Layout Detail

| Range | Size | Purpose |
|---|---|---|
| `$00000 – $000FF` | 256 B | Zero Page |
| `$00100 – $010FF` | 4 KB | Default Stack |
| `$01100 – $020FF` | 4 KB | System Variables |
| `$02100 – $040FF` | 8 KB | Kernel Workspace |
| `$04100 – $3FFFF` | ~240 KB | Free RAM |

**Zero Page** (`$00000 – $000FF`)
Fast-access variables, CPU-convention scratch space.

**Default Stack** (`$00100 – $010FF`)
SP initialised here at boot; grows downward.
Programs may relocate and resize the stack freely.

**System Variables** (`$01100 – $020FF`)
OS state, device status, IRQ vectors (RAM shadows), current video mode, keyboard buffer, etc.

**Kernel Workspace** (`$02100 – $040FF`)
BIOS runtime scratch, DMA buffers, I/O staging.

**Free RAM** (`$04100 – $3FFFF`)
Programs, data, extra stacks, heap — all free use.

---

## 1.4 — VRAM Layout Detail

The VIC-256 has full autonomous access to this region. The CPU can write here directly (it is
normal RAM on the bus) but the VIC-256 also reads it continuously for display. Internal layout
within VRAM is controlled by VIC-256 registers and defined fully in Phase 3.

```
$40000 – $7FFFF   256 KB   VIC-256 VRAM
                           · Framebuffer data
                           · Tile maps & tile graphics
                           · Sprite attribute tables & bitmaps
                           · Palette RAM
                           (internal layout defined in Phase 3)
```

---

## 1.5 — I/O Region Detail (`$80000 – $80FFF`)

| Range | Size | Device |
|---|---|---|
| `$80000 – $8000F` | 16 B | System config & misc control |
| `$80010 – $8001F` | 16 B | Timer A & Timer B registers |
| `$80020 – $8002F` | 16 B | Keyboard registers |
| `$80030 – $8003F` | 16 B | Joystick port A & B registers |
| `$80040 – $8004F` | 16 B | IRQ control & status |
| `$80050 – $800FF` | 176 B | Reserved for future I/O expansion |
| `$80100 – $801FF` | 256 B | AUR-1 Sound Chip registers |
| `$80200 – $802FF` | 256 B | VIC-256 Control registers |
| `$80300 – $80FFF` | ~3.5 KB | Reserved |

---

## 1.6 — ROM Layout Detail (`$FC000 – $FFFFF`)

| Range | Size | Contents |
|---|---|---|
| `$FC000 – $FC01F` | 32 B | ROM header (magic, version, checksum, entry points) |
| `$FC020 – $FC0FF` | 224 B | Reserved / padding |
| `$FC100 – $FC1FF` | 256 B | System call jump table (64 × 4 bytes) |
| `$FC200 – $FDFFF` | ~7.5 KB | BIOS kernel code |
| `$FE000 – $FF7FF` | 6 KB | Font data (2 KB primary + 4 KB secondary slot) |
| `$FF800 – $FFAFF` | 768 B | Default palette (256 × 3-byte RGB) |
| `$FFB00 – $FFFBF` | 1216 B | Reserved |
| `$FFFC0 – $FFFFF` | 64 B | System Vectors (16 × 4 bytes) |

### System Vectors

All vectors are **4 bytes** — 32-bit little-endian values masked to 20 bits. Slot *i* lives
at `$FFFC0 + 4×i`, mirroring the IVT layout (§2.6).

| Address | Index | Name | Purpose |
|---|---|---|---|
| `$FFFC0 – $FFFC3` | 0 | `RESET` | Boot entry point |
| `$FFFC4 – $FFFC7` | 1 | `NMI` | Non-maskable interrupt (debugger break) |
| `$FFFC8 – $FFFCB` | 2 | `IRQ` | All maskable device interrupts (software dispatch) |
| `$FFFCC – $FFFCF` | 3 | `BRK` | Software trap / illegal instruction |
| `$FFFD0 – $FFFFF` | 4–15 | — | Reserved (contain `$00000000`) |

---

## 1.7 — ROM Shadowing

The shadow source is a **fixed window: `$3C000 – $3FFFF`** (top 16KB of general RAM). When
the shadow enable bit (`SYSCFG` bit 0 at `$80000`) is set, the bus maps
`$FC000 + offset ↔ $3C000 + offset` for both reads and writes — allowing patched system
calls, replacement fonts, and custom kernels. Programs intending to shadow must not place
data in the window. Full procedure documented in Phase 6.

---

## 1.8 — Address Space At a Glance

```
$00000  ├──────────────────────┤  ↑
        │   Zero Page   256 B  │  │
$00100  ├──────────────────────┤  │
        │   Default Stack  4KB │  │  General
$01100  ├──────────────────────┤  │  Purpose
        │   System Vars    4KB │  │  RAM
$02100  ├──────────────────────┤  │  256 KB
        │   Kernel Work    8KB │  │
$04100  ├──────────────────────┤  │
        │   Free RAM    ~240KB │  │
$40000  ├──────────────────────┤  ↓
        │   VRAM        256KB  │  VIC-256
$80000  ├──────────────────────┤
        │   I/O Region    4KB  │  Devices
$81000  ├──────────────────────┤
        │   Reserved           │
$FC000  ├──────────────────────┤
        │   ROM          16KB  │  BIOS
$FFFFF  └──────────────────────┘
```

---

## Phase 1 — Key Facts

| Item | Address | Notes |
|---|---|---|
| Zero Page | `$00000` | CPU fast addressing |
| Default Stack | `$00100` | 4KB, grows downward, relocatable |
| System Variables | `$01100` | OS state, buffers |
| Kernel Workspace | `$02100` | BIOS scratch, DMA staging |
| Free RAM | `$04100` | ~240KB available to programs |
| VRAM | `$40000` | 256KB, CPU-writable, VIC-256 reads |
| I/O Region | `$80000` | All device registers |
| AUR-1 Registers | `$80100` | Sound chip, 256B block |
| VIC-256 Control | `$80200` | Video control registers, 256B block |
| ROM | `$FC000` | 16KB, shadowable via the `$3C000` window |
| System Vectors | `$FFFC0` | RESET, NMI, IRQ, BRK — 4-byte vectors |

---

---

# Phase 2 — Gab-16 CPU Specification

## Overview

The Gab-16 is a 16-bit RISC-inspired CPU with a 20-bit address bus, fixed 32-bit instruction
encoding, and a clean, programmer-friendly register file. The goal is simplicity, orthogonality,
and ease of implementation.

---

## 2.1 — Register File

The Gab-16 has **23 registers** in total — 16 general purpose and 7 special purpose.

### Register Width

All registers hold **20 significant bits**, stored in 32-bit slots internally. Every register
write is masked to `$FFFFF`.

- **Data operations** compute on the full register value; **flags (Z, N, C, V) are always
  derived from the low 16 bits of the result** (bit 15 = sign for N and V).
- **Address operations** use the full 20 bits, wired to the address bus.
- Documented sharp edge: `CMP` compares only the low 16 bits — comparing two 20-bit pointers
  also requires comparing bits 19:16 (`SHR` by 16, `CMP` again).

### General Purpose Registers (16)

| Register | Alias | Enforcement | Convention |
|---|---|---|---|
| `R0` | `ZERO` | **Hardware** — always reads 0, writes discarded | Source of zero, NOP operand |
| `R1` – `R4` | — | None | Argument / return registers (ABI) |
| `R5` – `R8` | — | None | Caller-saved scratch (ABI) |
| `R9` – `R12` | — | None | Callee-saved (ABI) |
| `R13` | `FP` | Convention only | Frame pointer |
| `R14` | `LR` | **Hardware** — written by `CALL`/`CALLA`, read by `RET` | Link / return address |
| `R15` | `SP` | **Hardware** — used implicitly by `PUSH`, `POP`, `PUSHA`, `POPA`, interrupt entry | Stack pointer |

**Notes on aliases:**
Hardware-enforced aliases mean the CPU itself uses that register implicitly for specific
instructions. Convention-only aliases are purely assembler names. `R0` hardwired to zero
simplifies the ISA significantly — comparisons against zero and NOP-like operations require
no dedicated instructions.

### Special Purpose Registers (7)

| Register | Width | Purpose |
|---|---|---|
| `PC` | 20-bit | Program Counter |
| `FLAGS` | 16-bit | Condition flags (see §2.2) |
| `IVT` | 20-bit | Interrupt Vector Table base address |
| `USP` | 20-bit | User Stack Pointer — saved on interrupt entry |
| `SSP` | 20-bit | Supervisor Stack Pointer — loaded into SP on interrupt entry |
| `SYS` | 16-bit | System control register |
| `CYC` | 32-bit | Cycle counter (read-only; wraps every ~298 s — defined behaviour) |

Read with `MFSR`, written with `MTSR` (§2.4). `IVT`/`SSP`/`SYS` writes are supervisor-only.
`PC` is not an `MTSR` target — use jumps.

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

All instructions are **exactly 32 bits wide**. Three primary formats:

### Format R — Register-Register (ALU ops)
```
31      26 25    22 21    18 17    14 13       5 4        0
┌──────────┬────────┬────────┬────────┬──────────┬──────────┐
│  OPCODE  │   RD   │   RA   │   RB   │  FUNC    │  FLAGS   │
│  6 bits  │ 4 bits │ 4 bits │ 4 bits │  9 bits  │  5 bits  │
└──────────┴────────┴────────┴────────┴──────────┴──────────┘
```

### Format I — Immediate (loads, stores, ALU with constant)
```
31      26 25    22 21    18 17                              0
┌──────────┬────────┬────────┬──────────────────────────────┐
│  OPCODE  │   RD   │   RA   │         IMM18                │
│  6 bits  │ 4 bits │ 4 bits │         18 bits              │
└──────────┴────────┴────────┴──────────────────────────────┘
```
IMM18 = signed 18-bit immediate (range: −131,072 to +131,071)

### Format J — Jump / Call (long branch)
```
31      26 25                                               0
┌──────────┬────────────────────────────────────────────────┐
│  OPCODE  │                  ADDR26                        │
│  6 bits  │                  26 bits                       │
└──────────┴────────────────────────────────────────────────┘
```
ADDR26 covers the full 20-bit address space with room to spare.

---

## 2.4 — Instruction Set

64 opcode slots; **49 assigned** (plus the `MOV` pseudo). **Opcode `$00` and every unassigned
opcode trap to the BRK vector** — a `$0000 0000` word (cleared RAM, open bus) never executes
silently. R-format FUNC and FLAGS fields are reserved and must be zero.

### Load / Store

| Opcode | Mnemonic | Format | Operation |
|---|---|---|---|
| `$01` | `LW  RD, [RA + IMM]` | I | Load 16-bit word into RD |
| `$02` | `LB  RD, [RA + IMM]` | I | Load 8-bit byte, zero-extend |
| `$03` | `SW  [RA + IMM], RS` | I | Store low 16 bits of RS (RS in the RD field) |
| `$04` | `SB  [RA + IMM], RS` | I | Store low 8 bits of RS (RS in the RD field) |
| `$05` | `LI  RD, IMM18` | I | RD = sign_extend(IMM18) & `$FFFFF` |
| `$06` | `LUI RD, IMM` | I | RD = (RD & `$0FFFF`) \| ((IMM & `$F`) << 16) — preserves low 16 |

### ALU — Register-Register

| Opcode | Mnemonic | Operation | Opcode | Mnemonic | Operation |
|---|---|---|---|---|---|
| `$08` | `ADD` | RD = RA + RB | `$0F` | `SHR` | logical right, RB[3:0] |
| `$09` | `SUB` | RD = RA − RB | `$10` | `ASR` | arithmetic right |
| `$0A` | `AND` | RD = RA & RB | `$11` | `MUL` | low 16 bits |
| `$0B` | `OR` | RD = RA \| RB | `$12` | `DIV` | quotient; ÷0 → `$FFFF`, V=1 |
| `$0C` | `XOR` | RD = RA ^ RB | `$13` | `MOD` | remainder; ÷0 → `$FFFF`, V=1 |
| `$0D` | `NOT` | RD = ~RA | `$14` | `CMP` | flags from RA − RB |
| `$0E` | `SHL` | logical left, RB[3:0] | | | |

### ALU — Immediate

`$18` `ADDI` · `$19` `SUBI` · `$1A` `ANDI` · `$1B` `ORI` · `$1C` `XORI` · `$1D` `CMPI`
(I-format; same semantics as register forms with sign-extended IMM18)

### Branch & Jump

| Opcode | Mnemonic | Condition / operation |
|---|---|---|
| `$20`–`$27` | `BEQ BNE BLT BGT BLE BGE BCS BCC` | J-format, PC-relative byte offset from next instruction; BCS = C=1 (unsigned ≥ after CMP) |
| `$28` | `JMP RA` | PC = RA |
| `$29` | `JMPA ADDR` | PC = ADDR26 & `$FFFFF` |
| `$2A` | `CALL RA` | LR = next instruction; PC = RA |
| `$2B` | `CALLA ADDR` | LR = next instruction; PC = ADDR |
| `$2C` | `RET` | PC = LR |

### Stack — 4-byte slots

| Opcode | Mnemonic | Operation |
|---|---|---|
| `$30` | `PUSH RA` | SP −= 4 ; [SP]₃₂ = RA |
| `$31` | `POP RD` | RD = [SP]₃₂ & `$FFFFF` ; SP += 4 |
| `$32` | `PUSHA` | Push R1–R12, LR (52 bytes) |
| `$33` | `POPA` | Pop LR, R12–R1 |

### System

| Opcode | Mnemonic | Operation |
|---|---|---|
| `$38` | `NOP` | No operation |
| `$39` | `HLT` | Halt; wake on next **delivered** interrupt |
| `$3A` | `RTI` | Return from interrupt (§2.6) |
| `$3B` | `SEI` | FLAGS.I = 1 |
| `$3C` | `CLI` | FLAGS.I = 0 |
| `$3D` | `MFSR RD, sreg` | Read special register (sreg in RA field) |
| `$3E` | `MTSR sreg, RA` | Write special register (sreg in RD field) |
| — | `MOV RD, RA` | Pseudo: `ADD RD, RA, R0` |

The v1.0 `SYS` instruction is **removed** — the BIOS jump table (§6) is the syscall
mechanism. sreg numbers: 0=FLAGS (user-mode MTSR ignores I and S), 1=IVT†, 2=USP, 3=SSP†,
4=SYS†, 5=CYC (read-only). † = supervisor-only writes.

### Flag semantics (always from the low 16 bits)

| Operations | Z | N | C | V |
|---|---|---|---|---|
| `ADD`/`ADDI` | ✓ | bit 15 | carry out | add overflow |
| `SUB`/`SUBI`/`CMP`/`CMPI` | ✓ | bit 15 | **no-borrow (C=1 iff a ≥ b unsigned)** | sub overflow |
| Logic ops | ✓ | ✓ | 0 | 0 |
| Shifts | ✓ | ✓ | last bit out | 0 |
| `MUL` | ✓ | ✓ | 0 | 0 |
| `DIV`/`MOD` | ✓ | ✓ | 0 | set on ÷0 |
| All others | flags unaffected | | | |

---

## 2.5 — Addressing Modes

| Mode | Syntax | Notes |
|---|---|---|
| Immediate | `IMM` | 18-bit signed constant |
| Register | `RA` | Direct register value |
| Register indirect | `[RA]` | Memory at address in RA |
| Base + offset | `[RA + IMM]` | Memory at RA + signed IMM18 |
| PC-relative | `PC + IMM` | Used by all branch instructions |
| Absolute | `ADDR` | Full address in J-format instruction |

---

## 2.6 — Interrupt Handling

- `IVT` register holds the base of the **Interrupt Vector Table**, anywhere in RAM
- **16 entries × 4 bytes** (64 B); each a 32-bit LE value masked to 20 bits; entry *i* at `IVT + 4×i`
- **Entry:** if S=0 → `USP ← SP`, `SP ← SSP` (nested entries skip the switch). Push `PC` (4 B),
  push `FLAGS` (4 B), set S, clear I, jump to vector. **Frame = 8 bytes**
- **`RTI`:** pop FLAGS, pop PC; if restored S=0 → `SSP ← SP`, `SP ← USP`
- `HLT` wakes only on a *delivered* (unmasked, I=1) interrupt

### Interrupt Vector Table

| Offset | Index | Source |
|---|---|---|
| `IVT + $00` | 0 | RESET |
| `IVT + $04` | 1 | NMI (debugger break; no hardware source in v1) |
| `IVT + $08` | 2 | IRQ — **all maskable device interrupts** |
| `IVT + $0C` | 3 | BRK / software trap / illegal instruction |
| `IVT + $10` – `$3C` | 4–15 | Reserved (`$00000000`) |

**Software dispatch:** all device interrupts enter index 2; the handler reads `IRQSTAT` to
dispatch. `SYS_IRQSET` maintains a BIOS-side per-source table — not hardware. The v1.0
per-source vectors (old 4–7) are deleted.

---

## 2.7 — Boot Sequence (CPU perspective)

1. Powers on: `FLAGS.S = 1`, `FLAGS.I = 0`
2. Loads `PC` from the 4-byte RESET vector at `$FFFC0`
3. ROM initialises SP (`$01100`) and SSP, clears variables, sets IVT (`$FFFC0`) via `MTSR`
4. ROM initialises all devices
5. ROM sets `FLAGS.I = 1` and hands off

---

## 2.8 — Calling Convention (ABI)

| Role | Registers | Notes |
|---|---|---|
| Arguments (up to 4) | `R1` – `R4` | Further args passed on stack |
| Return value (16-bit) | `R1` | — |
| Return value (32-bit) | `R1:R2` | High word in R1, low in R2 |
| Caller-saved scratch | `R1` – `R8` | Caller must save across calls |
| Callee-saved | `R9` – `R12`, `FP` | Callee must preserve and restore |
| Frame pointer | `R13 (FP)` | Convention only |
| Link register | `R14 (LR)` | Hardware enforced |
| Stack pointer | `R15 (SP)` | Hardware enforced |

---

## Phase 2 — Key Facts

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
| IVT | 16 × 4-byte vectors (64 B), base in IVT register |
| Supervisor mode | FLAGS.S — set on interrupt, cleared on RTI |
| Boot vector | `$FFFC0` (top of ROM), 4-byte |
| Stack | 4-byte slots; interrupt frame 8 bytes |

---

---

# Phase 3 — VIC-256 Video Chip Specification

## Overview

The VIC-256 is the Flommodore's graphics processor. It operates autonomously, continuously
reading from its dedicated 256KB VRAM region (`$40000 – $7FFFF`) and generating a video signal.
The CPU communicates with it via control registers at `$80200 – $802FF` and by writing directly
into VRAM and general RAM.

---

## 3.1 — Design Philosophy

The VIC-256 supports three display paradigms that can be layered:

- **Bitmap mode** — pixel-perfect framebuffer
- **Tile mode** — efficient background rendering using reusable 8×8 or 16×16 tiles
- **Sprite layer** — hardware sprites composited on top

Priority order: **Sprites > Tile layer > Bitmap layer > Background colour**

---

## 3.2 — Colour Palette System

| Mode | Bits/pixel | Colours | Typical use |
|---|---|---|---|
| **1-bit** | 1 bpp | 2 | Monochrome, text, overlays |
| **4-bit** | 4 bpp | 16 | Classic home computer style |
| **8-bit** | 8 bpp | 256 | Full VIC-256 palette |

Each palette entry is a **24-bit RGB** value. The 256-entry palette table (768 bytes) lives
in general RAM at the address pointed to by `VPALBASE`.

---

## 3.3 — Memory Architecture

Palette data, SAT, and tile maps live in **general RAM** (pointed to by VIC-256 control
registers). VRAM is reserved exclusively for pixel and tile graphics data.

```
General RAM (pointed to by VIC-256 registers)
  Palette RAM      768 B     256 × 3 bytes (24-bit RGB entries)
  SAT              512 B     64 sprites × 8 bytes
  Tile map         up to 8KB

VRAM ($40000 – $7FFFF, 256KB — pixel data only)
  Tile graphics    up to 16KB
  Framebuffer(s)   remainder
```

### VIC-256 pointer registers

| Register | Points to |
|---|---|
| `VPALBASE` | Palette RAM base address in general RAM |
| `VSATBASE` | Sprite Attribute Table base address in general RAM |
| `VTMAPBASE` | Tile map base address in general RAM |

---

## 3.4 — Resolutions & VRAM Budget

### Supported modes (framebuffer + 16KB tile graphics ≤ 256KB)

| Resolution | Colour depth | Framebuffer | Remaining | Double buffer? |
|---|---|---|---|---|
| 320×180 | 8 bpp (256 col) | 56 KB | 184 KB | ✓ |
| 320×180 | 4 bpp (16 col) | 28 KB | 212 KB | ✓ |
| 640×360 | 8 bpp (256 col) | 225 KB | 15 KB | ✗ |
| 640×360 | 4 bpp (16 col) | 115 KB | 125 KB | ✓ |
| 640×360 | 1 bpp (2 col) | 29 KB | 211 KB | ✓ |
| 960×540 | 1 bpp (2 col) | 64 KB | 176 KB | ✓ |
| 1280×720 | 1 bpp (2 col) | 115 KB | 125 KB | ✓ |

**Practical sweet spots:**
- **320×180 @ 8bpp** — full colour, double buffering, maximum headroom. Ideal for games.
- **640×360 @ 4bpp** — crisp resolution, 16 colours, double buffering. Classic feel.
- **640×360 @ 8bpp** — full colour at high resolution, single buffer only.

---

## 3.5 — Display Modes

| Mode | Name | Description |
|---|---|---|
| 0 | Bitmap | Raw pixel framebuffer |
| 1 | Tile | Grid of reusable 8×8 or 16×16 tiles with scroll |
| 2 | Bitmap + Tile | Tile layer overlaid on bitmap (HUD over scene) |
| 3 | Text | ROM font, character + colour attribute per cell |

---

## 3.6 — Sprite System

| Property | Value |
|---|---|
| Count | 64 sprites |
| Size options | 8×8, 16×16, 32×32 pixels |
| Transparency | Colour index 0 always transparent |
| Priority | Per-sprite: in front of (0) or behind (1) the tile layer; always above bitmap |
| Sprite-sprite priority | Lower index = higher priority |
| Max sprites per scanline | 8 (excess silently skipped) |
| Collision | Global flag: `VSTAT` bit 2, any sprite-sprite opaque overlap, w1c |

The 8 sprites/scanline limit is authentic hardware behaviour. Sprite multiplexing via raster
interrupts can display effectively more than 64 sprites per frame — a celebrated technique
from C64 programming.

### Sprite Attribute Table (SAT) — 8 bytes per sprite

```
Byte 0–1   X position   signed 16-bit
Byte 2–3   Y position   signed 16-bit
Byte 4     Tile index
Byte 5     Flags (MSB→LSB): enable(7) | flip-X(6) | flip-Y(5) | size[4:3] | priority(2) | spare[1:0]
Byte 6     Palette offset
Byte 7     Reserved
```

Sprite bitmaps live in **tile graphics RAM**: address = `$40000 + index × stride`, where
stride = size² × bpp ÷ 8; the index is in units of the sprite's own size. All packed
bit-field lists read **MSB→LSB**.

---

## 3.7 — VRAM Layout

```
$40000 – $43FFF    16 KB    Tile graphics RAM
$44000 – $7FFFF   240 KB    Framebuffer region (one or two buffers)
```

---

## 3.8 — VIC-256 Control Registers (`$80200 – $802FF`)

### Display configuration

| Address | Register | Description |
|---|---|---|
| `$80200` | `VMODE` | Display mode (0–3) |
| `$80201` | `VPALETTE` | Palette depth (0=1bpp, 1=4bpp, 2=reserved, 3=8bpp) |
| `$80202` | `VRESX` | Horizontal resolution: 0=320, 1=640, 2=960, 3=1280 |
| `$80203` | `VRESY` | Vertical resolution: 0=180, 1=360, 2=540, 3=720 |
| `$80204` | `VBGCOL` | Background fill colour index |
| `$80205` | `VTILESIZE` | Tile size (0=8×8, 1=16×16) |

Illegal combinations (or reserved `VPALETTE` 2) → fallback **320×180 @ 8bpp** + `VSTAT` bit 3.

### Framebuffer addressing

| Address | Register | Description |
|---|---|---|
| `$80206` | `VBUFLO` | Front framebuffer base address low byte |
| `$80207` | `VBUFHI` | Front framebuffer base address high byte |
| `$80208` | `VBUF2LO` | Back framebuffer base address low byte |
| `$80209` | `VBUF2HI` | Back framebuffer base address high byte |
| `$8020A` | `VSWAP` | Bit 0: swap front/back buffer at next VBLANK |

### Table pointer registers

| Address | Register | Description |
|---|---|---|
| `$8020B` | `VPALBASE_LO` | Palette RAM base low byte |
| `$8020C` | `VPALBASE_HI` | Palette RAM base high byte |
| `$8020D` | `VSATBASE_LO` | SAT base low byte |
| `$8020E` | `VSATBASE_HI` | SAT base high byte |
| `$8020F` | `VTMAPBASE_LO` | Tile map base low byte |
| `$80210` | `VTMAPBASE_HI` | Tile map base high byte |

All five base pairs hold **address ÷ 16** (16-byte granularity, 1 MB reach). `VBUF`/`VBUF2`
must resolve into VRAM; table bases into `$00000 – $3FFFF`; out of range sets `VSTAT` bit 3.

### Scrolling, sprites, interrupts & status

| Address | Register | Description |
|---|---|---|
| `$80211` | `VSCROLLX` | Tile horizontal fine scroll (0–15 pixels) |
| `$80212` | `VSCROLLY` | Tile vertical fine scroll (0–15 pixels) |
| `$80213` | `VSPRENA` | Sprite enable (1 bit per group of 8) |
| `$80214` | `VSCANLO` | Raster IRQ target scanline low byte |
| `$80215` | `VSCANHI` | Raster IRQ target scanline high byte |
| `$80216` | `VIRQEN` | Bit 0=VBLANK IRQ enable, Bit 1=raster IRQ enable |
| `$80217` | `VSTAT` | Bit 0=VBLANK, Bit 1=raster hit, Bit 2=sprite collision (w1c), Bit 3=mode error (w1c) |
| `$80218 – $802FF` | — | Reserved |

---

## 3.9 — Raster Interrupts

The VIC-256 fires a CPU interrupt at a programmable scanline. Used for: split-screen palette
zones, scroll position changes, copper bar effects, audio sync. Update `VSCANLO/HI` inside
each handler to set the next trigger point for multiple effects per frame.

---

## 3.10 — Double Buffering

Two framebuffers coexist in VRAM when space permits. Writing `1` to `VSWAP` atomically swaps
front and back buffers at the next VBLANK boundary — the `VBUF`/`VBUF2` register contents
are exchanged (visible to reads) and the bit auto-clears.

---

## 3.11 — Timing

60.000 Hz exact: **240,000 CPU cycles per frame** at 14.4 MHz. The emulator interleaves CPU
execution and rendering per scanline (raster handlers work mid-frame).

| Vertical res | Visible | VBLANK | Total lines | Cycles / line |
|---|---|---|---|---|
| 180 | 180 | 20 | 200 | 1200 |
| 360 | 360 | 40 | 400 | 600 |
| 540 | 540 | 60 | 600 | 400 |
| 720 | 720 | 30 | 750 | 320 |

---

## Phase 3 — Key Facts

| Item | Detail |
|---|---|
| VRAM | `$40000 – $7FFFF`, 256KB, pixel/tile data only |
| Tile graphics | `$40000`, up to 16KB |
| Framebuffer region | `$44000 – $7FFFF`, ~240KB |
| Palette RAM | General RAM, `VPALBASE` pointer, 768 bytes |
| SAT | General RAM, `VSATBASE` pointer, 512 bytes |
| Tile map | General RAM, `VTMAPBASE` pointer |
| Display modes | Bitmap, Tile, Bitmap+Tile, Text |
| Colour depths | 1, 4, 8 bpp |
| Sprites | 64 total, 8 max/scanline, 8×8/16×16/32×32 |
| Double buffering | VSWAP register, swaps at VBLANK |
| Raster interrupts | VSCAN registers, programmable scanline |
| Control registers | `$80200 – $802FF` |

---

---

# Phase 4 — AUR-1 Sound Chip Specification

## Overview

The AUR-1 is the Flommodore's audio processor — a register-driven real-time synthesiser
inspired by the C64 SID, Yamaha YM2149, and OPL3. It operates autonomously, generating
stereo 16-bit audio at up to 44.1KHz from its memory-mapped registers at `$80100 – $801FF`.

---

## 4.1 — Voice Architecture

The AUR-1 has **4 voices**, each independently configurable.

| Mode | Description |
|---|---|
| **Standard** | Voice operates independently with its own waveform and ADSR |
| **FM** | Voice pairs with next: modulator + carrier (OPL-style) |

FM pairs: **Voice 0 + Voice 1** and **Voice 2 + Voice 3**.

---

## 4.2 — Waveforms

| ID | Waveform | Character |
|---|---|---|
| 0 | Sine | Pure, smooth tone |
| 1 | Square | Hollow, buzzy — classic chiptune |
| 2 | Triangle | Soft, flute-like |
| 3 | Sawtooth | Bright, brassy, rich harmonics |
| 4 | Pulse | Variable duty cycle (PWM sweep) |
| 5 | Noise | White noise via 16-bit Galois LFSR (taps `$B400`, seeded `$ACE1`) |
| 6 | Wavetable | 256-byte custom waveform, unsigned 8-bit, `$80` = zero cross |
| 7 | Reserved | — |

---

## 4.3 — ADSR Envelope

```
Amplitude
    │         ╱╲
    │        ╱  ╲
    │       ╱    ╲__________
    │      ╱                 ╲
    └────────────────────────────── Time
          A    D    S (held)   R
```

Each of A, D, R: 4-bit time constant — SID-derived rate tables in Phase 4 §4.4 (attack 2 ms–8 s, decay/release 6 ms–24 s, non-linear). S: 4-bit amplitude level.
Packed into 2 bytes: `[A:4][D:4]` and `[S:4][R:4]`.

**Gate bit** (VCTRL bit 7): set = Attack (note on), clear = Release (note off). SID-style.

---

## 4.4 — Filter (SID-inspired)

Shared filter, routable per voice via the global **`AMFILT`** register (bits 0–3 — the sole
routing authority). Chamberlin state-variable filter at the output rate:
`cutoff_hz = 30 + (AFCUT/4095)² × 11970`, `Q = 0.5 + (AFRESON/15) × 9.5`.

| Mode | Type | Character |
|---|---|---|
| 0 | Low-pass | Warm, muffled |
| 1 | High-pass | Thin, bright |
| 2 | Band-pass | Nasal, vocal |
| 3 | Notch | Phaser-like |

Parameters: 12-bit cutoff frequency, 4-bit resonance.

---

## 4.5 — Ring Modulation & Hard Sync (SID-inspired)

**Ring modulation** — multiplies this voice output with the previous voice's (voice 0 pairs with voice 3 — wraparound). Metallic, bell-like timbres.

**Hard sync** — resets oscillator phase when previous voice completes a cycle. Classic growl sound.

Both enabled per-voice via single bits in `VCTRL`.

---

## 4.6 — FM Synthesis (OPL-inspired)

```
Modulator (Voice N)  →  [frequency output]
                              ↓  added to carrier frequency
Carrier (Voice N+1)  →  [audio output]  →  Mixer
```

FM parameters: 16-bit modulation depth, 3-bit feedback. Per sample: carrier phase increment
= `base + ((mod_out × depth) >> 16)`; modulator self-feedback adds `(prev_out × fbk) >> 3`.
Unlocks piano, bells, brass, organ timbres.

---

## 4.7 — Voice Register Map

**Voice N base: `$80100 + (N × $10)`**

| Offset | Register | Description |
|---|---|---|
| `+00` | `VFREQLO` | Frequency low byte |
| `+01` | `VFREQHI` | Frequency high byte — 16-bit **phase increment**: `F = freq × rate / 65536` |
| `+02` | `VWAVE` | Waveform (bits 2:0) \| FM enable (bit 3) |
| `+03` | `VCTRL` | Gate(7) \| Ring mod(6) \| Sync(5) \| bits 4:0 reserved — routing in `AMFILT`, pan in `VVOLL`/`VVOLR` |
| `+04` | `VADSR0` | Attack[7:4] \| Decay[3:0] |
| `+05` | `VADSR1` | Sustain[7:4] \| Release[3:0] |
| `+06` | `VPULSE` | Pulse duty cycle (0–255) |
| `+07` | `VVOL` | Voice volume (8-bit, pre-mixer) |
| `+08` | `VMODLO` | FM modulation depth low byte |
| `+09` | `VMODHI` | FM modulation depth high byte |
| `+0A` | `VFBK` | FM feedback depth (bits 2:0) |
| `+0B` | `VWTBLO` | Wavetable base address low byte |
| `+0C` | `VWTBHI` | Wavetable base address high byte |
| `+0D` | `VVOLR` | Right channel volume (4-bit) |
| `+0E` | `VVOLL` | Left channel volume (4-bit) |
| `+0F` | — | Reserved |

Voice base addresses: Voice 0=`$80100`, Voice 1=`$80110`, Voice 2=`$80120`, Voice 3=`$80130`

---

## 4.8 — Global Register Map (`$80140`)

| Address | Register | Description |
|---|---|---|
| `$80140` | `AMVOL` | Master volume (8-bit) |
| `$80141` | `AMVOLL` | Master left volume (4-bit) |
| `$80142` | `AMVOLR` | Master right volume (4-bit) |
| `$80143` | `AMVOICE` | Voice enable (bits 0–3) |
| `$80144` | `AMFILT` | Voice filter route (bits 0–3) |
| `$80145` | `AFCUTLO` | Filter cutoff low (bits 3:0 of 12-bit) |
| `$80146` | `AFCUTHI` | Filter cutoff high (bits 11:4) |
| `$80147` | `AFRESON` | Filter resonance (4-bit) |
| `$80148` | `AFMODE` | Filter mode (0=LP, 1=HP, 2=BP, 3=Notch) |
| `$80149` | `ASRATE` | Sample rate (0=44.1KHz, 1=22.05KHz, 2=11KHz) |
| `$8014A` | `AIRQEN` | Bit 0: IRQ on envelope completion |
| `$8014B` | `ASTAT` | Bits 0–3: envelope-complete flags (write 1 to clear) |
| `$8014C – $801FF` | — | Reserved |

Mixer: voices sum into signed 32-bit; after master volume the output **saturates** to 16-bit.
`ASRATE` selects the internal synthesis rate; host output stays 44.1 kHz.

---

## 4.9 — Software PCM Playback

The AUR-1 has no built-in sample playback. PCM is implemented via Timer A IRQ: fire at
sample rate, read next byte from buffer, write to `VVOL`, advance pointer.

---

## Phase 4 — Key Facts

| Item | Detail |
|---|---|
| Voices | 4, each 16 bytes of registers |
| Voice bases | `$80100`, `$80110`, `$80120`, `$80130` |
| Global registers | `$80140` |
| Waveforms | Sine, Square, Triangle, Sawtooth, Pulse, Noise, Wavetable |
| Envelope | ADSR per voice, gate-triggered |
| FM pairing | Voice 0+1, Voice 2+3 |
| Filter | Shared LP/HP/BP/Notch, 12-bit cutoff, 4-bit resonance |
| Output | Stereo, 16-bit, up to 44.1KHz |
| Audio IRQ | On envelope completion |
| Control registers | `$80100 – $801FF` |

---

---

# Phase 5 — I/O & Peripherals Specification

## Overview

All I/O devices are memory-mapped into `$80000 – $80FFF`. The CPU reads and writes peripheral
registers exactly like normal memory — no special I/O instructions needed.

---

## 5.1 — System Configuration (`$80000 – $8000F`)

| Address | Register | Description |
|---|---|---|
| `$80000` | `SYSCFG` | Bit 0 = ROM shadow enable |
| `$80001` | `SYSID` | Read-only machine ID (`$F1` = Flommodore) |
| `$80002` | `SYSVER` | Read-only firmware version |
| `$80003` | `SYSPWR` | Bit 0 = soft power off (emulator exits cleanly) |

---

## 5.2 — Timers (`$80010 – $8001F`)

Two independent **16-bit countdown timers**. Each counts down from a reload value at a
configurable divisor, then fires an optional IRQ and reloads (repeat) or stops (one-shot).

**Timer A base: `$80010` — Timer B base: `$80018`**

| Offset | Register | Description |
|---|---|---|
| `+00` | `TxLOADLO` | Reload value low byte |
| `+01` | `TxLOADHI` | Reload value high byte |
| `+02` | `TxCNTLO` | Current count low byte (read-only) |
| `+03` | `TxCNTHI` | Current count high byte (read-only) |
| `+04` | `TxCTRL` | Bit 0 enable \| Bit 1 repeat (0 = one-shot) \| Bit 2 IRQ enable |
| `+05` | `TxDIV` | Clock divisor (0=÷1, 1=÷8, 2=÷64, 3=÷256) |
| `+06` | `TxSTAT` | Bit 0=expired (write 1 to clear) |

At the exact **14.4 MHz** reference clock: ÷8 → 1.8 MHz (PCM: reload 40 → **45.0 kHz exact**, reload 80 → 22.5 kHz), ÷64 → 225 kHz, ÷256 → 56.25 kHz (game logic).

---

## 5.3 — Keyboard (`$80020 – $8002F`)

Scancode-based system with 16-entry key event queue. CPU does not need to poll at cycle speed.

| Address | Register | Description |
|---|---|---|
| `$80020` | `KSTAT` | event available \| queue full \| caps lock \| num lock |
| `$80021` | `KDATA` | Read: dequeue next scancode — 16-bit value, dequeues on **any** read width (use `LW`) |
| `$80022` | `KMOD` | Modifiers: shift \| ctrl \| alt \| super |
| `$80023` | `KCTRL` | IRQ enable \| flush queue |

### Scancode format (16-bit)
```
Bit 15     Key up (1) / key down (0)
Bits 7:0   USB HID scancode
```

---

## 5.4 — Joystick Ports (`$80030 – $8003F`)

Two 9-pin digital joystick ports (Atari/Amiga/C64 standard).

| Address | Register | Description |
|---|---|---|
| `$80030` | `JOY1` | Joystick 1 state |
| `$80031` | `JOY2` | Joystick 2 state |
| `$80032` | `JCTRL` | Bit 0 = IRQ on state change (any bit transition of either port) |

### State byte: `Fire2 | Fire1 | - | - | Right | Left | Down | Up` (1=pressed)

---

## 5.5 — IRQ Controller (`$80040 – $8004F`)

| Address | Register | Description |
|---|---|---|
| `$80040` | `IRQSTAT` | Pending sources (read-only) |
| `$80041` | `IRQMASK` | Enable mask (1 = enabled) |
| `$80042` | `IRQACK` | Write bit to acknowledge and clear |
| `$80043` | — | Reserved (v1.0 `IRQPRI` deleted) |

`IRQSTAT` always shows raw pending state; CPU line = `(IRQSTAT & IRQMASK) ≠ 0`. Device-level
enables gate whether a device sets its bit. All sources enter **IVT entry 2** (software
dispatch, §2.6).

### IRQ source bit map

| Bit | Source |
|---|---|
| 0 | Timer A |
| 1 | Timer B |
| 2 | Keyboard event |
| 3 | Joystick change |
| 4 | VIC-256 VBLANK |
| 5 | VIC-256 raster |
| 6 | AUR-1 envelope complete |
| 7 | Reserved |

---

## 5.6 — Full I/O Address Map

```
$80000 – $8000F    16 B     System config & ID
$80010 – $80017     8 B     Timer A
$80018 – $8001F     8 B     Timer B
$80020 – $8002F    16 B     Keyboard
$80030 – $8003F    16 B     Joystick ports A & B
$80040 – $8004F    16 B     IRQ controller
$80050 – $800FF   176 B     Reserved expansion
$80100 – $801FF   256 B     AUR-1 sound chip
$80200 – $802FF   256 B     VIC-256 video control
$80300 – $80FFF   ~3.5 KB   Reserved
```

---

## Phase 5 — Key Facts

| Item | Address | Detail |
|---|---|---|
| System config | `$80000` | ROM shadow, machine ID, power |
| Timer A | `$80010` | 16-bit, repeat/one-shot, 4 divisors, IRQ |
| Timer B | `$80018` | Same, independent |
| Keyboard | `$80020` | 16-entry queue, USB HID, modifiers |
| Joystick 1 | `$80030` | 4 directions + 2 fire |
| Joystick 2 | `$80031` | Same, independent |
| IRQ controller | `$80040` | 8 sources, maskable, ack, software dispatch via IVT entry 2 |
| Expansion | `$80050` | 176 bytes reserved |

---

---

# Phase 6 — ROM & Boot Sequence

## Overview

The ROM lives at `$FC000 – $FFFFF` (16KB) and is the first code the Gab-16 executes. It
initialises all hardware, provides a stable system call library at fixed addresses, embeds
the font and default palette, then hands off to a program or BIOS shell.

---

## 6.1 — ROM Layout

```
$FC000 – $FC01F    32 B     ROM header
$FC020 – $FC0FF   224 B     Reserved
$FC100 – $FC1FF   256 B     System call jump table (64 × 4 bytes)
$FC200 – $FDFFF   ~7.5 KB   BIOS kernel code
$FE000 – $FF7FF   ~6 KB     Font data + secondary font slot
$FF800 – $FFAFF   768 B     Default palette (256 × 3-byte RGB)
$FFB00 – $FFFBF  1216 B     Reserved
$FFFC0 – $FFFFF    64 B     System vectors (16 × 4 bytes)
```

---

## 6.2 — ROM Header (`$FC000`, 32 bytes)

```
+00  2 B   Magic: $464C  (ASCII "FL" — Flommodore)
+02  1 B   Version major
+03  1 B   Version minor
+04  2 B   Build number
+06  2 B   Feature flags (reserved)
+08  4 B   CRC-32 checksum
+0C  4 B   BIOS kernel entry point
+10  4 B   Font start ($FE000)
+14  4 B   Palette start ($FF800)
+18  8 B   Reserved
```

### Magic number convention

All Flommodore magic numbers use **ASCII-encoded bytes** — readable in hex dumps.

| Magic | Hex | Used for |
|---|---|---|
| `FL` | `$464C` | ROM header |
| `FB` | `$4642` | Autoboot application header |
| `FO` | `$464F` | Object file (.flobj) |

`SYSID` at `$80001` carries `$F1` — a raw byte (not ASCII) for hardware-level identification.

---

## 6.3 — System Call Jump Table (`$FC100`, 64 slots)

Fixed addresses — programs call these forever regardless of ROM version.

### Console & Text

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC100` | 0 | `SYS_PUTCHAR` | Print character in R1 |
| `$FC104` | 1 | `SYS_PUTSTR` | Print null-terminated string at R1 |
| `$FC108` | 2 | `SYS_CLRSCR` | Clear screen, home cursor |
| `$FC10C` | 3 | `SYS_SETCURSOR` | Cursor: R1=col, R2=row |
| `$FC110` | 4 | `SYS_SETCOLOR` | Foreground R1, background R2 |
| `$FC114` | 5 | `SYS_SCROLL` | Scroll up R1 lines |

### Keyboard

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC118` | 6 | `SYS_GETKEY` | Block until key; scancode in R1 |
| `$FC11C` | 7 | `SYS_POLLKEY` | Next key or 0 if empty |
| `$FC120` | 8 | `SYS_GETCHAR` | Block until key; ASCII in R1 |
| `$FC124` | 9 | `SYS_GETLINE` | Read line: R1=buf, R2=max len |

### Video & Palette

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC128` | 10 | `SYS_SETMODE` | R1=mode, R2=res, R3=depth |
| `$FC12C` | 11 | `SYS_SETPAL` | R1=index, R2=RGB24 |
| `$FC130` | 12 | `SYS_LOADPAL` | Load 256-entry palette from R1 |
| `$FC134` | 13 | `SYS_VBLANK` | Block until VBLANK |
| `$FC138` | 14 | `SYS_FILLSCR` | Fill framebuffer with colour R1 |

### Memory

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC13C` | 15 | `SYS_MEMCPY` | R3 bytes from R1 to R2 |
| `$FC140` | 16 | `SYS_MEMSET` | Fill R3 bytes at R1 with R2 |
| `$FC144` | 17 | `SYS_MEMCMP` | Compare R3 bytes R1 vs R2 |

### Sound

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC148` | 18 | `SYS_SNDINIT` | Silence all voices |
| `$FC14C` | 19 | `SYS_SNDPLAY` | R1=voice, R2=freq, R3=wave |
| `$FC150` | 20 | `SYS_SNDSTOP` | Stop voice R1 (trigger release) |
| `$FC154` | 21 | `SYS_SNDVOL` | Set master volume to R1 |

### Timers

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC158` | 22 | `SYS_TSET` | R1=A/B, R2=reload, R3=ctrl |
| `$FC15C` | 23 | `SYS_TWAIT` | Block until timer R1 expires |

### System

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC160` | 24 | `SYS_GETID` | Machine ID in R1, ROM version in R2 |
| `$FC164` | 25 | `SYS_RESET` | Soft reset |
| `$FC168` | 26 | `SYS_IRQSET` | R1=source, R2=handler address |
| `$FC16C` | 27 | `SYS_RAND` | 16-bit random in R1 |
| `$FC170` | 28 | `SYS_SEED` | Seed PRNG with R1 |
| `$FC174 – $FC1FF` | 29–63 | — | Reserved |

---

## 6.4 — Font & Palette

**Font** (`$FE000`): 8×8 monochrome, 256 characters, 2KB. Secondary slot (~4KB) for custom font.

**Default palette** (`$FF800`): xterm-256 layout — Black (index 0, sprite transparent), White,
14-colour home computer set, 6×6×6 RGB cube, 24-step greyscale. Copied to general RAM at boot.

---

## 6.5 — System Vectors (`$FFFC0`)

All vectors are **4 bytes** (32-bit LE, masked to 20 bits); slot *i* at `$FFFC0 + 4×i`,
mirroring the IVT.

| Address | Vector | Destination |
|---|---|---|
| `$FFFC0` | RESET | Boot entry in BIOS kernel |
| `$FFFC4` | NMI | NMI handler (debugger break) |
| `$FFFC8` | IRQ | IRQ dispatcher |
| `$FFFCC` | BRK | Software trap / illegal instruction handler |
| `$FFFD0 – $FFFFF` | — | Reserved slots 4–15 (`$00000000`) |

---

## 6.6 — Boot Sequence

| Stage | Actions |
|---|---|
| 0 — Reset | CPU: FLAGS.S=1, FLAGS.I=0, PC← RESET vector |
| 1 — Init | Load SP=$01100, SSP=$020F0, IVT=$FFFC0 (via MTSR), clear FLAGS except S |
| 2 — RAM clear | Zero-fill zero page, system variables, kernel workspace |
| 3 — Devices | Safe-default all I/O: mute AUR-1, text mode VIC-256, disable timers |
| 4 — Data | Copy palette ROM→RAM, set VPALBASE/VSATBASE/VTMAPBASE |
| 5 — Display | Text mode 640×360, clear screen, print boot banner |
| 6 — Handoff | Enable IRQs (SEI), scan for autoboot at **$04100**, else drop to BIOS shell |
| 7 — Shadow (optional) | Program-initiated: copy ROM to the fixed window `$3C000–$3FFFF`, enable via SYSCFG bit 0 |

---

## 6.7 — Autoboot Header (12 bytes at $04100)

```
+00  2 B   Magic bytes 'F','B' ($46, $42)
+02  2 B   Program version
+04  2 B   Entry point offset from header start (≥ 12)
+06  2 B   Minimum RAM (KB)
+08  4 B   Load address (LE, masked to 20 bits; $04100 for autoboot)
```

---

## 6.8 — BIOS Shell (fallback)

| Command | Description |
|---|---|
| `MEM addr` | Hex dump 256 bytes |
| `POKE addr val` | Write byte |
| `PEEK addr` | Read byte |
| `RUN addr` | Jump and execute |
| `RESET` | Soft reset |
| `VER` | ROM version and machine info |
| `HELP` | List commands |

---

## Phase 6 — Key Facts

| Item | Value | Detail |
|---|---|---|
| ROM | `$FC000 – $FFFFF` | 16KB, shadowable via SYSCFG bit 0 |
| ROM magic | `$464C` (FL) | ASCII convention |
| System calls | 29 defined | Fixed addresses forever |
| Font | `$FE000` | 8×8, 256 chars, 2KB + 4KB secondary |
| Palette | `$FF800` | xterm-256, 768 bytes |
| Vectors | `$FFFC0` | RESET/NMI/IRQ/BRK — 4-byte |
| Autoboot magic | `'F','B'` | 12-byte header at $04100 |

---

---

# Phase 7 — Emulator / Reference Implementation

## Overview

The emulator translates the specification into a running machine and is the definitive
runtime reference: **what the emulator does is what the Flommodore does**.

---

## 7.1 — Technology Stack

| Component | Choice | Reason |
|---|---|---|
| Language | **Zig 0.16** | Cross-compilation, safety, C interop, build system |
| Display | **SDL3** | Raw texture upload for framebuffer |
| Audio | **SDL3** | Stream-based PCM push for AUR-1 synthesis |
| Input | **SDL3** | Raw scancodes, full modifier access |
| Debugger UI | **Dear ImGui** via cimgui | Immediate-mode overlay |
| Build | **build.zig** | No external tool needed |

### Cross-compilation (from any host)

```bash
zig build -Dtarget=x86_64-windows-gnu   # Windows
zig build -Dtarget=x86_64-macos        # macOS
zig build -Dtarget=aarch64-linux       # ARM Linux
```

---

## 7.2 — Source Layout

```
flommodore/
├── build.zig / build.zig.zon
├── src/
│   ├── main.zig       Entry point, main loop
│   ├── bus.zig        Memory bus — address routing
│   ├── ram.zig        512KB flat RAM
│   ├── rom.zig        ROM load and shadow logic
│   ├── cpu.zig        Gab-16 fetch/decode/execute
│   ├── vic256.zig     VIC-256 scanline renderer
│   ├── aur1.zig       AUR-1 real-time synthesiser
│   ├── io.zig         I/O — timers, keyboard, joystick, IRQ
│   ├── debugger.zig   Built-in debugger
│   └── util.zig       Bit ops, logging, sign extend
├── rom/flommodore.rom
└── tests/
    ├── harness.zig    Headless test runner
    └── roms/          Per-component test binaries
```

---

## 7.3 — Memory Bus

Central address decoder. All reads and writes pass through here.

```
$00000–$7FFFF  → RAM
$80000–$80FFF  → I/O
$81000–$FBFFF  → open bus (returns $0000)
$FC000–$FFFFF  → ROM (or the RAM window $3C000–$3FFFF if shadow enabled)
```

All addresses masked to 20 bits; multi-byte accesses route per byte and wrap at `$FFFFF`.
Shadow ROM logic enforced transparently at bus level.

---

## 7.4 — Key Implementation Notes

**Byte order:** Little-endian (low byte at lower address).

**R0:** Any write to register 0 is silently discarded.

**CPU loop:** Check IRQ → fetch two 16-bit words → decode 6-bit opcode → execute → update flags → increment cycle counter.

**VIC-256:** One `render_line()` per scanline, **interleaved with CPU execution** (CYCLES_PER_LINE cycles per line — §3.11). Raster IRQ evaluated per line; VBLANK IRQ after the last visible line. Present to SDL3 texture with nearest-neighbour scaling.

**AUR-1:** Generate `SAMPLES_PER_FRAME` samples after each video frame, push to SDL3 audio stream. Per-voice: advance phase accumulator, generate waveform sample, apply ADSR envelope, apply volume. Noise via 16-bit Galois LFSR.

**Timers:** Advanced once per CPU cycle, prescaled by `TxDIV` (÷1/÷8/÷64/÷256).

**Main loop:** 240,000 cycles/frame exactly (14.4 MHz / 60 Hz), advanced in scanline quanta.

---

## 7.5 — Built-in Debugger

Activated by **F12** or `BRK` instruction. Renders via Dear ImGui alongside the Flommodore screen. Also drivable from text console.

| Feature | Description |
|---|---|
| Register view | All R0–R15, PC, FLAGS, SP, LR, cycle count |
| Disassembler | Instructions around current PC |
| Memory viewer | Hex + ASCII dump |
| Breakpoints | Up to 16 address breakpoints |
| Watchpoints | Halt on read/write to address |
| Step / Step over / Continue | Standard debugger controls |
| VRAM viewer | VRAM rendered as pixels |
| I/O viewer | All I/O register values live |
| Audio monitor | Voice states, envelopes, waveforms |

---

## 7.6 — Test Strategy

Each module has a dedicated test ROM that writes `$FF` to `$00010` on pass. The headless
harness loads each ROM, runs for a fixed cycle count, and reads `$00010`.

| Test ROM | Tests |
|---|---|
| `test_cpu_alu.rom` | ALU ops, flags, overflow |
| `test_cpu_branch.rom` | All branch conditions |
| `test_cpu_load_store.rom` | LW/LB/SW/SB, addressing modes |
| `test_cpu_stack.rom` | PUSH/POP/PUSHA/POPA, nested calls |
| `test_cpu_irq.rom` | IRQ entry/exit, RTI |
| `test_vic_text.rom` | Text mode, font |
| `test_vic_bitmap.rom` | Bitmap, palette, double buffer |
| `test_vic_sprite.rom` | Sprites, priority, collision |
| `test_aur_basic.rom` | Gate, waveforms, ADSR |
| `test_aur_fm.rom` | FM pairing, feedback |
| `test_io_timer.rom` | Timer reload, repeat, IRQ |
| `test_io_kbd.rom` | Queue, overflow, modifiers |

---

## Phase 7 — Key Facts

| Item | Detail |
|---|---|
| Language | Zig 0.16, pinned |
| Libraries | SDL3, Dear ImGui via cimgui |
| Byte order | Little-endian |
| Modules | main, bus, ram, rom, cpu, vic256, aur1, io, debugger, util |
| Main loop | 240,000 cycles/frame, scanline-interleaved |
| Debugger | F12, ImGui overlay, breakpoints, watchpoints |
| Test signal | `$FF` at `$00010` = pass |

---

---

# Phase 8 — Developer Toolchain

## Overview

The toolchain transforms the Flommodore from a machine you can run programs on into one you
can write programs for — assembler, linker, symbol files, and an optional higher-level language.

---

## 8.1 — Pipeline

```
.asm / .fl source
     ↓  flas (assembler)
  .flobj  (relocatable object)
     ↓  fll (linker)
  .flapp  (executable application)
     ↓  flommodore (emulator)
  Running program
```

---

## 8.2 — File Extension Family

| Extension | Magic | Description |
|---|---|---|
| `.asm` | — | Assembly source (plain text) |
| `.flobj` | `$464F` (FO) | Relocatable object file |
| `.flapp` | `$4642` (FB) | Executable application |
| `.flsym` | plain text | Debugger symbol file |
| `.flst` | plain text | Assembler listing file |
| `.flld` | plain text | Linker description script |
| `.fl` | — | FL higher-level language source |

`.flapp` (not `.flrom`) — a program is the opposite of a ROM. `.flst` (not `.lst`) — keeps
the file family consistent. **All file formats are little-endian; magics are defined as byte
sequences** (`'F'`,`'B'` …) so they read correctly in hex dumps.

---

## 8.3 — Assembly Language

NASM/ARM-inspired syntax. `$` hex prefix. `[]` for memory. `;` for comments.

### Directives

| Directive | Description |
|---|---|
| `ORG $addr` | Set assembly address |
| `DB / DW / DD` | Define byte / word / 32-bit double-word |
| `DS n` | n zero bytes |
| `EQU name, val` | Named constant |
| `INCLUDE / INCBIN` | Include source or binary |
| `ALIGN n` | Pad to n-byte boundary |
| `SECTION name` | Named section |

### Macro system

```asm
MACRO LOAD_ADDR reg, addr
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO
```

### Example

```asm
    ORG $04100
    EQU SYS_PUTSTR, $FC104

start:
    LI    R1, msg
    CALLA SYS_PUTSTR
    HLT

msg:
    DB "HELLO, FLOMMODORE!", 0
```

---

## 8.4 — Object File Format (.flobj, magic `$464F`)

Header: magic `'F','O'` (2 B) · version (1 B) · section count (1 B) · **symbol count (2 B)**
· **relocation count (2 B)**. Then section table, symbol table, relocation table, payload.
Relocation types: `ABS16` (DW), `ABS32` (DD), `ABS26` / `PCREL26` (J-format ADDR26),
`LO16` / `HI4` (I-format IMM18 for `LI`/`LUI` pairs). Final addresses resolved by the linker.

---

## 8.5 — Linker Script (.flld)

```
ENTRY start

SECTION code AT $04100
SECTION data AFTER code
SECTION bss  AFTER data
```

The linker resolves symbols, patches relocations, prepends the 12-byte autoboot header
(load address taken from `SECTION code AT` — `ENTRY` only names the entry symbol), and emits
`.flapp` + `.flsym`. `--raw --base $FC000 --size 16K` instead emits a raw padded ROM image
(no header; fails if the vector slots at `$FFFC0` are empty).

---

## 8.6 — Executable Format (.flapp, magic `$4642`)

```
+00  2 B   Magic bytes 'F','B' ($46, $42)
+02  2 B   Program version
+04  2 B   Entry point offset from file start (≥ 12)
+06  2 B   Minimum RAM (KB)
+08  4 B   Load address (LE, masked to 20 bits; $04100 for autoboot)
+0C  N B   Raw binary
```

Loaded verbatim at the load address; execution starts at `load_address + entry_offset`.

---

## 8.7 — Symbol File (.flsym)

Plain text, one symbol per line: `$address  name`. Auto-loaded by debugger if present
alongside the `.flapp`. Enables named breakpoints and annotated disassembly.

---

## 8.8 — Listing File (.flst)

```
$04100  10 41 40 14   start:  LI    R1, msg
$04104  04 C1 0F AC           CALLA SYS_PUTSTR
$04108  18 C1 0F AC           CALLA SYS_GETKEY
$0410C  00 00 00 E4           HLT
```

---

## 8.9 — Assembler Pipeline (two-pass)

```
Source → Lexer → Parser → Macro expansion → Pass 1 (symbols) → Pass 2 (emit) → .flobj
```

Pass 1 collects all symbol names and sizes. Pass 2 emits opcodes resolving all forward
references. Essential for `CALLA forward_label` style code.

---

## 8.10 — Command Line Interface

```bash
# Assembler
flas input.asm -o output.flobj
flas input.asm --listing output.flst -o output.flobj

# Linker
fll main.flobj lib.flobj -s program.flld -o program.flapp
fll *.flobj -s program.flld -o program.flapp -v

# Emulator
flommodore program.flapp
flommodore program.flapp --debug
flommodore --rom custom.rom program.flapp
```

---

## 8.11 — Build System

Zig 0.16 throughout — same language as the emulator, one repository, one build step.

```bash
zig build                              # emulator + assembler + linker (host)
zig build -Dtarget=x86_64-windows-gnu  # cross-compile for Windows
zig build -Dtarget=x86_64-macos        # cross-compile for macOS
zig build test                         # run all tests
```

---

## 8.12 — Optional: FL Language (future phase)

A C-like language compiling to `.asm`, feeding the existing pipeline unchanged. Requires
its own dedicated design phase covering: type system, memory model, calling convention
(must match Gab-16 ABI), compiler architecture, error model, standard library.

```c
// fl_hello.fl
extern fn sys_putstr(s: *u8) void @ $FC104;
fn main() void { sys_putstr("HELLO, FLOMMODORE!"); }
```

---

## Phase 8 — Key Facts

| Tool | Binary | Input | Output |
|---|---|---|---|
| Assembler | `flas` | `.asm` | `.flobj`, `.flst` |
| Linker | `fll` | `.flobj` + `.flld` | `.flapp`, `.flsym` |
| Emulator | `flommodore` | `.flapp` | Running machine |

---

---

# Master Quick Reference

## Complete Address Map

| Range | Size | Contents |
|---|---|---|
| `$00000 – $000FF` | 256 B | Zero Page |
| `$00100 – $010FF` | 4 KB | Default Stack |
| `$01100 – $020FF` | 4 KB | System Variables |
| `$02100 – $040FF` | 8 KB | Kernel Workspace |
| `$04100 – $3FFFF` | ~240 KB | Free RAM |
| `$40000 – $43FFF` | 16 KB | VRAM — Tile graphics |
| `$44000 – $7FFFF` | ~240 KB | VRAM — Framebuffer region |
| `$80000 – $8000F` | 16 B | System config |
| `$80010 – $8001F` | 16 B | Timers A & B |
| `$80020 – $8002F` | 16 B | Keyboard |
| `$80030 – $8003F` | 16 B | Joystick ports |
| `$80040 – $8004F` | 16 B | IRQ controller |
| `$80050 – $800FF` | 176 B | Reserved expansion |
| `$80100 – $801FF` | 256 B | AUR-1 sound chip |
| `$80200 – $802FF` | 256 B | VIC-256 video control |
| `$80300 – $80FFF` | ~3.5 KB | Reserved |
| `$81000 – $FBFFF` | ~492 KB | Open bus (reads $0000) |
| `$FC000 – $FC01F` | 32 B | ROM header |
| `$FC100 – $FC1FF` | 256 B | System call jump table |
| `$FC200 – $FDFFF` | ~7.5 KB | BIOS kernel |
| `$FE000 – $FF7FF` | ~6 KB | Font data |
| `$FF800 – $FFAFF` | 768 B | Default palette |
| `$FFB00 – $FFFBF` | 1216 B | Reserved |
| `$FFFC0 – $FFFFF` | 64 B | System vectors (16 × 4 B) |

## Magic Numbers

| Magic | Hex | Context |
|---|---|---|
| `FL` | bytes `$46,$4C` | ROM header |
| `FB` | bytes `$46,$42` | `.flapp` executable, autoboot header |
| `FO` | bytes `$46,$4F` | `.flobj` object file |
| `$F1` | `$F1` | `SYSID` hardware register |

## System Calls (quick reference)

| ID | Name | ID | Name |
|---|---|---|---|
| 0 | `SYS_PUTCHAR` | 15 | `SYS_MEMCPY` |
| 1 | `SYS_PUTSTR` | 16 | `SYS_MEMSET` |
| 2 | `SYS_CLRSCR` | 17 | `SYS_MEMCMP` |
| 3 | `SYS_SETCURSOR` | 18 | `SYS_SNDINIT` |
| 4 | `SYS_SETCOLOR` | 19 | `SYS_SNDPLAY` |
| 5 | `SYS_SCROLL` | 20 | `SYS_SNDSTOP` |
| 6 | `SYS_GETKEY` | 21 | `SYS_SNDVOL` |
| 7 | `SYS_POLLKEY` | 22 | `SYS_TSET` |
| 8 | `SYS_GETCHAR` | 23 | `SYS_TWAIT` |
| 9 | `SYS_GETLINE` | 24 | `SYS_GETID` |
| 10 | `SYS_SETMODE` | 25 | `SYS_RESET` |
| 11 | `SYS_SETPAL` | 26 | `SYS_IRQSET` |
| 12 | `SYS_LOADPAL` | 27 | `SYS_RAND` |
| 13 | `SYS_VBLANK` | 28 | `SYS_SEED` |
| 14 | `SYS_FILLSCR` | 29–63 | Reserved |

---

*Flommodore Fantasy Computer — Master Specification v1.1*
*All 8 Phases Locked — Block 0 amendments applied — Status: COMPLETE*
