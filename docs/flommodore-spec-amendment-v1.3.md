# Flommodore — Phase 9 Specification Amendments (v1.3)

**Status: LOCKED (rev. 5 — corrections folded back from the reference implementation,
marked ⟲; D57 reversed on the strength of the task-13.4 measurement) — supersedes the
listed sections of the v1.1 document set.

Locked after Blocks 14–18 implemented it in full: the FDD-1 and FLFS, the AUR-1 readback,
the `.flsnd` format, `sndlib` and AURED. The five ⟲ corrections are the record of what that
implementation found; amendment v1.4 carries the decisions §7.1 left open. Amendments v1.1 (Block 0) and v1.2 (Block 3) remain LOCKED and in force
except where explicitly amended here.**

This document is the output of Block 13, the specification pass required before the
AURED sound designer (Phase 9) can be implemented. It adds two pieces of hardware and
three file formats. Every register it defines lands in address space that Phase 5
already declares reserved; no existing register moves, changes width, or changes
meaning.

Each section contains normative replacement text. §9 maps every decision to the finding
that raised it. Where this document and a v1.1 or v1.2 document disagree, this document
wins.

---

## 0. Decision Register (continued from v1.2)

| # | Decision | Outcome |
|---|---|---|
| D48 | AUR-1 output readback | Three registers at `$8014C–$8014E`: `AOSCSEL`, `AOSC`, `AENV` |
| D49 ⟲ | `AOSC` tap point | Voice source = the **raw waveform value**: post-wavetable, post-hard-sync, **pre-envelope, pre-VVOL, pre-ring** (SID OSC3 behaviour); master source = mean of the two saturated output channels |
| D50 | Storage device FDD-1 | Six registers at `$80050–$80055`; **single 16-bit registers**, not LO/HI byte pairs |
| D51 | Transfer model | Fixed 512-byte sector; buffer base ÷ 16 in general RAM; **commit at completion**, not at command time |
| D52 | Command timing | Every accepted command is busy for exactly **2,000 master cycles**, then completes — including commands that complete with an error |
| D53 | IRQ source 7 | Assigned to **storage completion**; `IRQSTAT`/`IRQMASK`/`IRQACK` defined mask widens from `$7F` to `$FF` |
| D54 ⟲ | Disk geometry | 512-byte sectors, 16-bit LBA, **max 65,535 usable sectors** (≈32 MB); geometry reported by the `identify` command, not by registers |
| D55 | Filesystem FLFS v1 | Sector 0 = volume header, sector 1 = 16-entry directory, sector 2+ = data |
| D56 ⟲ | Storage syscalls | Ids 29–33: `SYS_DSKSTAT`, `SYS_DSKREAD`, `SYS_DSKWRITE`, `SYS_DSKFIND`, `SYS_DSKCREAT` |
| D57 ⟲ | `SAVE` residency | **Reversed.** Both `LOAD` and `SAVE` join the BIOS shell, and directory allocation lives in kernel ROM as `SYS_DSKCREAT` — one allocator, not one per application |
| D58 ⟲ | `.flsnd` patch scope | A patch is **whole-chip state**: its first **75** bytes are a byte image of `$80100–$8014A`, and the five after it are metadata occupying non-loadable register slots |

---

## 1. AUR-1 — Output readback (extends Phase 4 §4.10 and master specification §4.8)

### 1.1 Rationale (D48)

Before this amendment the AUR-1's entire readback surface was `ASTAT` — four
envelope-complete flags. A program could write the chip but could observe nothing about
what it produced. That makes an oscilloscope, an envelope meter, a level meter, or any
audio-reactive visual impossible, and it removes a family of techniques the SID made
famous (OSC3 as a cheap random source, ENV3 as a modulation source read back into
software).

Three read-only registers close it. The values are already computed every sample by the
synthesis pipeline; exposing them costs two latched bytes of device state.

### 1.2 Registers (replaces the `$8014C – $801FF` reserved row of Phase 4 §4.10)

