# Flommodore — Blocks 14–18 Specification Amendments (v1.4)

**Status: PROPOSED — supersedes the listed sections of the v1.1–v1.3 document set upon
acceptance. Amendments v1.1 (Block 0), v1.2 (Block 3) and v1.3 (Block 13) remain in force
except where explicitly amended here.**

This document is the output of building what v1.3 specified: the FDD-1 and its filesystem,
the AUR-1 readback registers, the `.flsnd` format, `sndlib`, and the AURED sound designer.
Almost every decision below was already made — recorded at its use site as `AUR-k`, `STO-a`
and so on, exactly as v1.3 §7.1 said such decisions should be. This promotes them to
normative text, and adds the findings that only appeared once an application, rather than
a test ROM, had to live with them.

Two of those findings change what a tool may do (§1, §3). The rest close gaps that were
silences rather than errors. §7 maps every decision to what raised it.

---

## 0. Decision Register (continued from v1.3)

| # | Decision | Outcome |
|---|---|---|
| D59 | Patch recoverability | **Nine bytes of a patch never reach the chip.** Saving must UPDATE a record, not snapshot the registers |
| D60 | Generated tables | The note, cutoff and ADSR tables are generated from single sources; §4.5's curve is **not evaluable on the machine at all** |
| D61 | AUR-1 readback detail | Master source is the channel mean; latch at the internal sample; an `AOSCSEL` write takes effect from the next sample |
| D62 | FDD-1 behavioural detail | Command validity, error priority, write-protect visibility, IRQ sampling, and validation timing |
| D63 | Patch load/store contract | The gate bit is cleared on load **and** on store; `snd_stop_all` keeps the mix configured |
| D64 | Mod-table byte signedness | Always signed in delta mode; in absolute mode signed for arpeggio and pitch, unsigned for the register targets |
| D65 | Host tool purity | A tool that mutates its input cannot participate in a build graph; `fldisk add` gains `-o` |

---

## 1. `.flsnd` — what a patch is, and what it is not (D59)

### 1.1 The finding

v1.3 §5.2 rev. 5 corrected the *extent* of the chip image: 75 bytes, ending at `$8014A`.
Writing the inverse operation — chip back into a record, which any editor needs in order to
save — showed the same fact has a second consequence the amendment did not draw out.

**Nine bytes of every patch have no representation on the chip at all:**

| Where | Byte | Why the chip cannot supply it |
|---|---|---|
| voice `+$0C` | mod mask | The chip uses that offset for `VWTBHI` |
| global `+$0B` | architecture | Sits on `ASTAT`, which is write-1-to-clear |
| global `+$0C` | transpose | Sits on `AOSCSEL`, which is live readback state |
| global `+$0D` | tick divider | Sits on `AOSC`, read-only |
| global `+$0E` | flags | Sits on `AENV`, read-only |
| global `+$0F` | reserved | — |

A tenth, the wavetable slot at voice `+$0B`, survives only because it is derivable:
`slot = (VWTB − pool) ÷ 16`, exact because both are in 16-byte units and a table is 256
bytes.

### 1.2 Normative consequence

**A patch may not be reconstructed from the AUR-1's registers.** An operation that saves
the current sound MUST update an existing patch record in place, writing back only the
bytes the chip holds and leaving the rest untouched.

An implementation that snapshots the registers instead will silently discard a patch's
architecture, transpose, tick rate and every mod-table routing — that is, everything that
makes a patch a per-frame program rather than a chord. The loss is silent because the
result is a structurally valid patch that simply does less.

`sndlib.asm`'s `snd_store_patch` is the reference implementation.

---

## 2. AUR-1 readback — detail promoted to normative (D61)

Completes v1.3 §1.3, which specified the tap point but left three points to the
implementation (`AUR-k`, `AUR-l`, `AUR-m`).

- **Master source.** With `AOSCSEL` bit 2 set, `AOSC` reports the arithmetic mean of the
  two saturated output channels, so a reading does not swing with `VVOLL`/`VVOLR` panning.
- **Latch point.** Both `AOSC` and `AENV` latch at the end of each internal synthesis
  sample — at the `ASRATE` rate, not the host output rate. Reads between samples return the
  previously latched value.
- **`AOSCSEL` timing.** A write takes effect from the next internal sample onward. The
  currently latched bytes are not retroactively re-derived.

**One sample per frame is a level meter, not an oscilloscope.** At `ASRATE` 0 a sample
lasts 326 master cycles, so a program reading `AOSC` in a loop receives the same byte many
times. A waveform trace requires the timer-driven sampling of v1.3 §1.5; describing a
per-frame read as a scope misrepresents what it shows.

---

## 3. FDD-1 — behavioural detail promoted to normative (D62)

Completes v1.3 §2, which specified the register interface but left the following to the
implementation (`STO-a` … `STO-g`).

- **Command validity.** `STCMD` 0 and codes 4–255 are ignored outright: no busy window, no
  error, no IRQ. Only 1, 2 and 3 are accepted.
- **Error priority.** Media presence is tested first, then the buffer window, then
  per-command conditions. Write-protect outranks a bad LBA, so a write to a bad sector on a
  protected volume reports 3 rather than 2.
- **Write-protect visibility.** `STSTAT` bit 3 reads 1 only when media is present. An empty
  drive is not "a write-protected empty drive".
- **IRQ sampling.** `STCTRL` bit 0 is sampled at the completion cycle, not at acceptance,
  matching the §5.5 device-gate model. Enabling the IRQ mid-command therefore works.
