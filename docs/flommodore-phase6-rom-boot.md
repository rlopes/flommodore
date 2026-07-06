# Flommodore — Phase 6: ROM & Boot Sequence

## Overview

The ROM is the Flommodore's firmware — the immutable foundation that brings the machine to
life from a cold power-on. It lives at `$FC000 – $FFFFF` (16KB) and is the first code the
Gab-16 CPU executes.

---

## 6.1 — ROM Goals

The ROM must accomplish four things:

1. **Initialise** all hardware to a known, safe state
2. **Provide** a stable system call library that programs can rely on at fixed addresses
3. **Embed** essential data — the font, the default palette, the machine identity
4. **Hand off** to a user program or drop into the built-in BIOS shell

---

## 6.2 — ROM Layout (16KB, `$FC000 – $FFFFF`)

```
$FC000 – $FC01F    32 B     ROM header
$FC020 – $FC0FF   224 B     Reserved / padding
$FC100 – $FC1FF   256 B     System call jump table
$FC200 – $FDFFF   ~7.5 KB   BIOS kernel code
$FE000 – $FF7FF   ~6 KB     Font data (built-in character set)
$FF800 – $FFAFF   768 B     Default palette (256 × 3-byte RGB)
$FFB00 – $FFFBF  1216 B     Reserved
$FFFC0 – $FFFFF    64 B     System vectors (16 × 4 bytes)
```

---

## 6.3 — ROM Header (`$FC000 – $FC01F`)

A fixed 32-byte structure identifying the firmware:

```
Offset  Size  Field
+00     2 B   Magic number: $464C  (ASCII "FL" for Flommodore)
+02     1 B   ROM version major
+03     1 B   ROM version minor
+04     2 B   ROM build number
+06     2 B   Feature flags (reserved, set to 0)
+08     4 B   ROM checksum (CRC-32 of $FC020 – $FFFBF)
+0C     4 B   BIOS kernel entry point address
+10     4 B   Font data start address ($FE000)
+14     4 B   Default palette start address ($FF800)
+18     4 B   Reserved
+1C     4 B   Reserved
```

### Magic number convention

All Flommodore magic numbers use **ASCII-encoded byte sequences** — each byte is a printable
ASCII character, making them immediately recognisable in a hex dump. This follows the same
convention used by real formats: ELF (`$7F454C46` = `\x7FELF`), PNG (`$89504E47`), and
Amiga IFF (`$464F524D` = `FORM`).

| Magic | Hex | Used for |
|---|---|---|
| `FL` | `$464C` | ROM header, Flommodore identity |
| `FB` | `$4642` | Autoboot program header (`FL`ommodore `B`oot) |

The machine ID register `SYSID` at `$80001` independently carries `$F1` (a raw byte value,
not ASCII) to identify the Flommodore at the hardware register level.

---

## 6.4 — System Call Jump Table (`$FC100 – $FC1FF`)

The jump table is a block of **fixed, permanent addresses** — one `JMPA` instruction per
system call, each 4 bytes wide. Programs call a system function by calling its fixed table
address. The entry jumps to the actual implementation inside the BIOS kernel.

This indirection means the kernel implementation can move between ROM versions while the
public API addresses stay the same forever. Every program ever written for the Flommodore
can call `$FC100` for `SYS_PUTCHAR` regardless of which ROM version is installed.

64 slots × 4 bytes = **256 bytes**, exactly filling the table region.

### System Call Table (first 29 defined)

#### Console & Text Output

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC100` | 0 | `SYS_PUTCHAR` | Print character in R1 at current cursor position |
| `$FC104` | 1 | `SYS_PUTSTR` | Print null-terminated string, address in R1 |
| `$FC108` | 2 | `SYS_CLRSCR` | Clear screen and reset cursor to home |
| `$FC10C` | 3 | `SYS_SETCURSOR` | Set cursor: R1=col, R2=row |
| `$FC110` | 4 | `SYS_SETCOLOR` | Set text foreground(R1) and background(R2) colour index |
| `$FC114` | 5 | `SYS_SCROLL` | Scroll screen up by R1 lines |

#### Keyboard Input

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC118` | 6 | `SYS_GETKEY` | Block until key press; return scancode in R1 |
| `$FC11C` | 7 | `SYS_POLLKEY` | Return next key from queue in R1, or 0 if empty |
| `$FC120` | 8 | `SYS_GETCHAR` | Block until key; return ASCII character in R1 |
| `$FC124` | 9 | `SYS_GETLINE` | Read line into buffer: R1=address, R2=max length |