| Address | Register | Description |
|---|---|---|
| `$8014C` | `AOSCSEL` | Bits 1:0 = voice select (0–3). Bit 2 = source: 0 = selected voice's oscillator, 1 = master mix. Bits 15:3 reserved, read zero, ignore writes |
| `$8014D` | `AOSC` | **Read-only.** Most recent internal sample of the selected source, biased unsigned: `$80` = zero crossing, `$00`/`$FF` = negative/positive full scale |
| `$8014E` | `AENV` | **Read-only.** Current envelope level of the voice selected by `AOSCSEL` bits 1:0, `$00` = silent, `$FF` = full |
| `$8014F – $801FF` | — | Reserved |

Writes to `AOSC` and `AENV` are ignored. Neither register has a read side effect;
`peek16` and `read16` are identical for all three (contrast `KDATA`).

### 1.3 Semantics (D49)

**Voice source** (`AOSCSEL` bit 2 = 0) — the selected voice's waveform output **after**
waveform generation, wavetable lookup, and hard sync (which acts on the phase, so it is
included by construction), and **before** the envelope, `VVOL`, and ring modulation.

⟲ Ring modulation is *excluded*, and cannot be otherwise: the reference implementation
applies ring mod **post**-envelope (decision `AUR-d`), so no pre-envelope tap can contain
it. Rev. 1 of this section said "after ring modulation"; that was unimplementable.
Formally, with `w` the signed 16-bit voice sample that amendment v1.1 §6.2 feeds into the
envelope multiply:

```
AOSC = ((w >> 8) + 128) & $FF
```

Pre-envelope is deliberate. It gives the editor the *shape* of the oscillator
independent of amplitude, `AENV` supplies the amplitude separately, and the product of
the two is what the mixer heard — so nothing is hidden. It also preserves the SID
idiom: a voice set to waveform 5 (noise) becomes a readable random-number generator
whose rate follows its `VFREQ`.

**Master source** (`AOSCSEL` bit 2 = 1) — the arithmetic mean of the two **saturated**
output channels of the most recent internal sample, biased the same way:

```
AOSC = ((((left + right) >> 1) >> 8) + 128) & $FF
```

The mean rather than one channel, so a scope reading does not swing with `VVOLL`/`VVOLR`
panning. `AENV` continues to report the voice named in bits 1:0 regardless of bit 2.

**`AENV`** — the envelope generator's current level scaled to eight bits (`level >> 8`
of the 16-bit internal level). It is meaningful in every phase: rising during attack,
falling during decay and release, tracking the live `VADSR1` sustain nibble while
sustaining (implementation decision AUR-c).

**Latching.** Both registers latch at the end of each internal synthesis sample — that
is, at the `ASRATE` rate, not the host output rate. Reads between samples return the
previously latched value. A write to `AOSCSEL` takes effect from the next internal
sample onward; the currently latched bytes are not retroactively re-derived.

**Determinism.** Sample generation is already cycle-aligned and bit-deterministic
(`aur1.zig` header), so the value a program reads at a given `CYC` is reproducible
across hosts and targets. Golden-audio hashes are unaffected: this amendment adds no
term to the synthesis path.

### 1.4 Reset state

`AOSCSEL = $0000` (voice 0, voice source), `AOSC = $80`, `AENV = $00`.

### 1.5 Reading a waveform (informative)

`AOSC` holds one sample for a whole sample period — 326 master cycles at `ASRATE` 0.
Reading it in a tight loop therefore returns the same byte many times over; it is not a
sampling instrument by itself. A program that wants a waveform trace must sample it on a
timer, exactly as §4.12 describes for software PCM, run in the opposite direction:

- Timer A, `TADIV` = 1 (÷8, 1.8 MHz), reload 160 → **11.25 kHz exactly**
- IRQ handler: read `AOSC`, store to a ring buffer, advance the index, acknowledge
- Cost: one interrupt every 1,280 cycles; a ~20-instruction handler is under 2% of a
  frame at 1 cycle per instruction (D17)

A 128-entry buffer at that rate spans 11.4 ms — three cycles of a 262 Hz tone, which is
what a scope display wants.

---

## 2. Storage — FDD-1 (extends Phase 5 §5.5 and §5.6)

### 2.1 Rationale

The machine has never been able to keep anything. Phase 6 §6.10 lists a `LOAD` shell
command described as "reserved for storage device support", and the BIOS currently
answers it with a diagnostic. Every application that produces data — a sound designer, a
sprite editor, a tracker, a game with saved progress — is blocked on this.

FDD-1 is deliberately the smallest device that unblocks them: one fixed sector size, a
flat 16-bit sector number, a DMA buffer, and a completion flag.

