# Flommodore — Block 0 Specification Amendments (v1.1)

**Status: LOCKED (2026-06-12) — supersedes the listed sections of the Phase 1–8 documents and master specification v1.0. Propagated into the v1.1 document set.**

This document is the output of the pre-implementation design audit (2026-06-12). Each section contains normative replacement text. Section 10 maps every audit finding to its fix. Where this document and a v1.0 document disagree, this document wins.

---

## 0. Decision Register

| # | Decision | Outcome |
|---|---|---|
| D1 | Register/address model | 20-bit register writes everywhere; flags from low 16 bits |
| D2 | LI/LUI semantics | LI sign-extends to 20 bits; LUI ORs bits 19:16 non-destructively |
| D3 | Vector width & location | 4-byte vectors; system vectors at $FFFC0–$FFFFF; IVT = 64 B |
| D4 | Supervisor stack | New SSP special register |
| D5 | Interrupt frame | 8 bytes: PC (4 B) then FLAGS (4 B) — amended by D34 |
| D6 | Special register access | New MFSR/MTSR instructions |
| D7 | SYS instruction | Dropped from v1; opcode reserved |
| D8 | Flag semantics & memory edges | Per-op table §1.6; per-byte boundary routing; wrap at $FFFFF |
| D9 | ROM shadow | Fixed window $3C000–$3FFFF |
| D10 | Program loading | Canonical load address $04100; `.flapp` header v1.1 with load-address field |
| D11 | Palette ROM slot | $FF800–$FFAFF (768 B) |
| D12 | Boot SP | $01100 |
| D13 | IRQ dispatch | Software dispatch via IVT entry 2; IRQPRI deleted |
| D14 | I/O access model | 16-bit register per address; exact-address LW/SW |
| D15 | Timer control | One-shot bit removed; one-shot ≡ repeat=0 |
| D16 | Master clock | **14,400,000 Hz** |
| D17 | Instruction timing | 1 cycle per instruction, uniform |
| D18 | Video timing | Per-mode line tables, §5.6 |
| D19 | 5bpp mode | Dropped from v1 |
| D20 | Sprite collision | Single global VSTAT flag, w1c |
| D21 | Sprite priority bit | 0 = front of tiles, 1 = behind tiles |
| D22 | VRESX/Y encodings | §5.2 |
| D23 | VIC base registers | Hold address ÷ 16 |
| D24 | Text mode & sprite storage | §5.4, §5.5; global MSB→LSB bit-field convention |
| D25 | Filter routing | AMFILT only; VCTRL bit removed |
| D26 | Panning | VVOLL/VVOLR only; VCTRL Pan bits removed |
| D27 | AUR-1 numeric model | §6 |
| D28–D31 | Toolchain formats | §8 |
| D32 | Opcode assignment | One opcode per instruction; FUNC/FLAGS fields reserved-zero; full table §1.3 |
| D33 | ORG vs sections | ORG = absolute mode only; mixing with SECTION is an error |
| D34 | Stack slot width | **4 bytes per slot** (derived from D1) |
| D35 | Opcode $00 | **Illegal — traps to BRK** (runaway-code safety) |

---

## 1. Gab-16 CPU — Corrections (supersedes Phase 2 §2.1–§2.7, Phase 7 §7.6 excerpts)

### 1.1 Register model (replaces Phase 2 §2.1 "Register Width")

All registers hold **20 significant bits**. Every register write is masked to `$FFFFF`. There is no separate 16-bit write path:

```zig
fn set_reg(cpu: *Gab16, reg: u4, val: u32) void {
    if (reg != 0) cpu.r[reg] = val & 0xFFFFF;
}
```

- **Data operations** compute on the full register value; **FLAGS are always derived from the low 16 bits of the result** (bit 15 is the sign bit for N and V). This preserves the 16-bit programming model while letting pointers above $FFFF survive arithmetic.
- **Address operations** (memory access, jumps) use the full 20 bits.
- Known sharp edge (documented, intended): `CMP` of two pointers compares only the low 16 bits. To compare full 20-bit addresses, also compare bits 19:16 (e.g. `SHR` by 16 and `CMP` again).