- **Validation timing.** Every accepted command validates at completion, not at acceptance.
  This is what makes §2.5's promise hold: an accepted command always completes after
  exactly 2,000 cycles, whatever the outcome.

---

## 4. Generated tables (D60)

Three tables are now generated by `flsnd` rather than written by hand. The reasons differ,
and the third is the one with a normative consequence.

| Table | Generated because |
|---|---|
| `notes.inc` | `VFREQ` is a phase increment; a typed table would be a second implementation of `round(Hz × 65536 ÷ rate)`, free to drift |
| `adsr.inc` | The values already exist, as `aur1.zig`'s own arrays. A transcript could disagree with the envelope generator it is supposed to describe |
| `cutoff.inc` | **The curve cannot be evaluated on the machine.** See below |

### 4.1 §4.5's cutoff curve is not computable by a guest

Phase 4 §4.5 gives `cutoff_hz = 30 + (AFCUT ÷ 4095)² × 11970`. `AFCUT` is 12-bit, so the
squaring alone reaches 16,769,025 — 24 bits, against a 20-bit register — and no
rearrangement keeps every intermediate in range.

**A Flommodore program cannot convert a cutoff setting to hertz by arithmetic.** Any
software that displays one needs a lookup table. This is not a defect in §4.5, which
describes the hardware correctly; it is a consequence of the register width that the
specification should state, because the alternative is every author rediscovering it.

The generated table is 256 entries indexed by `AFCUT >> 4`, which costs at most one step of
display error — 44 Hz at the top of a 12 kHz range.

### 4.2 An invariant of §4.4 worth recording

Decay and release times are exactly three times the attack time at every one of the sixteen
indices. This is the SID-derived shape, not a rounding artefact, and is a cheaper thing to
assert than thirty-two separate constants.

---

## 5. Patch playback contract (D63, D64)

- **The gate bit is cleared on load and on store.** A patch that sounds the moment it is
  loaded is a broken patch; a saved patch that does so is a broken patch that persists.
  Ring modulation and hard sync are preserved in both directions — only the gate is masked.
- **Releasing is not tearing down.** An operation that stops all voices clears the gates and
  leaves the mix, routing and filter configured, so the next note sounds without reloading a
  patch. `snd_stop_all` and `snd_silence` are deliberately different operations.
- **Mod-table byte signedness**, which v1.3 §5.2 left open: a table byte is **always signed
  in delta mode**, since a sweep that cannot descend is not a sweep. In absolute mode it is
  signed for arpeggio and pitch — offsets from the sounding note, useless one-way — and
  unsigned for pulse width and cutoff, which are register values with no negative.

---

## 6. Host tools must be pure functions of their inputs (D65)

`fldisk add` originally wrote its volume back in place, which is what a person at a prompt
wants and what a build graph cannot express: a step's inputs are immutable and its outputs
are cached, so a `create` that does not re-run followed by an `add` that does means adding
the same file twice. The second build fails with `DuplicateName` — correctly, and
invisibly on a clean checkout.

**A host tool intended for use in the build MUST offer a mode in which it is a pure
function of its inputs.** `fldisk add -o <out>` is the reference form; in-place remains the
default for interactive use.

The same reasoning applies to output on success. A build step that declares an output file
captures the child's streams and fails on unexpected stderr, so `flas`, `fll`, `fldisk` and
`flsnd` are all silent on success. Only reporting subcommands print.

---

## 7. Mapping: decision → origin

| # | Raised by |
|---|---|
| D59 | Writing `snd_store_patch`, the inverse of a loader: the nine bytes had nowhere to come from |
| D60 | AURED needing to display a cutoff in hertz, and the arithmetic not fitting a 20-bit register |
| D61 | `aur1.zig`'s readback implementation (`AUR-k`, `AUR-l`, `AUR-m`), and AURED's meters showing what one sample a frame can and cannot be |
| D62 | `storage.zig` (`STO-a` … `STO-g`), and the test ROM that had to know which error a doubly-invalid command reports |
| D63 | `sndlib.asm` (`SND-b`, `SND-c`), confirmed by an AURED test that loads a patch over a sounding note |
| D64 | `snd_tick`, where absolute-mode arpeggio needed negatives and pulse width did not |
| D65 | `fldisk add` failing on the second build, and only on the second |

---

## Appendix — Recorded, not amended

**The four-bit shift count was already specified, twice.** Phase 2 §2.4's instruction table
gives `RD = RA << RB[3:0]`, and amendment v1.2's D37 says "amount = RB **value** bits 3:0"
and notes that the "SHR by 16" prose was corrected for exactly this reason. It is recorded
here only because the implementation of Blocks 15–17 nonetheless assumed a shift of 16
would work, producing three latent defects in `bios.asm` — autoboot's load address,
`SYS_IRQSET`'s stored handler and `irq_entry`'s reassembly — each harmless solely because
every address in play was below `$10000`.

The specification was right. The consequence worth stating in prose, since a table entry
did not convey it: **no single instruction can move a 20-bit register's high nibble into its
low half.** Splitting or reassembling a 20-bit pointer takes two shifts of 8.

**Deferred, and not oversights:** the `.flsnd` ⇄ `.asm` text form, which has no consumer
until AURED can say what it needs to emit; a real oscilloscope, which needs the timer-driven
ring buffer of v1.3 §1.5; and multi-volume storage, which §2's appendix already covers.

---

*Flommodore Fantasy Computer — Design Document*
*Blocks 14–18 Specification Amendments — Status: PROPOSED (v1.4)*