### 2.2 Registers (replaces part of the Phase 5 §5.6 "Reserved expansion" row)

Base `$80050`. Every I/O address is a 16-bit register (D14); byte access follows D47.

| Address | Register | Description |
|---|---|---|
| `$80050` | `STCMD` | Write-only command: 0 = no-op, 1 = read sector, 2 = write sector, 3 = identify. Reads return `$0000` |
| `$80051` | `STSTAT` | **Read-only.** Bit 0 = busy, bit 1 = media present, bit 2 = error, bit 3 = write-protected |
| `$80052` | `STLBA` | Sector number, full 16 bits |
| `$80053` | `STBUF` | Transfer buffer base **÷ 16**, full 16 bits |
| `$80054` | `STCTRL` | Bit 0 = raise IRQ on completion. Bits 15:1 reserved |
| `$80055` | `STERR` | **Read-only.** Error code of the last completed command (§2.6) |
| `$80056 – $8005F` | — | Reserved |
| `$80060 – $800FF` | — | Reserved expansion (was `$80050 – $800FF`) |

**Single 16-bit registers, not LO/HI pairs (D50).** The VIC-256 and AUR-1 split
multi-byte values across byte-pair registers because their register maps were specified
as tables of 8-bit fields. Nothing in the machine requires that: D14 makes every I/O
address a 16-bit register, and a 16-bit LBA or buffer base fits one. A new device
repeating the pair convention would double its register count and make `SW` writes
gratuitously into two. The pairs stay where they are for compatibility; they are not
extended to new hardware.

### 2.3 Command model

Writing a nonzero value to `STCMD` **accepts** a command if `STSTAT` bit 0 is clear.
On acceptance the device:

1. Clears `STSTAT` bit 2 and sets `STERR` to 0
2. Sets `STSTAT` bit 0 (busy)
3. Latches `STLBA` and `STBUF` — later writes to either do not affect the command
4. Completes 2,000 master cycles later (§2.5)

Writing to `STCMD` **while busy** is rejected: the command is discarded, `STERR` is set
to 5 (busy), `STSTAT` bit 2 is set, and no additional completion or IRQ occurs. Writing
0 is always a no-op and never sets busy.

Every command transfers exactly one 512-byte block, which keeps one invariant across the
whole device:

- **read (1)** — sector `STLBA` → RAM at `STBUF × 16`
- **write (2)** — RAM at `STBUF × 16` → sector `STLBA`
- **identify (3)** — a 512-byte device record → RAM at `STBUF × 16`, `STLBA` ignored

The identify record:

```
+000  4 B   magic 'F','D','D','1'
+004  2 B   device version (1)
+006  2 B   sector size in bytes (always 512)
+008  2 B   total sector count (0 if no media; ≤ 65,535 — see below)
+00A  2 B   flags: bit 0 = write-protected
+00C  4 B   reserved (zero)
+010  ...   zero to 512 bytes
```

⟲ **65,535 usable sectors, not 65,536.** The count above is a 16-bit field, so a
65,536-sector volume would report zero. The last usable LBA is 65,535 and trailing sectors
of a larger image are unreachable.

### 2.4 Transfer atomicity (D51)

The transfer **commits at the completion cycle**, not when the command is accepted. For
a read, no RAM byte changes before completion; for a write, the sector receives the RAM
content as it stands at the completion cycle.

A program must therefore not touch the buffer while `STSTAT` bit 0 is set. This is a
documented contract rather than an enforced one: the device does not detect or report
concurrent modification.

### 2.5 Timing (D52)

Busy lasts **exactly 2,000 master cycles** from the cycle the command is accepted,
for every command and every outcome, including commands that complete with an error.
At 14.4 MHz that is 139 µs — about 0.8% of a frame, and slow enough that programs
which poll properly stay correct if the constant is ever revised.

One constant, not a seek model, because the emulator is the definitive runtime reference
(master specification, About This Document) and a fabricated seek curve would be
unverifiable detail that every future test would have to encode.

Commands that fail still complete normally — busy clears, `STSTAT` bit 2 and `STERR`
report the failure, and the completion IRQ fires if enabled. A program waiting on the
IRQ can therefore never hang on a bad command.

### 2.6 Error codes

