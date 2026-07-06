# Flommodore — Phase 3: VIC-256 Video Chip Specification

## Overview

The VIC-256 is the Flommodore's graphics processor. It operates autonomously, continuously
reading from its dedicated 256KB VRAM region (`$40000 – $7FFFF`) and generating a video signal.
The CPU communicates with it via control registers at `$80200 – $802FF` and by writing directly
into VRAM and general RAM.

---

## 3.1 — Design Philosophy

The VIC-256 supports three display paradigms that can be layered:

- **Bitmap mode** — pixel-perfect framebuffer, full creative freedom
- **Tile mode** — efficient background rendering using reusable 8×8 or 16×16 tiles
- **Sprite layer** — hardware sprites composited on top of the background

All three can be active simultaneously with a defined priority order:
**Sprites > Tile layer > Bitmap layer > Background colour**

---

## 3.2 — Colour Palette System

The VIC-256 supports three palette modes selected via control registers.

| Mode | Bits/pixel | Colours | Typical use |
|---|---|---|---|
| **1-bit** | 1 bpp | 2 | Monochrome, text, overlays |
| **4-bit** | 4 bpp | 16 | Classic home computer style |
| **8-bit** | 8 bpp | 256 | Full VIC-256 palette |

Each palette entry is a **24-bit RGB** value (8 bits per channel). The full 256-entry palette
table occupies 256 × 3 = **768 bytes**, stored in general RAM at the address pointed to by the
`VPALBASE` control register.

---

## 3.3 — Memory Architecture

### What lives where

Palette data, the Sprite Attribute Table (SAT), and tile maps are **small, frequently updated
tables** that the CPU needs to manipulate constantly. Rather than consuming VRAM, they live in
**general RAM** (`$04100` onwards) at addresses pointed to by VIC-256 control registers. The CPU
can read and write them with ordinary load/store instructions.

VRAM (`$40000 – $7FFFF`) is reserved exclusively for **pixel and tile graphics data** — the
framebuffer and tile graphics RAM. This gives the framebuffer the maximum possible space.

```
General RAM (CPU-side, pointed to by VIC-256 registers)
  Palette RAM      768 B     256 × 3 bytes (24-bit RGB entries)
  SAT              512 B     64 sprites × 8 bytes
  Tile map         up to 8KB depending on resolution and tile size

VRAM ($40000 – $7FFFF, 256KB — pixel data only)
  Tile graphics    up to 16KB
  Framebuffer(s)   remainder — up to 256KB
```

### VIC-256 pointer registers

The VIC-256 is told where to find its tables via three base-address control registers:

| Register | Points to |
|---|---|
| `VPALBASE` | Palette RAM base address in general RAM |
| `VSATBASE` | Sprite Attribute Table base address in general RAM |
| `VTMAPBASE` | Tile map base address in general RAM |

This design means tile maps and sprite attributes are just normal RAM — the CPU manipulates
them with no special access mechanism, and the VIC-256 reads them autonomously each frame.

---

## 3.4 — Resolutions & VRAM Budget

The resolution and colour depth must fit within the **full 256KB of VRAM** (since palette, SAT,
and tile map now live in general RAM). Tile graphics occupy up to 16KB of VRAM, leaving the
remainder for the framebuffer.

### Framebuffer sizes

| Resolution | Aspect | 1 bpp | 4 bpp | 8 bpp |
|---|---|---|---|---|
| 320×180 | 16:9 | 7 KB | 28 KB | 56 KB |
| 640×360 | 16:9 | 29 KB | 115 KB | 225 KB |
| 960×540 | 16:9 | 64 KB | 253 KB ✗ | — |
| 1280×720 | 16:9 | 115 KB | — | — |

Entries marked ✗ exceed 256KB and are not supported.

### Supported mode summary (framebuffer + 16KB tile graphics ≤ 256KB)

| Resolution | Colour depth | Framebuffer | Tile graphics | Total | Remaining |
|---|---|---|---|---|---|
| 320×180 | 8 bpp (256 col) | 56 KB | 16 KB | 72 KB | 184 KB |
| 320×180 | 4 bpp (16 col) | 28 KB | 16 KB | 44 KB | 212 KB |
| 640×360 | 8 bpp (256 col) | 225 KB | 16 KB | 241 KB | 15 KB |
| 640×360 | 4 bpp (16 col) | 115 KB | 16 KB | 131 KB | 125 KB |
| 640×360 | 1 bpp (2 col) | 29 KB | 16 KB | 45 KB | 211 KB |
| 960×540 | 1 bpp (2 col) | 64 KB | 16 KB | 80 KB | 176 KB |
| 1280×720 | 1 bpp (2 col) | 115 KB | 16 KB | 131 KB | 125 KB |