#### Video & Palette

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC128` | 10 | `SYS_SETMODE` | Set video mode: R1=mode, R2=resolution, R3=depth |
| `$FC12C` | 11 | `SYS_SETPAL` | Set palette entry: R1=index, R2=RGB24 value |
| `$FC130` | 12 | `SYS_LOADPAL` | Load full palette from address in R1 |
| `$FC134` | 13 | `SYS_VBLANK` | Block until next VBLANK |
| `$FC138` | 14 | `SYS_FILLSCR` | Fill framebuffer with colour index in R1 |

#### Memory

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC13C` | 15 | `SYS_MEMCPY` | Copy R3 bytes from R1 to R2 |
| `$FC140` | 16 | `SYS_MEMSET` | Fill R3 bytes at R1 with byte value in R2 |
| `$FC144` | 17 | `SYS_MEMCMP` | Compare R3 bytes at R1 vs R2; result in R1 |

#### Sound

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC148` | 18 | `SYS_SNDINIT` | Initialise AUR-1 to silent default state |
| `$FC14C` | 19 | `SYS_SNDPLAY` | Set voice: R1=voice, R2=freq, R3=waveform |
| `$FC150` | 20 | `SYS_SNDSTOP` | Stop voice R1 (trigger release phase) |
| `$FC154` | 21 | `SYS_SNDVOL` | Set master volume to R1 |

#### Timers

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC158` | 22 | `SYS_TSET` | Configure timer: R1=A/B, R2=reload, R3=ctrl flags |
| `$FC15C` | 23 | `SYS_TWAIT` | Block until timer R1 expires once |

#### System

| Address | ID | Name | Description |
|---|---|---|---|
| `$FC160` | 24 | `SYS_GETID` | Return machine ID in R1, ROM version in R2 |
| `$FC164` | 25 | `SYS_RESET` | Soft reset — full reinitialisation |
| `$FC168` | 26 | `SYS_IRQSET` | Install IRQ handler: R1=source, R2=handler address |
| `$FC16C` | 27 | `SYS_RAND` | Return 16-bit pseudo-random number in R1 |
| `$FC170` | 28 | `SYS_SEED` | Seed the PRNG with value in R1 |
| `$FC174 – $FC1FF` | 29–63 | — | Reserved for future system calls |

---

## 6.5 — Font Data (`$FE000 – $FF7FF`)

The built-in font is an **8×8 pixel monochrome bitmap font** covering the full 256-character
ASCII/extended set.

```
256 characters × 8 bytes per character = 2,048 bytes (2KB)
```

Each character is 8 rows of 8 pixels, one bit per pixel, packed into 8 bytes. The font is
used directly by the VIC-256 in **Text mode (Mode 3)** and by `SYS_PUTCHAR` in all other
modes (rendered in software by the BIOS).

The remaining space in `$FE000 – $FF7FF` (~4KB after the 2KB primary font) holds a
**secondary font slot** available for a user-defined custom font loaded at runtime, or
additional built-in glyphs such as box-drawing characters and symbols.

---

## 6.6 — Default Palette (`$FF800 – $FFAFF`)

A 256-entry default palette stored in ROM, packed as **3 bytes per entry** (R, G, B):

```
256 entries × 3 bytes = 768 bytes
```

The default palette follows a well-structured layout:

```
Index 0          Black (transparent convention for sprites)
Index 1          White
Index 2 – 15     Standard 14-colour home computer palette
                 (reds, greens, blues, yellows, cyans, magentas, greys)
Index 16 – 231   6×6×6 RGB colour cube
Index 232 – 255  24-step greyscale ramp
```

This matches the **xterm-256 colour convention** — a widely known layout giving programmers
immediate access to a broad, organised colour space without needing to define their own palette
for general use.