| `STERR` | Meaning | Raised when |
|---|---|---|
| 0 | None | Command completed successfully |
| 1 | No media | `STSTAT` bit 1 was clear at acceptance |
| 2 | Bad LBA | `STLBA` ≥ the volume's sector count |
| 3 | Write protected | Write command on a write-protected volume |
| 4 | Bad buffer | `STBUF × 16` is outside `$00000 – $3FE00`, i.e. the 512-byte block would leave general RAM |
| 5 | Busy | `STCMD` written while `STSTAT` bit 0 was set |

`STSTAT` bit 2 and `STERR` are cleared when the next command is accepted; there is no
write-1-to-clear.

### 2.7 IRQ source 7 (D53 — amends Phase 5 §5.5)

The IRQ source bit map's row 7 changes from "Reserved" to:

| Bit | Source |
|---|---|
| 7 | Storage completion (FDD-1) |

The bit sets at the completion cycle if `STCTRL` bit 0 is set (the device-level enable,
per §5.5's gate rule), is cleared through `IRQACK` like every other source, and enters
the CPU through IVT entry 2 with the rest. The `IRQSTAT`/`IRQMASK`/`IRQACK` defined mask
becomes `$FF`; `IRQMASK ← $FFFF` now reads back `$00FF` rather than `$007F`.

### 2.8 Reset state

`STCMD` idle, `STSTAT` = media-present and write-protect bits as reported by the host
(0 if no image is attached), `STLBA` = 0, `STBUF` = 0, `STCTRL` = 0, `STERR` = 0.

### 2.9 Host image (informative)

The backing store is a raw sector image — no container, no header — named on the command
line with `--disk path` (read/write) or `--disk-ro path` (write-protected). Sector count
is the file length divided by 512, truncated; a file shorter than 512 bytes is treated as
no media. Writes are committed to the backing file before busy clears, so an emulator
crash cannot lose an acknowledged write.

---

## 3. FLFS v1 (D55)

A filesystem sufficient to name files and find them again. Not extensible, not
fragmenting, not concurrent — deliberately.

```
Sector 0    Volume header
Sector 1    Directory — 16 entries × 32 bytes
Sector 2+   File data, contiguous
```

**Volume header** (sector 0, remainder zero):

```
+000  4 B   magic 'F','L','F','S'
+004  2 B   version (1)
+006  2 B   total sectors on the volume
+008  8 B   volume label, ASCII, space-padded
+010  ...   zero
```

**Directory entry** (32 bytes):

```
+00  12 B   name, ASCII, uppercase, space-padded
            first byte $00 = never used (end of directory), $E5 = deleted
+0C   2 B   type: 'AP' = .flapp, 'SN' = .flsnd, 'TX' = text, 'DT' = raw data
+0E   2 B   start LBA
+10   2 B   sector count
+12   4 B   byte length (≤ sector count × 512)
+16   2 B   flags: bit 0 = read-only
+18   8 B   reserved (zero)
```

Files are contiguous runs of sectors. Deleting an entry does not reclaim its sectors;
compaction, if anyone ever wants it, is a host-tool job. Directory search stops at the
first entry whose name byte is `$00`.

---

## 4. BIOS — storage system calls (extends Phase 6 §6.4 and §6.10)

### 4.1 Jump table entries (D56 ⟲)

Five of the reserved slots gain implementations. Addresses follow the permanent rule
`$FC100 + 4 × id`.

| Id | Address | Name | Arguments | Result |
|---|---|---|---|---|
| 29 | `$FC174` | `SYS_DSKSTAT` | — | R1 = `STSTAT`, R2 = `STERR` |
| 30 | `$FC178` | `SYS_DSKREAD` | R1 = LBA, R2 = buffer address | R1 = 0 ok, `$FFFF` error |
| 31 | `$FC17C` | `SYS_DSKWRITE` | R1 = LBA, R2 = buffer address | R1 = 0 ok, `$FFFF` error |
| 32 | `$FC180` | `SYS_DSKFIND` | R1 = name pointer (NUL-terminated), R2 = 512-byte scratch buffer | R1 = byte offset of the matching entry within the scratch, `$FFFF` if not found |
| 33 | `$FC184` | `SYS_DSKCREAT` | R1 = name pointer, R2 = 512-byte scratch buffer, R3 = sector count | R1 = byte offset of the new entry within the scratch, `$FFFF` if the directory is full or the volume is out of space |

Conventions follow decision be: arguments in R1–R3, result in R1, callers may lose
R1–R4 and R12.

**Buffer alignment.** `SYS_DSKREAD`, `SYS_DSKWRITE`, `SYS_DSKFIND`, and `SYS_DSKCREAT`
require a **16-byte-aligned** buffer address, because `STBUF` addresses in units of 16
bytes — a misaligned address cannot be expressed at all, and rounding it down would
silently transfer to the wrong place. ⟲ A misaligned address returns `$FFFF` and **leaves
`STERR` untouched**; rev. 2 said it reports `STERR` = 4, which the kernel cannot do —
`STERR` is a read-only device register (§2.2), so only the device can set it. The kernel
does not bounce through a staging buffer: that would cost 512 bytes of permanent BIOS RAM
to paper over a one-instruction requirement on the caller.

`SYS_DSKREAD` and `SYS_DSKWRITE` block until `STSTAT` bit 0 clears, in the manner of
`SYS_TWAIT`. `SYS_DSKFIND` reads sector 1 into the caller's scratch buffer, compares
names case-insensitively over 12 bytes with trailing spaces ignored, and returns the
offset so the caller reads the entry in place — no copy, no second buffer.

**`SYS_DSKCREAT`** is the reason directory allocation belongs in ROM. It reads the
directory, rejects a duplicate name, claims the first entry whose name byte is `$00` or
`$E5`, and allocates the run immediately above the highest `start + count` currently in
use — FLFS v1 never reclaims deleted space (D55), so a bump allocator is the whole
algorithm. It writes the directory back before returning, and fails with `$FFFF` if no
entry is free, if the name already exists, or if `start + count` would exceed the
volume's sector count. The caller then writes its data sectors with `SYS_DSKWRITE`.

One allocator in ROM rather than one per application: the alternative has every program
that creates a file reimplementing free-entry search, bump allocation, and the
out-of-space cases, which is exactly the duplication a kernel exists to prevent.

### 4.2 `LOAD` shell command (amends Phase 6 §6.10)

```
LOAD name
```

`LOAD` reads the directory into `$04100`, searches it, and — if the entry is of type
`'AP'` — reads its sectors to `$04100` onward, validates the `FB` header per §6.9, and
`CALL`s the entry point. A program that ends in `RET` drops back to `READY.`, exactly as
autoboot and `RUN` already behave (decision bs).

Using `$04100` as the directory scratch is intentional: it is 16-byte aligned, it is
about to be overwritten by the program anyway, and it costs the kernel no new RAM.

`LOAD` with no argument, a missing file, a non-`'AP'` type, or a bad header prints a
diagnostic and returns to the prompt.

### 4.3 ⟲ `SAVE` shell command (D57, reversed)

```
SAVE name addr len
```

`SAVE` allocates through `SYS_DSKCREAT`, then writes `len` bytes from `addr` sector by
sector with `SYS_DSKWRITE`, padding the final sector with zeros. It reports the entry it
created, or a diagnostic on a full directory, a duplicate name, or an out-of-space
volume.

**Why this reverses rev. 2.** That revision kept `SAVE` and directory allocation out of
the kernel for two stated reasons, and the task-13.4 measurement killed the first while
examination killed the second.

The budget argument is simply gone. Kernel code occupies `$FC000 – $FDFFF` (8 KB) less
the 32-byte header and the 256-byte jump table; the measured image uses **4,273 bytes and
leaves 3,919 free**, against an estimated 1.1 KB for all five syscalls plus both shell
commands. There was never a shortage to ration.

The second argument — "directory allocation is application-side" — was pointing the wrong
way. Allocation is not application-*specific*; it is identical for every writer. Leaving
it out of ROM does not avoid the code, it multiplies it once per program and invites four
subtly different bump allocators to disagree about the same volume. Rev. 2 let a
constraint that turned out not to exist make an architectural argument it could not
support.

The estimate this block is working against, for the next person measuring:
`SYS_DSKSTAT` ~40 B, `SYS_DSKREAD` and `SYS_DSKWRITE` ~80 B each, `SYS_DSKFIND` ~200 B,
`SYS_DSKCREAT` ~240 B, `LOAD` ~240 B, `SAVE` ~240 B — about 1.1 KB, leaving ~2.8 KB free.
Block 15 is the last cheap opportunity to put anything in kernel ROM, so an overrun
matters more than the slack suggests.

---

## 5. `.flsnd` sound bank format (D58)

### 5.1 Design property

A patch's first 80 bytes follow the chip's own register layout — the four voice blocks
and the global block — so loading a patch is a block copy plus a short fix-up list, which
is what keeps a player routine small enough to be obviously correct.

⟲ **How much of it is genuinely a chip image.** Rev. 1 of this section said all 80 bytes
were an image of `$80100 – $8014F`. That was true when it was written and stopped being
true three sections earlier in the same document: §1.2 assigned `AOSCSEL` to `$8014C`,
which is exactly where §5.2 puts the patch's transpose byte. A 16-byte copy of the global
block would write transpose into `AOSCSEL` and silently redirect the oscilloscope.

The image therefore ends at `$8014A`: **75 bytes copied**, and five more read as patch
metadata. Only `$8014D`/`$8014E` are read-only enough that copying onto them would have
been harmless; `AOSCSEL` is writable, which is what makes this a defect rather than an
untidiness. Nothing in the layout moves — the extent of the image was simply overstated.
`sndlib.asm`'s `snd_load_patch` implements the corrected form.

### 5.2 Patch record — 128 bytes

```
+$00 .. +$3F   4 × 16-byte voice blocks   (image of $80100–$8013F)
+$40 .. +$4A   global block               (image of $80140–$8014A)
+$4B .. +$4F   patch metadata             (NOT chip registers — see below)
+$50 .. +$5F   name, 16 ASCII bytes, space-padded
+$60 .. +$7F   4 × 8-byte mod-table descriptors
```

**Voice block** — chip layout, two bytes repurposed:

| Off | Chip register | Patch meaning |
|---|---|---|
| `+0` `+1` | `VFREQLO` `VFREQHI` | Base pitch; overwritten by the player's note-on |
| `+2` | `VWAVE` | Waveform 2:0, FM enable bit 3 (modulator voices 0 and 2 only) |
| `+3` | `VCTRL` | Ring mod and sync; the gate bit is stored but **cleared on load** |
| `+4` `+5` | `VADSR0` `VADSR1` | Attack/decay, sustain/release |
| `+6` | `VPULSE` | Pulse duty |
| `+7` | `VVOL` | Pre-mixer volume |
| `+8` `+9` | `VMODLO` `VMODHI` | FM modulation depth |
| `+A` | `VFBK` | FM feedback, bits 2:0 |
| `+B` | ~~`VWTBLO`~~ | **Wavetable slot**, 0–15; resolved to an address on load |
| `+C` | ~~`VWTBHI`~~ | **Mod mask** — which of the four mod tables drive this voice |
| `+D` `+E` | `VVOLR` `VVOLL` | Pan |
| `+F` | — | Reserved, zero |

**Global block** — ⟲ only `+0` … `+A` are loaded. The last five bytes sit on registers a
loader must not write: `ASTAT` is write-1-to-clear, `AOSCSEL` is live readback state
owned by whoever is watching the scope, and `AOSC`/`AENV` are read-only.

| Off | Chip register | Patch meaning |
|---|---|---|
| `+0` … `+A` | `AMVOL` … `AIRQEN` | Loaded verbatim — the chip image ends here |
| `+B` | ~~`ASTAT`~~ (w1c) | **Architecture**: 0 = 4 × mono, 1 = FM pair 0+1 plus mono 2 and 3, 2 = two FM pairs |
| `+C` | ~~`AOSCSEL`~~ (RW) | **Transpose**, signed semitones — **never written to the chip** (§1.2) |
| `+D` | ~~`AOSC`~~ (RO) | **Tick divider** — mod tables advance every N frames (1 = 60 Hz) |
| `+E` | ~~`AENV`~~ (RO) | Flags |
| `+F` | — | Reserved, zero |

**Mod-table descriptor** — 8 bytes:

| Off | Meaning |
|---|---|
| `+0` | Target: 0 = off, 1 = arpeggio (semitones), 2 = pulse width, 3 = filter cutoff, 4 = pitch |
| `+1` | Table slot, 0–15 |
| `+2` | Length in steps, 1–32 |
| `+3` | Loop point step index; `$FF` = one-shot, then hold the last value |
| `+4` | Speed, frames per step |
| `+5` | Mode: 0 = absolute, 1 = signed delta, accumulated |
| `+6` `+7` | Reserved, zero |

Mod tables exist because the AUR-1 has no LFO, no pulse-width sweep, and no
envelope-to-filter routing. Every parameter that moves is a CPU write, so a patch that
sounds like anything is a per-frame register script, not a set of static values.

### 5.3 Bank file

```
+$00   2 B   magic 'F','S' ($46, $53)
+$02   2 B   version (1)
+$04   1 B   patch count       (≤ 32)
+$05   1 B   wavetable count   (≤ 16)
+$06   1 B   mod-table count   (≤ 16)
+$07   9 B   reserved (zero)
+$10   ...   patches      count × 128 bytes
             wavetables   count × 256 bytes
             mod tables   count × 32 bytes
```

A full bank is 16 + 4,096 + 4,096 + 512 = **8,720 bytes**, 18 sectors. All fields
little-endian; the magic is a byte sequence, following the convention of every other
Flommodore format.

Wavetable samples are unsigned 8-bit with `$80` as the zero crossing (v1.1 §6.2). The
wavetable pool must be placed at a 16-byte-aligned address inside RAM, because `VWTB`
holds an address ÷ 16 (implementation decision AUR-a).

---

## 6. I/O register map — audit (task 13.2)

Every address added by this amendment, checked against the complete sorted map:

| Range | Before | After |
|---|---|---|
| `$80050 – $80055` | Reserved expansion | **FDD-1 registers** |
| `$80056 – $8005F` | Reserved expansion | Reserved (FDD-1) |
| `$80060 – $800FF` | Reserved expansion | Reserved expansion (160 B, was 176 B) |
| `$8014C – $8014E` | Reserved (AUR-1) | **`AOSCSEL`, `AOSC`, `AENV`** |
| `$8014F – $801FF` | Reserved (AUR-1) | Reserved (AUR-1) |

No collisions. No existing register moves or changes width. Every remaining hole is
still explicitly reserved. The only behavioural change to an existing register is
`IRQSTAT`/`IRQMASK`/`IRQACK` bit 7 becoming defined (D53).

---

## 7. Reference implementation contract (normative for the emulator)

Recorded so Block 14 has no latitude to differ:

1. `aur1.zig` latches two bytes per internal sample. Synthesis is otherwise untouched;
   **all existing golden-audio hashes must be unchanged** by this amendment, and a
   change to any of them is a bug, not a re-baseline.
2. `io.zig` gains a storage dispatch arm alongside the VIC and AUR arms, with the same
   optional-pointer null semantics (`return 0x0000` when no device is wired).
3. `irq_defined_mask` widens from `$7F` to `$FF`. The existing `io.zig` test asserting
   `read16($80050) == 0` for reserved expansion, and the one asserting
   `IRQMASK ← $FFFF` reads back `$7F`, both change with it.
4. ⟲ The storage device counts cycles in `Machine.cycle`, beside the AUR-1 — **not** in
   `Io.tick`, which has no RAM access and therefore cannot perform the DMA. One busy
   countdown, decremented once per master cycle, raising IRQ source 7 at zero if enabled.
5. `storage.zig` stays host-I/O-free in the manner of every other device module: it owns
   a sector image slice, and `main.zig`/the harness load and flush the file.
6. `peek16` must be identical to `read16` for all six FDD-1 registers and all three
   AUR-1 readback registers — no new register has a read side effect, so the debugger's
   memory viewer stays safe.
7. Boot's `dev_init` gains safe defaults for the new registers, and the boot-state
   verifier gains the corresponding assertions.

### 7.1 Decisions raised by the implementation

Recorded at their use sites in the manner of `AUR-a`–`AUR-j`; candidates for v1.4.

| Tag | Where | Point v1.3 left open |
|---|---|---|
| `AUR-k` ⟲ | `aur1.zig` | The `AOSC` voice tap — corrects §1.3 (D49) |
| `AUR-l` | `aur1.zig` | Master source is the channel mean, so a trace ignores panning |
| `AUR-m` | `aur1.zig` | Latch point, and when an `AOSCSEL` write takes effect |
| `STO-a` | `storage.zig` | Command 0 and codes 4–255 are ignored outright — no busy, no error |
| `STO-b` ⟲ | `storage.zig` | 65,535 usable sectors, not 65,536 (D54) |
| `STO-c` | `storage.zig` | Completed writes are announced via `takeDirty()` for the host to flush |
| `STO-d` | `storage.zig` | Error priority: media, buffer, then per command; write-protect outranks bad LBA |
| `STO-e` | `storage.zig` | The write-protect status bit only shows with media present |
| `STO-f` | `storage.zig` | `STCTRL` bit 0 is sampled at completion, per the §5.5 gate model |
| `STO-g` | `storage.zig` | Validation happens at completion, not acceptance |
| `SND-a` ⟲ | `sndlib.asm` | The global-block image ends at `+$0A`; the last five bytes are metadata (D58) |
| `SND-b` | `sndlib.asm` | The gate bit is masked off on load — loading a patch must not sound it |
| `SND-c` | `sndlib.asm` | `snd_stop_all` releases gates without tearing down the mix, so the next note needs no reload |

---

## 8. Test infrastructure conventions (informative)

Continuing the v1.2 §3 list:

- **Harness disk injection:** `--disk path` and `--disk-ro path`, mirroring the emulator
  flags. A test that needs a prepared volume gets it from a build-step-generated image,
  never from a checked-in binary.
- **New test ROMs:** `test_aur_readback.rom` (waveform values per waveform id, envelope
  through all four ADSR phases, `AOSCSEL` selection, read-only enforcement) and
  `test_storage.rom` (read/write round trip, identify record, all six error codes, the
  busy window, the completion IRQ). Both use the established `$00080` = `$600D` protocol.
- **Cycle-exact busy test:** the 2,000-cycle constant is asserted directly — busy set at
  acceptance, still set at 1,999, clear at 2,000 — because a drifting constant would
  silently change every disk-using program's timing.

---

## 9. Mapping: decision → origin

| # | Raised by |
|---|---|
| D48 | Phase 9 planning: the AUR-1 exposes only `ASTAT`, making a scope, envelope meter, or any audio-reactive display impossible |
| D49 | The tap point determines whether `AOSC` shows shape or amplitude; SID precedent (OSC3) and the availability of a separate `AENV` decide it |
| D50 | New device, no legacy: D14 already makes every I/O address a 16-bit register, so byte pairs would double the register count for nothing |
| D51 | Commit-at-acceptance would let a program observe read data before busy clears and depend on it; commit-at-completion has one observable moment |
| D52 | A seek model would be fabricated detail the emulator alone defines and every test would have to encode |
| D53 | Bit 7 was the only reserved IRQ source, and storage completion is the only device that needed one |
| D54 | 512 bytes and a 16-bit LBA cover 32 MB — far past anything this machine will hold — with no geometry registers to get wrong |
| D55 | `LOAD name` requires a name-to-sector mapping; anything more than a flat contiguous directory is a filesystem phase, not this |
| D56 | Phase 6 §6.4 reserves ids 29–63; storage is the first claim on them |
| D57 ⟲ | Task 13.4 measured 3,919 bytes free against a ~1.1 KB need, removing the only real objection — and allocation is common to every writer, not specific to any |
| D58 ⟲ | The AUR-1's cross-voice features — shared filter, previous-voice ring and sync, fixed FM pairs — make per-voice presets incoherent. The image extent was corrected when `snd_load_patch` was written: §1.2 had claimed `$8014C` for `AOSCSEL` after §5.2 had already spent it |

---

## Appendix — Explicitly deferred

Not in this amendment, recorded so they are not mistaken for oversights:

- **Multiple volumes.** One device, one image. A second drive would need a unit-select
  bit in `STCTRL` and is trivial to add later; nothing here forecloses it.
- **Sector sizes other than 512.** `identify` reports the size so a future device can
  differ; FDD-1 v1 always answers 512.
- **Compaction and fragmentation.** Files are contiguous; deleted space is not
  reclaimed. A host tool can rewrite an image.
- **`.flsnd` v2 fields.** The bank header keeps 9 reserved bytes and each patch keeps a
  reserved byte per voice, so new per-voice state can be added without a version break.

---

*Flommodore Fantasy Computer — Design Document*
*Phase 9 Specification Amendments — Status: PROPOSED (v1.3)*