### Double buffering availability

Double buffering requires two full framebuffers in VRAM simultaneously. The remaining VRAM
column above must accommodate a second framebuffer of the same size.

| Resolution | Colour depth | Double buffer possible? |
|---|---|---|
| 320×180 | 8 bpp | ✓ (2 × 56KB = 112KB, fits easily) |
| 320×180 | 4 bpp | ✓ (2 × 28KB = 56KB) |
| 640×360 | 8 bpp | ✗ (2 × 225KB = 450KB, exceeds VRAM) |
| 640×360 | 4 bpp | ✓ (2 × 115KB = 230KB, fits with tile graphics) |
| 640×360 | 1 bpp | ✓ |
| 960×540 | 1 bpp | ✓ |
| 1280×720 | 1 bpp | ✓ |

**Practical sweet spots:**
- **320×180 @ 8bpp** — full 256-colour palette, comfortable double buffering, maximum tile and
  sprite headroom. Ideal for games.
- **640×360 @ 4bpp** — crisp resolution, 16 colours, double buffering available. Classic feel.
- **640×360 @ 8bpp** — full colour at high resolution, single buffer only. Ideal for demos and
  static or slow-scrolling scenes.

---

## 3.5 — Display Modes

### Mode 0 — Bitmap
Raw pixel framebuffer. Each pixel is 1, 4, or 8 bits wide depending on palette mode.
Framebuffer base address set via `VBUFLO/HI` control registers.

### Mode 1 — Tile
Screen divided into a grid of tiles. Each tile is an 8×8 or 16×16 block stored once in VRAM
tile graphics RAM, referenced by index in the tile map (in general RAM).

- **Tile map** — one byte per cell referencing a tile index (in general RAM via `VTMAPBASE`)
- **Tile graphics** — up to 256 tiles stored in VRAM tile graphics area
- **Scroll registers** — `VSCROLLX` / `VSCROLLY` for pixel-level fine scrolling

### Mode 2 — Bitmap + Tile overlay
Tile layer rendered over the bitmap layer. Useful for HUD elements (score, status) drawn as
tiles over a full framebuffer game scene.

### Mode 3 — Text
Special case of tile mode using the built-in ROM font (from `$FE000` in ROM). Each screen cell
stores a character code and a colour attribute byte. No custom tile data needed. Intended for
the BIOS shell, debug output, and simple text applications.

---

## 3.6 — Sprite System

The VIC-256 supports **64 hardware sprites**.

| Property | Value |
|---|---|
| Count | 64 sprites |
| Size options | 8×8, 16×16, 32×32 pixels |
| Colour depth | Shares the active palette mode |
| Transparency | Colour index 0 is always transparent |
| Priority | Per-sprite: in front of (0) or behind (1) the tile layer — always above the bitmap layer |
| Sprite-sprite priority | Lower sprite index = higher priority |
| Collision detection | Global flag: `VSTAT` bit 2 sets on any sprite-sprite opaque-pixel overlap (write-1-to-clear) |
| Max sprites per scanline | 8 (excess silently skipped) |

### Sprites per scanline — explained

The VIC-256 generates video one **scanline** (horizontal line) at a time. On each scanline it
must determine every sprite's pixel contribution in real time. The chip has 8 hardware sprite
rendering units — it can actively process 8 sprites per scanline. If more than 8 sprites overlap
the same scanline, the lowest-priority ones (highest index numbers) are silently skipped on
that line.

This is a deliberate, authentic constraint. Classic techniques to work around it include:

- **Distribute sprites vertically** — arrange sprites so they do not all crowd the same
  scanline range
- **Sprite multiplexing** — use raster interrupts to redefine sprite positions and graphics
  mid-frame, effectively showing far more than 64 sprites per frame by reusing sprite slots
  across different screen regions. This is a celebrated technique from C64 programming.

### Sprite Attribute Table (SAT)

The SAT lives in general RAM (pointed to by `VSATBASE`). Each sprite occupies **8 bytes**:

```
Byte 0–1   X position   signed 16-bit, allows off-screen positioning
Byte 2–3   Y position   signed 16-bit
Byte 4     Tile index   which sprite graphic tile to display
Byte 5     Flags        enable(bit 7) | flip-X(6) | flip-Y(5) | size[4:3] (0=8×8, 1=16×16, 2=32×32) | priority(2) | spare[1:0]
Byte 6     Palette offset   shifts which palette entries are used for this sprite
Byte 7     Reserved
```