At boot, the BIOS copies this palette from ROM into palette RAM in general RAM (pointed to
by `VPALBASE`).

---

## 6.7 — System Vectors (`$FFFC0 – $FFFFF`)

All vectors are **4 bytes** — 32-bit little-endian values masked to 20 bits. Slot *i* lives
at `$FFFC0 + 4×i`, mirroring the IVT layout (Phase 2 §2.6).

```
$FFFC0 – $FFFC3   RESET vector   → boot entry point in BIOS kernel
$FFFC4 – $FFFC7   NMI vector     → NMI handler (debugger break)
$FFFC8 – $FFFCB   IRQ vector     → IRQ dispatcher in BIOS kernel
$FFFCC – $FFFCF   BRK vector     → BRK / software trap / illegal instruction handler
$FFFD0 – $FFFFF   Reserved (slots 4–15, contain $00000000)
```

These are the values the CPU reads at power-on from ROM. After boot, programs may install
their own IRQ and BRK handlers via `SYS_IRQSET` — which updates the BIOS-side dispatch
table, not the ROM vectors themselves.

---

## 6.8 — Boot Sequence

### Stage 0 — Hardware reset
The Gab-16 CPU asserts its reset state: `FLAGS.S = 1`, `FLAGS.I = 0`, loads `PC` from the
4-byte RESET vector at `$FFFC0`. Execution begins in ROM.

### Stage 1 — CPU & stack initialisation
```
· Load SP with $01100 (empty-descending; 4-byte stack slots stay word-aligned)
· Load SSP with $020F0 (16-slot supervisor stack at top of System Variables)
· Load IVT register with ROM vector table address ($FFFC0) via MTSR
· Clear FLAGS except S (remain in supervisor mode)
```

### Stage 2 — RAM clear
```
· Zero-fill Zero Page        ($00000 – $000FF)
· Zero-fill System Variables ($01100 – $020FF)
· Zero-fill Kernel Workspace ($02100 – $040FF)
```

### Stage 3 — Device initialisation
```
· Write safe defaults to all I/O registers
· AUR-1:      mute all voices, disable IRQ
· VIC-256:    set text mode, 640×360, point to default palette
· Timers:     disable both, clear status flags
· Keyboard:   flush queue, enable key-event IRQ
· Joystick:   enable read, disable IRQ
· IRQ ctrl:   mask all sources initially
```

### Stage 4 — Data setup
```
· SYS_MEMCPY: copy default palette from ROM ($FF800) → palette RAM in general RAM
· Write palette RAM address → VPALBASE registers
· Write SAT address in general RAM → VSATBASE registers
· Write tile map address in general RAM → VTMAPBASE registers
  (BIOS conventions: palette RAM $02100–$023FF, SAT $02400–$025FF,
   text matrix from $02600 — all in Kernel Workspace)
```

### Stage 5 — Display bring-up
```
· Set VIC-256 to Text Mode (Mode 3), 640×360
· Clear screen via SYS_CLRSCR
· Print boot banner:

  ╔══════════════════════════════╗
  ║   FLOMMODORE  v1.0           ║
  ║   512KB RAM  ·  16KB ROM     ║
  ║   GAB-16 CPU @ 14.4MHz       ║
  ╚══════════════════════════════╝
  READY.
```

### Stage 6 — IRQ enable & handoff
```
· Install default IRQ dispatcher into IVT
· Enable IRQ sources: VBLANK, Timer A, Keyboard (via IRQMASK)
· Set FLAGS.I = 1 (SEI — enable CPU interrupts)
· Scan for autoboot: check for a valid program header at the canonical load address $04100
    → If found and RAM requirement met: jump to program entry point
    → If not found:                     drop into BIOS shell
```

### Stage 7 — ROM shadowing (optional, program-initiated)

ROM shadowing is **never initiated by the BIOS**. The shadow source is the **fixed window
`$3C000 – $3FFFF`** (top 16KB of general RAM): while SYSCFG bit 0 is set, the bus maps
`$FC000 + offset ↔ $3C000 + offset` for both reads and writes. The procedure is:

