# Flommodore — Phase 1: Memory Map Architecture

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
                           · Sprite graphics bitmaps (the SAT itself lives in general RAM — Phase 3)
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

All vectors are **4 bytes** — 32-bit little-endian values masked to 20 bits (a 2-byte vector
cannot hold a 20-bit ROM address). Vector slot *i* lives at `$FFFC0 + 4×i`, mirroring the
IVT layout (Phase 2 §2.6).

| Address | Index | Name | Purpose |
|---|---|---|---|
| `$FFFC0 – $FFFC3` | 0 | `RESET` | Boot entry point |
| `$FFFC4 – $FFFC7` | 1 | `NMI` | Non-maskable interrupt (debugger break) |
| `$FFFC8 – $FFFCB` | 2 | `IRQ` | All maskable device interrupts (software dispatch) |
| `$FFFCC – $FFFCF` | 3 | `BRK` | Software trap / illegal instruction |
| `$FFFD0 – $FFFFF` | 4–15 | — | Reserved (contain `$00000000`) |

---

## 1.7 — ROM Shadowing

The shadow source is a **fixed window: `$3C000 – $3FFFF`** (the top 16KB of general RAM).
When the shadow enable bit (`SYSCFG` bit 0 at `$80000`) is set, the bus maps
`$FC000 + offset ↔ $3C000 + offset` for **both reads and writes** — the shadowed "ROM" is
live-patchable. This allows:

- Patching system calls
- Replacing the built-in font
- Installing a custom kernel

A program copies the ROM image into the window, applies patches, then sets the bit (full
procedure in Phase 6 §6.8 Stage 7). Enabling shadow costs the top 16KB of free RAM by
convention — programs intending to shadow must not place data there.

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

## Phase 1 — Key Facts (carry forward to all phases)

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

*Flommodore Fantasy Computer — Design Document*
*Phase 1: Memory Map Architecture — Status: LOCKED (v1.1 — Block 0 amendments applied)*