64 sprites × 8 bytes = **512 bytes** for the full SAT.

All packed bit-field lists in this specification read **MSB→LSB**. The priority bit:
0 = sprite in front of the tile layer; 1 = behind the tile layer but in front of the
bitmap layer (C64-style).

### Sprite graphics storage

Sprite bitmaps live in the **tile graphics RAM** at `$40000`. Graphic address =
`$40000 + index × stride`, where stride = size² × bpp ÷ 8 (8×8 @ 8bpp = 64 B …
32×32 @ 8bpp = 1024 B). The SAT tile index is in units of the sprite's own size, so larger
sprites address proportionally fewer slots in the 16 KB region (16 max at 32×32 @ 8bpp).

---

## 3.7 — VRAM Layout

Total VRAM: **256KB** at `$40000 – $7FFFF`. Exclusively pixel and tile graphics data.

```
$40000 – $43FFF    16 KB    Tile graphics RAM (256 tiles × 8×8 @ 8bpp)
$44000 – $7FFFF   240 KB    Framebuffer region (one or two buffers, mode dependent)
```

The framebuffer base address and optional back buffer address are set via control registers,
allowing flexible placement within the framebuffer region.

### Tile graphics detail

| Tile size | Depth | Bytes/tile | 256 tiles total |
|---|---|---|---|
| 8×8 | 8 bpp | 64 B | 16 KB |
| 8×8 | 4 bpp | 32 B | 8 KB |
| 16×16 | 8 bpp | 256 B | 64 KB (first 64 tiles only in 16KB budget) |
| 16×16 | 4 bpp | 128 B | 32 KB (first 128 tiles in budget) |

For 16×16 tiles the 16KB tile graphics area supports fewer than 256 tiles. The tile count
limit at 16×16 is noted in the `VTILESIZE` register description.

---

## 3.8 — VIC-256 Control Registers (`$80200 – $802FF`)

### Display configuration

| Address | Register | Description |
|---|---|---|
| `$80200` | `VMODE` | Display mode (0=Bitmap, 1=Tile, 2=Bitmap+Tile, 3=Text) |
| `$80201` | `VPALETTE` | Palette depth (0=1bpp, 1=4bpp, 2=reserved, 3=8bpp) |
| `$80202` | `VRESX` | Horizontal resolution: 0=320, 1=640, 2=960, 3=1280 |
| `$80203` | `VRESY` | Vertical resolution: 0=180, 1=360, 2=540, 3=720 |
| `$80204` | `VBGCOL` | Background fill colour index (shown behind all layers) |
| `$80205` | `VTILESIZE` | Tile size (0=8×8, 1=16×16) |

An illegal resolution/depth combination (or the reserved `VPALETTE` value 2) puts the
VIC-256 into fallback mode **320×180 @ 8bpp** and sets `VSTAT` bit 3 (mode error).

### Framebuffer addressing

| Address | Register | Description |
|---|---|---|
| `$80206` | `VBUFLO` | Front framebuffer base address low byte |
| `$80207` | `VBUFHI` | Front framebuffer base address high byte |
| `$80208` | `VBUF2LO` | Back framebuffer base address low byte |
| `$80209` | `VBUF2HI` | Back framebuffer base address high byte |
| `$8020A` | `VSWAP` | Bit 0: swap front/back buffer at next VBLANK |

### Table base address pointers (point into general RAM)

| Address | Register | Description |
|---|---|---|
| `$8020B` | `VPALBASE_LO` | Palette RAM base address low byte |
| `$8020C` | `VPALBASE_HI` | Palette RAM base address high byte |
| `$8020D` | `VSATBASE_LO` | Sprite Attribute Table base address low byte |
| `$8020E` | `VSATBASE_HI` | Sprite Attribute Table base address high byte |
| `$8020F` | `VTMAPBASE_LO` | Tile map base address low byte |
| `$80210` | `VTMAPBASE_HI` | Tile map base address high byte |

All five base-address register pairs (`VBUF`, `VBUF2`, `VPALBASE`, `VSATBASE`, `VTMAPBASE`)
hold the target **address ÷ 16** as a 16-bit value (LO = bits 7:0, HI = bits 15:8 of the
shifted value) — 16-byte granularity giving full 1 MB reach. `VBUF`/`VBUF2` must resolve
into `$40000 – $7FFFF`; the three table bases into `$00000 – $3FFFF`. Out-of-range values
set `VSTAT` bit 3.

### Scrolling