**Special registers** (7): PC (20-bit), FLAGS (16-bit), IVT (20-bit), USP (20-bit), **SSP (20-bit, new)**, SYS (16-bit), CYC (32-bit, read-only). The Gab-16 has **16 GP + 7 special = 23 registers** (Phase 2's "24" is corrected).

### 1.2 LI / LUI (replaces the Phase 2 §2.4 entries)

```
LI  RD, IMM18    RD = sign_extend_18_to_20(IMM18) & $FFFFF
LUI RD, IMM18    RD = (RD & $0FFFF) | ((IMM18 & $F) << 16)
```

LUI is **non-destructive to the low 16 bits** and writes only bits 19:16. The canonical 20-bit address load is therefore LI-first, exactly as the Phase 8 `LOAD_ADDR` macro already does:

```asm
MACRO LOAD_ADDR reg, addr
    LI   \reg, (\addr & $FFFF)
    LUI  \reg, (\addr >> 16)
ENDMACRO
```

(The assembler must range-check: `\addr & $FFFF` as an LI operand is encoded as an unsigned 16-bit value in the 18-bit field, so sign extension never fires for the macro's inputs.)

### 1.3 Opcode assignment table (new — closes audit G1)

One opcode per instruction. The FUNC (9-bit) and FLAGS (5-bit) fields of R-format are **reserved and must be zero**; nonzero values are an illegal-instruction trap. All unlisted opcodes, including **$00**, trap to the BRK vector (D35: a $0000 0000 instruction word — cleared RAM or open bus — must never execute silently).

| Op | Mnemonic | Fmt | Field usage | Op | Mnemonic | Fmt | Field usage |
|---|---|---|---|---|---|---|---|
| $00 | — illegal | — | traps | $20 | BEQ | J | ADDR26 = rel |
| $01 | LW | I | RD ← [RA+IMM] | $21 | BNE | J | ADDR26 = rel |
| $02 | LB | I | RD ← zx8 [RA+IMM] | $22 | BLT | J | ADDR26 = rel |
| $03 | SW | I | [RA+IMM] ← RB-as-RD slot* | $23 | BGT | J | ADDR26 = rel |
| $04 | SB | I | [RA+IMM] ← low8* | $24 | BLE | J | ADDR26 = rel |
| $05 | LI | I | RD ← sext18 | $25 | BGE | J | ADDR26 = rel |
| $06 | LUI | I | RD bits19:16 ← IMM | $26 | BCS | J | ADDR26 = rel |
| $07 | — reserved | | | $27 | BCC | J | ADDR26 = rel |
| $08 | ADD | R | RD ← RA+RB | $28 | JMP | R | PC ← RA |
| $09 | SUB | R | RD ← RA−RB | $29 | JMPA | J | PC ← ADDR26 & $FFFFF |
| $0A | AND | R | RD ← RA&RB | $2A | CALL | R | LR ← PC; PC ← RA |
| $0B | OR | R | RD ← RA\|RB | $2B | CALLA | J | LR ← PC; PC ← ADDR26 |
| $0C | XOR | R | RD ← RA^RB | $2C | RET | R | PC ← LR |
| $0D | NOT | R | RD ← ~RA | $2D–$2F | — reserved | | |
| $0E | SHL | R | RD ← RA << RB[3:0] | $30 | PUSH | R | SP−=4; [SP]32 ← RA |
| $0F | SHR | R | RD ← RA >> RB[3:0] | $31 | POP | R | RD ← [SP]32; SP+=4 |
| $10 | ASR | R | arithmetic shift | $32 | PUSHA | R | push R1–R12, LR (52 B) |
| $11 | MUL | R | RD ← (RA×RB) low 16 | $33 | POPA | R | pop LR, R12–R1 |
| $12 | DIV | R | RD ← RA ÷ RB | $34–$37 | — reserved | | |
| $13 | MOD | R | RD ← RA mod RB | $38 | NOP | R | — |
| $14 | CMP | R | flags(RA−RB), RD ignored | $39 | HLT | R | halt until IRQ |
| $15–$17 | — reserved | | | $3A | RTI | R | §1.5 |
| $18 | ADDI | I | RD ← RA+sext18 | $3B | SEI | R | FLAGS.I ← 1 |
| $19 | SUBI | I | RD ← RA−sext18 | $3C | CLI | R | FLAGS.I ← 0 |
| $1A | ANDI | I | RD ← RA & imm | $3D | MFSR | R | RD ← sreg[RA field] |
| $1B | ORI | I | RD ← RA \| imm | $3E | MTSR | R | sreg[RD field] ← RA |
| $1C | XORI | I | RD ← RA ^ imm | $3F | — reserved | | |
| $1D | CMPI | I | flags(RA−sext18) | | | | |
| $1E–$1F | — reserved | | | | | | |

\* SW/SB use I-format with the **RD field carrying the source register** (the format has no RB): `SW [RA+IMM], RS` encodes RS in the RD field. The Phase 2 mnemonic tables are corrected accordingly.

`MOV RD, RA` remains an assembler pseudo for `ADD RD, RA, R0`. **Count: 49 opcodes + 1 pseudo** (Phase 2's "~50" and the plan's "all 50" are corrected to this).

Branch targets: `target = PC_next + sext26(ADDR26)` where PC_next is the address of the following instruction, offset in **bytes**. JMPA/CALLA: ADDR26 is an absolute byte address masked to 20 bits. `CALL/CALLA: LR ← address of the following instruction` (identical to the prior "PC+4" wording).

`SYS` is removed (D7); the BIOS jump table (Phase 6 §6.4) is the sole system-call mechanism in v1.

### 1.4 MFSR / MTSR (new)

Special register numbers: 0=FLAGS, 1=IVT, 2=USP, 3=SSP, 4=SYS, 5=CYC, 6–15 reserved.

- `MFSR RD, n` — n encoded in the RA field. Always permitted. CYC reads return the low 32 bits of the cycle counter (wraps every ~298 s at 14.4 MHz; wrap is defined behavior).
- `MTSR n, RA` — n encoded in the RD field. Writes to IVT, SSP, SYS require S=1, else illegal-instruction trap. Writes to CYC are ignored. **MTSR FLAGS in user mode ignores bits I and S** (no privilege escalation); in supervisor mode all defined bits are writable. PC is not an sreg — use JMP.

### 1.5 Interrupt model (replaces Phase 2 §2.6; closes audit E1, E5, G4)

- All vectors — the 16 IVT entries and the 16 ROM system-vector slots — are **4 bytes** (32-bit little-endian, value masked to 20 bits). IVT table size = 64 B. Vector index i lives at `base + 4×i`.
- IVT indices: 0=RESET, 1=NMI, 2=IRQ, 3=BRK, 4–15 reserved. **Indices 4–7 are no longer hardware vectors** (Timer A/B, raster, audio entries are deleted): under D13, every maskable device interrupt enters through index 2, and the handler reads IRQSTAT to dispatch. `SYS_IRQSET` installs handlers in a BIOS-side dispatch table keyed by IRQSTAT bit number; this table is BIOS state, not hardware.
- **Entry** (hardware): if FLAGS.S = 0 → USP ← SP; SP ← SSP. (If S = 1 — a nested entry — the stack switch and USP save are skipped.) Then push PC (4 B), push FLAGS (4 B, upper 16 bits zero), set S=1, clear I, PC ← vector.
- **RTI**: pop FLAGS (low 16 bits taken), pop PC. If the restored S = 0 → SSP ← SP; SP ← USP. Frame size: **8 bytes**.
- **HLT** wakes only on an interrupt that is delivered (unmasked, FLAGS.I=1). HLT with I=0 halts until reset — intentional, documented.
- NMI: no hardware source exists in v1. The vector is reserved for the debugger's break injection; the emulator never raises it otherwise.

### 1.6 Flag semantics per operation (new — closes audit G14)

FLAGS are computed from the low 16 bits in every case.

| Ops | Z | N | C | V |
|---|---|---|---|---|
| ADD, ADDI | result=0 | bit 15 | carry out of bit 15 | add overflow: (~(a^b) & (a^r)) bit 15 |
| SUB, SUBI, CMP, CMPI | result=0 | bit 15 | **no-borrow (ARM): C=1 iff a ≥ b unsigned** | sub overflow: ((a^b) & (a^r)) bit 15 |
| AND/OR/XOR/NOT (+I forms) | ✓ | ✓ | cleared | cleared |
| SHL/SHR/ASR | ✓ | ✓ | last bit shifted out (0 if shift=0) | cleared |
| MUL | ✓ (low 16) | ✓ | 0 | 0 |
| DIV, MOD | ✓ | ✓ | 0 | set on divide-by-zero |
| All others | — | — | — | — (flags unaffected) |

Shift amount = RB bits 3:0 (0–15; larger shifts are unencodable). **Divide by zero: RD ← $FFFF, V ← 1, no trap** — for both DIV and MOD. BCS/BCC after CMP therefore read as unsigned ≥ / < — the Phase 2 branch table's "carry set / unsigned overflow" wording is replaced with "C=1 (unsigned ≥ after CMP)".

### 1.7 Memory access edges (promotes Phase 7 behavior to normative; closes G14b)

Unaligned 16-bit access is legal, no penalty. A multi-byte access whose bytes fall in different bus regions is routed **per byte**. Addresses wrap: $FFFFF + 1 → $00000. Writes to non-shadowed ROM and to open bus are silently ignored; open-bus reads return $0000. All instruction fetches are two 16-bit reads, little-endian, as in Phase 7.

---

## 2. Memory Map — Corrections (supersedes Phase 1 §1.2/§1.6/§1.7, Phase 6 §6.2)

### 2.1 ROM layout v1.1 (single authoritative version — closes E6, E7, E16)

```
$FC000 – $FC01F     32 B    ROM header (unchanged from Phase 6 §6.3)
$FC020 – $FC0FF    224 B    Reserved / padding
$FC100 – $FC1FF    256 B    System call jump table (64 × 4 B, unchanged)
$FC200 – $FDFFF   ~7.5 KB   BIOS kernel code
$FE000 – $FF7FF     6 KB    Font data (2 KB primary + 4 KB secondary slot)
$FF800 – $FFAFF    768 B    Default palette (256 × 3 B RGB)        ← was 512 B
$FFB00 – $FFFBF   1216 B    Reserved
$FFFC0 – $FFFFF     64 B    System vectors (16 × 4 B)              ← was $FFBC0
```

System vector slot i at `$FFFC0 + 4×i`, mirroring IVT indices (0=RESET, 1=NMI, 2=IRQ, 3=BRK, 4–15 reserved, containing $00000000). The boot sequence sets IVT = $FFFC0, which is now fully coherent — reserved entries are defined zeros and never dispatched under D13. Every occurrence of $FFBC0 in Phases 1, 2, 6, the master, and plan task 5.2 is replaced by **$FFFC0**. Phase 1 §1.2's "$FFC0–$FFFFF" typo and §1.6's 256-byte-header layout are deleted in favor of the table above. The ROM header CRC-32 coverage becomes `$FC020 – $FFFBF`.

### 2.2 ROM shadowing (replaces Phase 1 §1.7 and Phase 6 §6.8 Stage 7 — closes E3, E18)

The shadow source is a **fixed window: $3C000 – $3FFFF** (top 16 KB of general RAM). When SYSCFG bit 0 = 1, the bus maps `$FC000+off ↔ $3C000+off` for **both reads and writes** (the shadowed "ROM" is live-patchable). Procedure:

```
1. SYS_MEMCPY: copy ROM ($FC000–$FFFFF) → $3C000–$3FFFF
2. Apply patches to the copy
3. Write 1 to SYSCFG bit 0 — shadow active
4. Write 0 to restore real ROM
```

Enabling shadow permanently costs the top 16 KB of free RAM by convention; programs must not place data there if they intend to shadow. The old "allocate anywhere" wording (and its 12 KB arithmetic error) is deleted.

### 2.3 Program loading (closes E4)

The **canonical load address is $04100** (start of free RAM). The BIOS autoboot scan (boot Stage 6, plan 12.15) checks exactly $04100 for the `.flapp` magic. The emulator loads a `.flapp` file image verbatim at the address in its header's load-address field (§8.2) — which must be $04100 for BIOS autoboot to find it. Phase 8 §8.6's sentence "loads at the address specified by the ENTRY directive" is deleted; placement comes from `SECTION ... AT`, and ENTRY only names the entry symbol.

### 2.4 Boot corrections

Stage 1: **SP ← $01100** (empty-descending; with 4-byte slots the first push occupies $010FC–$010FF, inside the stack region, aligned). **SSP ← $020F0** (top of System Variables region, reserved 16-slot supervisor stack — BIOS may relocate). IVT ← $FFFC0 via MTSR.

---

## 3. I/O — Corrections (supersedes Phase 5 §5.2/§5.5 excerpts)

### 3.1 Access model (closes E8)

Every I/O register is a **16-bit value at its listed address**. Access I/O with LW/SW at the exact register address; adjacent addresses are independent registers and never combine into one word. LB/SB access the low byte of the register. Registers narrower than 16 bits read back with undefined upper bits documented as zero. **KDATA dequeues on any read width**; use LW to preserve the key-up bit (bit 15).

### 3.2 Timer control (closes E9)

`TxCTRL`: bit 0 = enable, bit 1 = repeat (0 = one-shot: timer disables itself at expiry), bit 2 = IRQ enable, bits 3–15 reserved. Bit 3 "one-shot" is deleted.

### 3.3 IRQ controller (closes E5, G13)

The controller drives a single CPU IRQ line: `line = (IRQSTAT & IRQMASK) ≠ 0`. IRQSTAT always shows raw pending state regardless of mask. Device-level enables (TxCTRL bit 2, KCTRL bit 0, VIRQEN, AIRQEN) gate whether a device *sets* its IRQSTAT bit. IRQACK is write-1-to-clear per source. **IRQPRI ($80043) is deleted — reserved.** The joystick IRQ (bit 3) fires on any bit transition of either port. SYSPWR bit 0 = 1 causes the emulator to exit cleanly. The §5.5 handler pattern stands as the normative dispatch idiom.

### 3.4 Timer rate table at 14.4 MHz (replaces Phase 5 §5.2 table)

| Divisor | Tick rate | Notes |
|---|---|---|
| ÷1 | 14.4 MHz | fine timing |
| ÷8 | 1.8 MHz | PCM: reload 40 → **45.0 kHz exact**; reload 80 → 22.5 kHz exact |
| ÷64 | 225 kHz | music sequencing |
| ÷256 | 56.25 kHz | game logic, UI |

(45 kHz and 22.5 kHz are the machine's natural PCM rates; 44.1 kHz is approximated with reload 41 ≈ 43.9 kHz.)

---

## 4. Clock & Timing (closes G5, G6, G16, E15 groundwork)

- Master clock: **14,400,000 Hz exactly**. Boot banner becomes "GAB-16 CPU @ 14.4MHz".
- **Every instruction executes in exactly 1 cycle** (normative). 14.4 MIPS.
- Frame: **240,000 cycles at 60.000 Hz exactly** (`CYCLES_PER_FRAME = 240_000` — also fixes the Zig comptime division error).
- The emulator main loop advances in **scanline quanta**: run CYCLES_PER_LINE cycles → render that line → evaluate raster IRQ → next line; VBLANK IRQ, present, audio push, and event poll at frame end. Phase 7 §7.10's frame-at-once loop is superseded (this is what makes raster effects and sprite multiplexing actually work).

---

## 5. VIC-256 — Corrections (supersedes Phase 3 §3.2, §3.4–§3.8, §3.11 excerpts)

### 5.1 Colour depths (closes G9)

Supported depths: **1, 4, 8 bpp**. The 5bpp mode is removed; `VPALETTE` value 2 is reserved (writing it falls back as an illegal mode per §5.2). All §3.4 table rows and §3.2 entries for 5bpp are deleted.

### 5.2 Resolution registers (closes G7)

`VRESX`: 0=320, 1=640, 2=960, 3=1280. `VRESY`: 0=180, 1=360, 2=540, 3=720. Legal (X, Y, bpp) combinations are exactly the rows of the Phase 3 §3.4 supported-mode table (minus 5bpp). An illegal combination or reserved VPALETTE value puts the VIC in fallback mode **320×180 @ 8bpp** and sets VSTAT bit 3 (mode error, w1c).

### 5.3 Base address registers (closes G8)

All five pointer register pairs — VBUF, VBUF2, VPALBASE, VSATBASE, VTMAPBASE — hold the target **address ÷ 16** as a 16-bit value (LO = bits 7:0, HI = bits 15:8 of the shifted value). Reach = 1 MB; all tables and framebuffers are 16-byte aligned. VBUF/VBUF2 must resolve into $40000–$7FFFF; the three table bases must resolve into $00000–$3FFFF; out-of-range values set VSTAT bit 3.

### 5.4 Text mode (closes G10)

Text matrix in general RAM via VTMAPBASE, **2 bytes per cell**: byte 0 = character code, byte 1 = attribute (bits 3:0 = foreground palette index, bits 7:4 = background palette index, drawn from entries 0–15). Cell grid = (resX/8) × (resY/8). Font glyph: 8 bytes per char, one row per byte, **bit 7 = leftmost pixel**. The text cursor is BIOS software state in System Variables (hardware has no cursor); SYS_SETCURSOR/PUTCHAR manage it.

### 5.5 Sprites (closes E12, E13, G11)

- Sprite graphics live in **tile graphics RAM** ($40000+). Graphic address = `$40000 + index × stride(size, bpp)` where stride = size²×bpp/8 (8×8@8bpp=64 B … 32×32@8bpp=1024 B). The index is in units of the sprite's own size; large sprites therefore consume proportionally more of the 16 KB region (16 sprites max at 32×32@8bpp).
- SAT byte 5, read **MSB→LSB** (global convention for all packed bit-field lists in this spec): enable(7) | flipX(6) | flipY(5) | size(4:3: 0=8×8, 1=16×16, 2=32×32, 3=reserved) | priority(2) | spare(1:0).
- **Priority bit: 0 = sprite in front of the tile layer; 1 = behind the tile layer but in front of the bitmap layer** (C64-style). §3.1's "all sprites above everything" is amended.
- **Collision: single global flag** — VSTAT bit 2 sets when any two enabled sprites overlap on an opaque (non-index-0) pixel during a frame; **write-1-to-clear**. The "per-sprite collision flag" claim is deleted.
- Phase 1 §1.4's "sprite attribute tables … in VRAM" wording is corrected: the SAT lives in general RAM (Phase 3 wins).

### 5.6 Video timing tables (closes G6)

| Vertical res | Visible lines | VBLANK lines | Total | Cycles/line |
|---|---|---|---|---|
| 180 | 180 | 20 | 200 | 1200 |
| 360 | 360 | 40 | 400 | 600 |
| 540 | 540 | 60 | 600 | 400 |
| 720 | 720 | 30 | 750 | 320 |

All rows: total × cycles/line = 240,000. VSTAT bit 0 (VBLANK) sets at the start of the first VBLANK line and clears at line 0. The raster IRQ asserts at the start of the target visible line. VSWAP: the pending bit is readable until the swap; at VBLANK the VBUF and VBUF2 register contents are exchanged (visible to subsequent reads) and the bit auto-clears.

---

## 6. AUR-1 — Corrections (supersedes Phase 4 §4.4–§4.10 excerpts; closes E10, E11, G12)

### 6.1 VCTRL (per voice)

Read MSB→LSB: **gate(7) | ring mod(6) | hard sync(5) | bits 4:0 reserved**. The filter-route bit is deleted (**AMFILT at $80144 is the sole routing authority**) and the Pan field is deleted (**VVOLL/VVOLR are the sole pan mechanism**).

### 6.2 Numeric model

- **Frequency**: VFREQ is a 16-bit phase increment into a 16-bit accumulator, advanced once per output sample: `F_out = freq × sample_rate / 65536`. (At 44.1 kHz, A440 ≈ $0289.)
- **ADSR rate tables** (4-bit value → time, SID-derived):
  - Attack (ms): 2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000, 5000, 8000
  - Decay/Release (ms): 6, 24, 48, 72, 114, 168, 204, 240, 300, 750, 1500, 2400, 3000, 9000, 15000, 24000
- **Wavetable**: 256 unsigned 8-bit samples, $80 = zero crossing; output = `(sample − 128) << 8` (full-scale, fixing the ×256 level bug in Phase 7 §7.8).
- **FM**: carrier effective phase increment per sample = `base_inc + ((mod_output × depth) >> 16)`; modulator self-feedback adds `(prev_mod_output × fbk) >> 3` to its own phase input. Modulator output is taken post-envelope.
- **Ring mod / hard sync wraparound**: voice 0's "previous voice" is **voice 3**.
- **Filter**: Chamberlin state-variable filter at the output sample rate. `f = 2·sin(π·fc/fs)`, `cutoff_hz = 30 + (AFCUT/4095)² × 11970` (30 Hz–12 kHz), `Q = 0.5 + (AFRESON/15) × 9.5`. LP/HP/BP/Notch taps per AFMODE.
- **Mixer**: voices sum into signed 32-bit, master volume applied, then **saturated** to i16. No wraparound distortion.
- **ASRATE** selects the internal synthesis tick rate (44.1 k / 22.05 k / 11.025 kHz); the emulator's host stream stays at 44.1 kHz and repeats samples 1×/2×/4×.
- **Noise**: 16-bit Galois LFSR, taps $B400, seeded to $ACE1 at reset (deterministic for golden-audio tests).

---

## 7. ROM & Boot — Corrections (supersedes Phase 6 §6.6–§6.9 excerpts)

- Default palette occupies $FF800–$FFAFF (768 B); the Phase 6 §6.2 layout line "512 B" is corrected (see §2.1).
- Boot Stage 1 per §2.4 above. Stage 6 autoboot scans **$04100** (closes the "known load address" gap). The boot banner reads `GAB-16 CPU @ 14.4MHz`.
- BIOS table placements (closes G17): palette RAM $02100–$023FF, SAT $02400–$025FF, text matrix $02600 onward — all in Kernel Workspace, documented as the BIOS convention.
- Syscall behavioral pins (closes G18): SYS_GETLINE echoes, terminates on Enter, NUL-terminates the buffer, returns length in R1; SYS_GETCHAR applies shift via KMOD using the HID-to-ASCII table in ROM; SYS_MEMCMP returns 0 / 1 / $FFFF in R1 (equal / first-diff-greater / first-diff-less); SYS_RAND is a 16-bit Galois LFSR (taps $B400) seeded $1 at boot, SYS_SEED of 0 is coerced to $1; SYS_IRQSET handlers are invoked by the BIOS dispatcher with CALL and must end with RET (the dispatcher executes the RTI); SYS_TWAIT on a disabled timer returns immediately with R1=$FFFF.
- KSTAT caps/num-lock mirror host keyboard state via SDL; KCTRL bit 1 = write-1-to-flush, self-clearing.

---

## 8. Toolchain — Corrections (supersedes Phase 8 §8.3–§8.6 excerpts)

### 8.1 `.flobj` v1.1 header (closes E14)

```
+00  2 B   Magic bytes 'F','O'
+02  1 B   Version (= 1)
+03  1 B   Section count
+04  2 B   Symbol count
+06  2 B   Relocation count
```

Section table, symbol table, relocation table, payload follow in that order, sized by the counts. **All multi-byte fields in every Flommodore file format are little-endian; magic numbers are normatively byte *sequences*** ('F' then 'O') so they read correctly in a hex dump — the "$464F" notation describes the bytes in file order, not a u16 (closes the endianness ambiguity).

### 8.2 `.flapp` v1.1 header (12 bytes — closes E4)

```
+00  2 B   Magic bytes 'F','B'
+02  2 B   Program version
+04  2 B   Entry point offset from header start (≥ 12)
+06  2 B   Minimum RAM required (KB)
+08  4 B   Load address (little-endian, masked to 20 bits; $04100 for autoboot)
```

The file image (header + payload) is loaded verbatim at the load address; execution begins at load address + entry offset.

### 8.3 Relocation types (closes G15a)

| Value | Name | Patches |
|---|---|---|
| 0 | ABS16 | 16-bit LE word in data (DW) |
| 1 | ABS32 | 32-bit LE word in data (DD) |
| 2 | ABS26 | J-format ADDR26 field, absolute byte address |
| 3 | PCREL26 | J-format ADDR26 field, `target − (instr_addr + 4)` |
| 4 | LO16 | I-format IMM18 field ← `addr & $FFFF` |
| 5 | HI4 | I-format IMM18 field ← `addr >> 16` |

### 8.4 New directive: `DD value` (define 32-bit double-word)

Required by 4-byte vectors (D3) — ROM vector tables and IVT images are built with DD. Added to the Phase 8 directive table and plan task 10.7.

### 8.5 ORG vs sections (closes G15b)

A source file is either **absolute** (uses ORG; output sections carry fixed load addresses; linkable without a script — how test ROMs are built) or **relocatable** (uses SECTION; placement from the linker script). Mixing ORG and SECTION in one file is an assembler error.

### 8.6 ROM image emission (closes G15d)

New linker mode: `fll --raw --base $FC000 --size 16K input.flobj -o flommodore.rom` — emits the raw padded image with no autoboot header and **fails if the four defined vector slots at $FFFC0–$FFFCF are empty**.

### 8.7 Listing example

Phase 8 §8.8's example bytes are regenerated against the §1.3 opcode table (e.g. `HLT` = opcode $39 → instruction word $E4000000 → file bytes `00 00 00 E4`). Listing byte columns show **bytes in file/memory order**.

---

## 9. Phase 7 Reference-Code Errata (closes E21)

The Phase 7 snippets are normatively corrected as follows: `set_reg` masks to `0xFFFFF` (§1.1); `update_flags` is replaced by the per-op table (§1.6 — the ADD-only V/C formulas must not be used for SUB/CMP); `ram.read` must not index past the array (per-byte bus routing, §1.7, removes the $7FFFF overflow); `CYCLES_PER_FRAME = 240_000` (exact, compiles); the timer `tick()` must honor TxDIV (prescaler counter per timer); wavetable scaling per §6.2; the main loop per §4. Phase 7 retains its "the emulator defines ambiguity" authority *after* these corrections.

---

## 10. Finding → Fix Cross-Reference

| Finding | Fixed by | Finding | Fixed by |
|---|---|---|---|
| E1 | §1.5, §2.1 | E14 | §8.1 |
| E2 | §1.1, §1.2 | E15 | §4 |
| E3 | §2.2 | E16 | §2.1 (+ $FBFFF typo fix) |
| E4 | §2.3, §8.2 | E17 | §1.1 |
| E5 | §1.5, §3.3 | E18 | §2.2 |
| E6 | §2.1 | E19 | §2.4 |
| E7 | §2.1 | E20 | §1.3 |
| E8 | §3.1 | E21 | §9 |
| E9 | §3.2 | E22/E23 | plan/listing text fixes |
| E10 | §6.1 | G1 | §1.3 |
| E11 | §6.1 | G2 | §1.4 |
| E12 | §5.5 | G3 | §1.3 (SYS dropped) |
| E13 | §5.5 | G4 | §1.5 |
| — | — | G5–G20 | §4, §5.2–5.6, §6.2, §7, §8 |

---

*Flommodore Fantasy Computer — Block 0 Amendments v1.1*
*Pending acceptance → status LOCKED; then propagate into Phase 1–8 documents and master specification v1.1*