```
1. SYS_MEMCPY: copy ROM ($FC000 – $FFFFF) → $3C000 – $3FFFF
2. Apply patches to the RAM copy
   (replace system calls, install custom font, fix bugs, etc.)
3. Write 1 to SYSCFG bit 0 ($80000) → ROM shadow enabled
4. All accesses to $FC000–$FFFFF now resolve to the window — the
   shadowed "ROM" is live-patchable
5. To restore ROM: write 0 to SYSCFG bit 0
```

**Important:** the CPU must not enable shadowing until the copy is complete and verified —
enabling the bit first means executing uninitialised RAM. Enabling shadow permanently costs
the top 16KB of free RAM by convention; programs intending to shadow must not place data in
the window. The BIOS provides no guard — it is the programmer's responsibility.

---

## 6.9 — Autoboot Program Header

A program is considered bootable if it begins with a valid **12-byte header** at the
canonical load address **$04100**. The BIOS checks for this header during Stage 6.

```
Offset  Size  Field
+00     2 B   Magic bytes 'F','B' ($46, $42 — Flommodore Boot)
+02     2 B   Program version
+04     2 B   Entry point offset from header start (≥ 12)
+06     2 B   Minimum RAM required (in KB)
+08     4 B   Load address (little-endian, masked to 20 bits; $04100 for autoboot)
```

The file image (header + payload) is loaded verbatim at the load address; execution begins
at `load_address + entry_offset`.

### Magic number rationale

`$4642` encodes the ASCII characters `F` (`$46`) and `B` (`$42`), standing for
**F**lommodore **B**oot. It is unambiguous in a hex dump, follows the ASCII magic convention
established by the ROM header, and is distinct from the ROM's own `$464C` (`FL`) magic.

If the BIOS finds the `'F','B'` magic at $04100 and the RAM requirement is satisfied,
it jumps to `load_address + entry_point_offset`. Otherwise it prints a brief diagnostic and
drops to the BIOS shell.

---

## 6.10 — BIOS Shell

If no autoboot program is found, the Flommodore drops into a minimal interactive **BIOS
shell** — a command-line monitor in the spirit of the C64's READY prompt and classic machine
code monitors of the era.

| Command | Description |
|---|---|
| `MEM addr` | Hex dump 256 bytes from addr |
| `POKE addr val` | Write byte val to addr |
| `PEEK addr` | Read and print byte at addr |
| `RUN addr` | Jump to address and execute |
| `LOAD` | Load a program (reserved for storage device support) |
| `RESET` | Soft reset — re-run full boot sequence |
| `VER` | Print ROM version and machine info |
| `HELP` | List available commands |

---

## Phase 6 — Key Facts (carry forward to all phases)

| Item | Address / Value | Detail |
|---|---|---|
| ROM range | `$FC000 – $FFFFF` | 16KB, read-only unless shadowed |
| ROM header magic | `$464C` (`FL`) | ASCII convention, readable in hex dumps |
| ROM header | `$FC000` | 32 bytes, version, checksum, entry points |
| System call table | `$FC100` | 64 slots × 4 bytes, fixed addresses forever |
| System calls defined | 29 | Text, keyboard, video, sound, memory, timers, system |
| Font | `$FE000` | 8×8 bitmap, 256 chars, 2KB primary + ~4KB secondary slot |
| Default palette | `$FF800` | 256 × RGB, xterm-256 layout, copied to RAM at boot |
| System vectors | `$FFFC0` | RESET / NMI / IRQ / BRK — 4-byte vectors |
| Boot stages | 0 – 6 | Reset → init → RAM clear → devices → data → display → handoff |
| ROM shadow | Optional | Program-initiated, fixed window `$3C000–$3FFFF`, toggle via SYSCFG bit 0 |
| Autoboot magic | `$4642` (`FB`) | ASCII "FB" — Flommodore Boot |
| BIOS shell | Fallback | MEM / POKE / PEEK / RUN / RESET / VER / HELP |

---

*Flommodore Fantasy Computer — Design Document*
*Phase 6: ROM & Boot Sequence — Status: LOCKED (v1.1 — Block 0 amendments applied)*