| Address | Register | Description |
|---|---|---|
| `$80211` | `VSCROLLX` | Tile layer horizontal fine scroll offset (0–15 pixels) |
| `$80212` | `VSCROLLY` | Tile layer vertical fine scroll offset (0–15 pixels) |

### Sprite control

| Address | Register | Description |
|---|---|---|
| `$80213` | `VSPRENA` | Sprite enable flags (1 bit per group of 8 sprites) |

### Interrupts & status

| Address | Register | Description |
|---|---|---|
| `$80214` | `VSCANLO` | Raster interrupt target scanline low byte |
| `$80215` | `VSCANHI` | Raster interrupt target scanline high byte |
| `$80216` | `VIRQEN` | Bit 0=VBLANK IRQ enable, Bit 1=raster IRQ enable |
| `$80217` | `VSTAT` | Bit 0=VBLANK, Bit 1=raster hit, Bit 2=sprite collision (w1c), Bit 3=mode error (w1c) |
| `$80218 – $802FF` | — | Reserved for future VIC-256 features |

---

## 3.9 — Raster Interrupts

The VIC-256 can fire a CPU interrupt at a programmable scanline number. This is the classic
technique used on the C64 and Amiga to:

- Split the screen into zones with different palettes or scroll positions
- Trigger audio events in sync with specific video frames
- Implement visual effects such as copper bars, wobble, and palette cycling

Set `VSCANLO/HI` to the target scanline, enable via `VIRQEN`, and the VIC-256 asserts the
raster IRQ when the beam reaches that line. Multiple effects per frame can be achieved by
updating `VSCANLO/HI` inside each raster IRQ handler to set the next trigger point.

---

## 3.10 — Double Buffering

When VRAM permits (see §3.4), two framebuffers can coexist:

- **Front buffer** — currently displayed by VIC-256
- **Back buffer** — being drawn to by the CPU

Writing `1` to the `VSWAP` register bit causes the VIC-256 to atomically swap front and back
buffer pointers at the next VBLANK boundary, eliminating screen tearing. The pending bit is
readable until the swap; at VBLANK the `VBUF` and `VBUF2` register contents are exchanged
(visible to subsequent reads) and the bit auto-clears.

---

## 3.11 — Timing & Sync

| Property | Value |
|---|---|
| Frame rate | 60.000 Hz exact — 240,000 CPU cycles per frame at 14.4 MHz |
| VBLANK IRQ | Fired at the start of the first VBLANK line; VSTAT bit 0 clears at line 0 |
| Raster IRQ | Asserted at the start of the VSCAN target visible line |
| CPU VRAM access | Allowed at all times (no wait states) |

### Scanline timing tables

| Vertical res | Visible lines | VBLANK lines | Total lines | CPU cycles / line |
|---|---|---|---|---|
| 180 | 180 | 20 | 200 | 1200 |
| 360 | 360 | 40 | 400 | 600 |
| 540 | 540 | 60 | 600 | 400 |
| 720 | 720 | 30 | 750 | 320 |

Every row satisfies total × cycles/line = 240,000. The emulator interleaves CPU execution
and rendering per scanline, so raster IRQ handlers can change VIC registers mid-frame —
the mechanism behind sprite multiplexing and split-screen effects.

---

## Phase 3 — Key Facts (carry forward to all phases)

| Item | Detail |
|---|---|
| VRAM | `$40000 – $7FFFF`, 256KB, pixel/tile data only |
| Tile graphics | `$40000`, up to 16KB, 256 tiles @ 8×8/8bpp |
| Framebuffer region | `$44000 – $7FFFF`, ~240KB, base address configurable |
| Palette RAM | General RAM, pointed to by `VPALBASE` registers, 768 bytes |
| SAT | General RAM, pointed to by `VSATBASE` registers, 512 bytes |
| Tile map | General RAM, pointed to by `VTMAPBASE` registers |
| Display modes | Bitmap, Tile, Bitmap+Tile, Text |
| Colour depths | 1, 4, 8 bpp |
| Sweet spot modes | 320×180@8bpp, 640×360@4bpp, 640×360@8bpp (single buffer) |
| Sprites | 64 total, 8 max per scanline, 8×8/16×16/32×32 |
| Sprite transparency | Colour index 0 always transparent |
| Double buffering | Via VSWAP register, swaps at VBLANK |
| Raster interrupts | Programmable scanline trigger via VSCAN registers |
| Control registers | `$80200 – $802FF` |

---

*Flommodore Fantasy Computer — Design Document*
*Phase 3: VIC-256 Video Chip Specification — Status: LOCKED (v1.1 — Block 0 amendments applied)*
