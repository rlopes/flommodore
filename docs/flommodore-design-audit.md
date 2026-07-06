# Flommodore Design Audit — 2026-06-12

## Summary

The specification is well-organized, consistent in tone, and unusually complete at the *map* level — the address space, register blocks, and file family hold together with almost no collisions. However, the audit found **7 Blocker-level findings**, ~29 Major, and ~15 Minor. The blockers cluster around one root cause: **the 16-bit-data / 20-bit-address split was never fully designed**. Vectors are 2 bytes (can't hold ROM addresses), ALU results are masked to 16 bits (can't compute VRAM pointers), LI/LUI semantics are undefined, and several pointer registers are 16 bits wide for ≥18-bit targets. The top 3 issues:

1. **E1/E2 — The address model is broken**: 16-bit vectors and 16-bit ALU write-masking make it impossible to reach ROM, VRAM, or I/O from software as specified.
2. **G1 — No opcode values are assigned anywhere**, blocking the CPU decoder, assembler, disassembler, and every test ROM.
3. **E3/E4 — ROM shadowing and program loading both reference addresses that don't exist**: the shadow redirect target is undefinable as written, and the "known load address" for autoboot is never defined.

All are cheap to fix on paper now. A recommended pre-implementation "Block 0" is proposed in Section C.

---

## A. Errors

*(spec says two incompatible things, or a stated fact is internally impossible)*

---

**E1 — System vectors and IVT entries are 16-bit but must hold 20-bit addresses**
- **Severity:** Blocker
- **Locations:** Phase 2 §2.6 ("each a 2-byte address"), §2.7; Phase 1 §1.6; Phase 6 §6.7 ("$FFBC0–$FFBC1 RESET"); master §2.6, §6.5.
- **Description:** The RESET vector must point at boot code in ROM ($FC2xx — a 20-bit address). NMI/IRQ/BRK vectors likewise point into ROM; IVT entries must point anywhere in the 1MB space. A 2-byte vector holds at most $FFFF.
- **Consequence:** The machine cannot boot. No interrupt handler outside the first 64KB can be installed.
- **Recommended fix:** Make every vector **4 bytes** (32-bit little-endian, masked to 20 bits). IVT becomes 16 × 4 = 64 bytes. Note the elegant side effect: the System Vectors region is labeled "64 B" everywhere — 16 four-byte vectors fill it exactly. ROM vector layout becomes RESET +$00, NMI +$04, IRQ +$08, BRK +$0C, reserved +$10–$3F.

---

**E2 — 20-bit addresses cannot be computed or loaded: ALU masks results to 16 bits and LI/LUI semantics are undefined/contradictory**
- **Severity:** Blocker
- **Locations:** Phase 2 §2.1 ("ALU operations work on the lower 16 bits"), §2.4 (`LI` "18-bit sign-extended", `LUI` "load immediate into upper bits" — undefined); Phase 7 §7.6 (`set_reg` masks **every** register write with `& 0xFFFF`); Phase 8 §8.3 `LOAD_ADDR` macro (does `LI` then `LUI`, which only works if LUI preserves the low 16 bits — never stated, and impossible if set_reg masks to 16 bits).
- **Description:** Three mutually incompatible statements: (1) registers hold 20-bit addresses; (2) all register writes are masked to 16 bits in the reference code; (3) the official macro builds a 20-bit address by LI-then-LUI. As written, no instruction sequence can place $40000 (VRAM), $80000 (I/O), or $FC100 (syscalls) into a register, and pointer arithmetic across $FFFF is impossible (ADD masks to 16 bits).
- **Consequence:** Programs cannot touch VRAM, I/O registers, or ROM via register-indirect addressing. The entire memory map above 64KB is unreachable from software except via J-format absolute jumps.
- **Recommended fix (decision required, marked as recommendation):** Registers hold 20 significant bits. `set_reg` masks to `0xFFFFF`, not `0xFFFF`. FLAGS are always computed from the low 16 bits of the result (preserving the "16-bit data" model). Define: `LI RD, IMM18` → RD = sign_extend(IMM18) & $FFFFF; `LUI RD, IMM` → RD = (RD & $FFFF) | ((IMM & $F) << 16) (non-destructive OR into bits 19:16 — matches the LOAD_ADDR macro's LI-first ordering). Alternative: classic LUI-first-then-ORI; either works but **one must be locked** and the macro updated to match.

---

**E3 — ROM shadow redirect target is undefined and undefinable as specified**
- **Severity:** Blocker
- **Locations:** Phase 1 §1.7; Phase 6 §6.8 Stage 7 ("Allocate 16KB from free RAM... e.g. $04100"); Phase 7 §7.4 (`ram.read(masked)` with masked ≥ $FC000); plan task 2.4.
- **Description:** When shadow is enabled, reads to $FC000–$FFFFF "resolve to RAM" — but physical RAM ends at $7FFFF, and the program's shadow buffer is at an arbitrary, program-chosen address the bus cannot know. The Phase 7 reference code indexes the 512KB RAM array at offset ≥ $FC000 — an out-of-bounds panic.
- **Consequence:** Shadowing crashes the emulator the instant it's enabled; the feature is unimplementable as written.
- **Recommended fix:** Define a **fixed shadow window**: bus maps $FC000+off → $3C000+off (the top 16KB of general RAM). Update the Stage-7 procedure: copy ROM → $3C000–$3FFFF (no allocation choice), then set SYSCFG bit 0. Document that enabling shadow costs the top 16KB of free RAM. Also specify write behavior while shadowed (writes land in $3C000 window — making the shadowed "ROM" patchable live, which is the point).

---

**E4 — Program load address is never defined; `.flapp` has no load-address field; Phase 8 contradicts itself about who decides it**
- **Severity:** Blocker
- **Locations:** Phase 6 §6.8 Stage 6 ("check for valid program header at *known load address*" — never stated), §6.9; Phase 8 §8.6 ("The BIOS loads the .flapp at the address specified by the linker script **ENTRY** directive" — ENTRY names a *symbol*, not an address, and the BIOS never sees the linker script); §8.10 (`flommodore program.flapp` — emulator must load it somewhere); plan task 12.15.
- **Consequence:** Neither the BIOS autoboot scan nor the emulator's `.flapp` loader can be implemented; the linker and loader disagree about whose job placement is.
- **Recommended fix:** (a) Define the **canonical load address $04100** (start of free RAM) as the autoboot scan location and the emulator's default. (b) Add a 4-byte **load address** field to the `.flapp` header (growing it to 12 bytes) so non-default placement is possible; the emulator honors it, the BIOS autoboot only accepts $04100. Correct §8.6: load address comes from `SECTION code AT`, not ENTRY.

---

**E5 — IRQ vectoring contradiction: single IRQ line vs per-source IVT entries**
- **Severity:** Major
- **Locations:** Phase 5 §5.5 ("presents them to the Gab-16 CPU as a **single IRQ line**"; handler pattern reads IRQSTAT and software-dispatches); Phase 2 §2.6 (IVT entries 4–7 for Timer A, Timer B, raster, audio — implying hardware vectoring per source).
- **Description:** If all sources funnel into one line, the CPU always enters via IVT entry 2 and entries 4–7 are dead. If the CPU vectors per source, the controller must convey a source index — a mechanism nowhere defined.
- **Consequence:** CPU task 3.14 ("jump to IVT") and ROM IRQ dispatcher cannot be written; SYS_IRQSET (per-source handlers) is ambiguous.
- **Recommended fix:** Adopt **software dispatch** (matches the §5.5 handler pattern): all maskable device IRQs enter IVT entry 2; SYS_IRQSET maintains a BIOS-level dispatch table indexed by IRQSTAT bit. Re-document IVT entries 4–7 as "reserved" or as the BIOS dispatch table convention rather than hardware vectors.

---

**E6 — Default palette (768 B) does not fit its ROM slot (512 B)**
- **Severity:** Major
- **Locations:** Phase 6 §6.2 ("$FF800–$FF9FF 512 B Default palette") vs §6.6 ("256 entries × 3 bytes = 768 bytes"); master line ~1065 (512 B) vs Phase-6 key facts (768 bytes).
- **Consequence:** Boot stage 4 copies 768 bytes starting at $FF800, reading 256 bytes of reserved/garbage into the live palette.
- **Recommended fix:** Extend the slot to $FF800–$FFAFF (768 B); reserved becomes $FFB00–$FFBBF (192 B). (Alternative — RGB565 2-byte entries fitting 512 B — contradicts Phase 3's locked 24-bit palette entries; not recommended.)

---

**E7 — System vectors region: $FFBC0–$FFFFF is 1,088 bytes, labeled "64 B" everywhere; Phase 1 also contains a 4-digit address typo**
- **Severity:** Major
- **Locations:** Phase 1 §1.2 ("System Vectors 64 B ($FFC0 – $FFFFF)" — invalid 4-digit address), §1.6; Phase 6 §6.2/§6.7; master lines 82, 191, 1067.
- **Description:** $FFFFF − $FFBC0 + 1 = $440 = 1,088 B, not 64 B. The "$FFC0" typo strongly suggests the original intent was **$FFFC0–$FFFFF** (exactly 64 B at the true top of ROM, matching "top of ROM" wording in Phase 2 §2.7).
- **Recommended fix:** Move vectors to **$FFFC0–$FFFFF** (64 B — and with E1's 4-byte vectors, exactly 16 entries). Reserved region becomes $FFB00–$FFFBF (after E6). Update RESET vector references ($FFBC0 → $FFFC0) in Phases 1, 2, 6, master, and plan task 5.2.

---

**E8 — KDATA is a 16-bit value at byte address $80021; I/O register access width is undefined and the two phase docs imply different models**
- **Severity:** Major
- **Locations:** Phase 5 §5.3 (registers presented as byte-granular map; scancode format is 16-bit); Phase 7 §7.9 (`io.read` returns a full u16 per single address, e.g. `0x80021 => keyboard_dequeue()`).
- **Description:** Under a byte-addressed model, a 16-bit read at $80021 overlaps KMOD at $80022; under Phase 7's model, each address yields an independent 16-bit value (so what does LB do? what does a 16-bit read at $80020 return — KSTAT only, or KSTAT|KDATA<<8 with a destructive dequeue side effect?).
- **Consequence:** Every I/O driver and test ROM depends on this; KDATA reads have side effects, so getting it wrong silently eats keystrokes.
- **Recommended fix:** Adopt the Phase 7 model and make it normative: *each I/O register is a 16-bit value at its listed address; access I/O with LW/SW at the exact register address; LB/SB on I/O access the low byte; reads never combine adjacent registers.* Document KDATA's dequeue-on-read side effect explicitly.

---

**E9 — TxCTRL has both a "repeat" bit (1) and a "one-shot" bit (3)**
- **Severity:** Major
- **Locations:** Phase 5 §5.2.
- **Description:** Repeat and one-shot are the same axis. Both-set and both-clear states are undefined.
- **Recommended fix:** Delete bit 3; one-shot ≡ repeat=0. (Frees a bit for future use.)

---

**E10 — Filter routing is specified by two different mechanisms**
- **Severity:** Major
- **Locations:** Phase 4 §4.5 + §4.9 (per-voice VCTRL filter-route bit) vs §4.8 + §4.10 (global AMFILT per-voice route bits).
- **Recommended fix:** Keep **AMFILT** (one register to read/write all routing), remove the VCTRL bit. If both are kept, define the combination (OR) — not recommended.

---

**E11 — Panning is specified by two different mechanisms**
- **Severity:** Major
- **Locations:** Phase 4 §4.9 (VCTRL `Pan[1:0]`) vs §4.8/§4.9 (per-voice VVOLL/VVOLR).
- **Recommended fix:** Keep VVOLL/VVOLR (continuous panning, already in the register map); remove Pan[1:0] from VCTRL, freeing 2 bits.

---

**E12 — Sprite collision: "per-sprite collision flag" claimed, but VSTAT bit 2 is a single global bit**
- **Severity:** Major
- **Locations:** Phase 3 §3.6 (property table) vs §3.8 (VSTAT layout).
- **Recommended fix:** Either downgrade the claim to a single global sprite-collision flag (simplest, C64-adjacent), or add an 8-byte collision bitmap at $80218+. Also specify: collision = sprite-sprite (opaque pixel overlap), when set (per frame), and clear semantics (recommend write-1-to-clear, matching ASTAT/TxSTAT convention).

---

**E13 — Sprite priority: "all sprites above tile and bitmap layers" contradicts the per-sprite SAT `priority` bit**
- **Severity:** Major
- **Locations:** Phase 3 §3.1/§3.6 vs §3.6 SAT byte 5.
- **Recommended fix:** Define the priority bit C64-style: 0 = sprite in front of tile layer, 1 = sprite behind tile layer (but in front of bitmap/background). Update §3.1's blanket statement.

---

**E14 — `.flobj` format has no symbol count or relocation count fields**
- **Severity:** Major
- **Locations:** Phase 8 §8.4 (header carries only magic, version, section count; symbol and relocation tables follow with no length).
- **Consequence:** A reader cannot determine where the symbol table ends and relocations begin; the format is unparseable.
- **Recommended fix:** Header → magic(2) | version(1) | section count(1) | **symbol count(2) | relocation count(2)**. Also state on-disk endianness (recommend little-endian throughout, with magics defined as *byte sequences* 'F','O' so they remain readable in hex dumps — see G15).

---

**E15 — Emulator architecture makes raster effects impossible despite the spec promoting them**
- **Severity:** Major
- **Locations:** Phase 7 §7.10 (main loop runs CYCLES_PER_FRAME of CPU, *then* calls `render_frame()`, which renders all scanlines and fires raster IRQs back-to-back with no CPU execution in between) vs §7.7 ("renders scanline by scanline so raster interrupts fire at the correct line") and Phase 3 §3.6/§3.9 (sprite multiplexing and per-zone raster effects are explicitly celebrated features).
- **Consequence:** A raster IRQ handler cannot change VIC registers "mid-frame" because no CPU cycles execute between scanlines — the headline raster features silently don't work.
- **Recommended fix:** Scanline-interleaved main loop: run CYCLES_PER_LINE CPU cycles → render one scanline → evaluate raster/VBLANK IRQ → repeat. Requires the timing model of G6. Update plan Block 5/6 accordingly (see P2).

---

**E16 — Master spec internally conflicts with itself on the ROM layout, mirroring the Phase 1 ↔ Phase 6 disagreement, plus a range typo**
- **Severity:** Major
- **Locations:** Master §1.6 (256 B header, no palette, $FF800–$FFBBF reserved) vs master §6.1 (32 B header, jump table $FC100–$FC1FF, palette at $FF800); master combined map: "`$81000 – $FBBFF` Reserved" — should be $FBFFF (leaves $FBC00–$FBFFF unaccounted).
- **Recommended fix:** Phase 6's layout is the more detailed and internally consistent version — it should win. Rewrite master §1.6 (and Phase 1 §1.6) to match Phase 6 §6.2 exactly (with E6/E7 corrections applied), and fix the $FBBFF typo.

---

**E17 — "24 registers in total" but only 22 are listed**
- **Severity:** Minor
- **Locations:** Phase 2 §2.1: 16 GP + 6 special (PC, FLAGS, IVT, USP, SYS, CYC) = 22, with a note implying SP/LR are double-counted to reach 24.
- **Recommended fix:** Say "16 GP + 6 special" plainly — or, better, use the two phantom slots for registers the design actually needs: **SSP** (supervisor stack pointer, see G4) and reserve one. That makes "24" true and fixes a real gap.

---

**E18 — Shadow-buffer example range is 12KB, not 16KB**
- **Severity:** Minor
- **Locations:** Phase 6 §6.8 Stage 7: "$04100 – $070FF" spans $3000 = 12,288 B. 16KB from $04100 ends at $080FF.
- **Recommended fix:** Superseded by E3's fixed window; if the example survives, correct it to $04100–$080FF.

---

**E19 — Initial SP = $010FF makes every push unaligned**
- **Severity:** Minor
- **Locations:** Phase 6 §6.8 Stage 1; master §6.6. PUSH is `SP -= 2; [SP] = RA`, so the first word lands at $010FD (odd).
- **Recommended fix:** Initialize SP = **$01100** (empty-descending; first push lands at $010FE–$010FF, inside the stack region, word-aligned). State an alignment convention for the stack even though unaligned access is legal.

---

**E20 — Opcode count drift: "~50" claimed, 48 real opcodes listed, plan says "all 50"**
- **Severity:** Minor
- **Locations:** Phase 2 §2.4 (counting the tables: 6+13+6+13+4+7 = 49 mnemonics, of which MOV is explicitly a pseudo → 48 opcodes); plan task 10.5 ("all 50 opcodes").
- **Recommended fix:** Resolved automatically when G1's opcode table is written; until then, say "48 opcodes + 1 pseudo".

---

**E21 — Phase 7 reference snippets contain defects that will be copied verbatim ("the emulator is the reference")**
- **Severity:** Minor (each individually; collectively worth a sweep)
- **Locations & issues:** §7.6 `update_flags` — the V formula `(a^result)&(b^result)` and C test `result > 0xFFFF` are correct **only for ADD**; SUB/CMP need the subtraction forms (see G14a). §7.8 wavetable sample is scaled to ±128 while every other waveform is ±32767 (wavetable would be ~256× quieter). §7.5 `ram.read(addr)` reads `data[addr+1]` — out of bounds at $7FFFF. §7.10 `CYCLES_PER_FRAME = 14_000_000 / 60` — inexact comptime integer division is a **compile error** in Zig. §7.9 timer `tick()` ignores TxDIV entirely.
- **Recommended fix:** Either fix the snippets or mark them "illustrative — normative behavior defined in Phases 2–5"; given Phase 7's self-declared authority, fixing is better.

---

**E22 — Implementation plan internal inconsistencies**
- **Severity:** Minor
- **Locations:** Block 10 header says "Depends on: Block 1" while the dependency graph hangs Block 10 off Block 2. Task 5.2 says "infinite loop **at** $FFBC0" — $FFBC0 is where the vector *lives*; the loop must live elsewhere and the vector point at it.
- **Recommended fix:** Graph and text should both say Block 1 (the assembler needs no emulator code); reword 5.2 ("RESET vector at $FFFC0 pointing to an infinite loop in ROM body").

---

**E23 — `.flst` listing example bytes are inconsistent with the encoding scheme**
- **Severity:** Minor
- **Locations:** Phase 8 §8.8 — `HLT` shown as `FF 00 00 00` (opcode field is 6 bits; no byte order stated; the bytes shown can't decode under any consistent reading).
- **Recommended fix:** Regenerate the example once G1's opcode table exists; state the listing's byte order (recommend: bytes in file/memory order, i.e., little-endian word).

---

## B. Gaps

*(spec is silent or ambiguous on something implementation requires)*

---

**G1 — No opcode values are assigned anywhere**
- **Severity:** Blocker
- **Locations:** Phase 2 §2.4 lists mnemonics only; no numeric opcode table, no FUNC-field values for R-format sub-ops, no definition of the R-format 5-bit FLAGS field.
- **Consequence:** CPU decode (3.3), assembler pass 2 (10.5), disassembler (9.4), and every hand-built test ROM are blocked. This plus P1 is the project's critical path.
- **Recommendation:** Publish a complete encoding table before Block 3: opcode value per mnemonic, FUNC value per R-format ALU sub-op (one ALU opcode + FUNC selector, or one opcode each — pick one), and define the R-format FLAGS field (recommend: bit 0 = "suppress flag update", rest reserved-zero — or simply declare the field reserved-zero in v1).

---

**G2 — No instructions exist to read/write special registers (IVT, SYS, CYC, FLAGS, USP)**
- **Severity:** Blocker
- **Locations:** Phase 2 §2.1/§2.4 — boot Stage 1 says "Load IVT register" (Phase 6 §6.8) but no instruction can do it; CYC is "read-only for profiling" with no read path.
- **Recommendation:** Add `MTSR sreg, RA` / `MFSR RD, sreg` (R-format, sreg in the RB/FUNC field; IVT/SYS writes supervisor-only). Two opcodes from the reserved pool.

---

**G3 — SYS instruction semantics undefined**
- **Severity:** Major
- **Locations:** Phase 2 §2.4 ("trap to kernel vector" — which vector? what does IMM mean?); meanwhile the actual syscall mechanism (Phase 6 §6.4) is the CALLA jump table and never uses SYS.
- **Recommendation:** Either define `SYS IMM` → interrupt-style entry through IVT entry 3 with IMM latched in a readable register (needs G2), or **drop SYS from v1** — the jump table fully covers the use case. Dropping is cleaner.

---

**G4 — Interrupt entry/exit underspecified: PC push width, supervisor stack, nesting, re-entry while S=1, HLT+I=0**
- **Severity:** Major
- **Locations:** Phase 2 §2.6 ("pushes PC then FLAGS... saves user SP into USP" — onto *which* stack? SP is then... what?); Phase 7 §7.6 step() (HLT with I=0 sleeps forever — intended?).
- **Recommendation:** Add an **SSP** register (fits E17's missing slots). Entry when S=0: USP←SP, SP←SSP, push PC (4 B, per E1's width) then FLAGS (2 B), set S, clear I. Entry when S=1 (nested): push without touching USP. RTI: pop FLAGS, pop PC; if restored S=0 then SSP←SP, SP←USP. Define frame as 6 bytes. State explicitly: HLT wakes only on an unmasked IRQ with I=1; HLT with I=0 halts until reset (or define NMI as the escape — see G13).

---

**G5 — Per-instruction cycle counts are not specified**
- **Severity:** Major
- **Locations:** Nowhere; Phase 7's loop implicitly assumes 1 cycle/instruction (`cyc +%= 1` per step, timer tick per step); Phase 5's PCM table ("reload ≈ 39") presumes a concrete relationship.
- **Recommendation:** Declare normatively: **every instruction costs exactly 1 cycle** (14 MHz = 14 MIPS — fantasy hardware is allowed to be magic). It makes timers, raster timing, and tests deterministic and matches all existing reference code. Alternative (per-class costs, e.g., mem=2) doubles test complexity for little authenticity gain.

---

**G6 — Video timing model undefined: total scanlines, cycles per scanline, VBLANK duration, VSTAT set/clear timing, VSWAP read-back**
- **Severity:** Major
- **Locations:** Phase 3 §3.11 gives only "60 Hz"; required by E15's fix and by test_vic_* determinism.
- **Recommendation:** Define per vertical resolution: total lines = visible + fixed VBLANK lines, and CYCLES_PER_LINE = CYCLES_PER_FRAME ÷ total lines — chosen to divide exactly (see G16 for clock choice). Define VSTAT bit 0 set at first VBLANK line, cleared at line 0; raster IRQ asserted at the start of the target line; VSWAP bit readable as pending until the swap, auto-clears at VBLANK (already stated) — add that the VBUF register contents are exchanged (visible to reads).

---

**G7 — VRESX/VRESY encodings undefined**
- **Severity:** Major
- **Locations:** Phase 3 §3.8 ("resolution select" — no values); plan 6.2/6.5 need them.
- **Recommendation:** VRESX: 0=320, 1=640, 2=960, 3=1280; VRESY: 0=180, 1=360, 2=540, 3=720; define the legal (X,Y,bpp) combination set from §3.4's table and the behavior of illegal writes (recommend: register accepts the write, VIC outputs mode 320×180 fallback, sets a VSTAT error bit — or simply clamps; pick one).

---

**G8 — VBUF/VPAL/VSAT/VTMAP base registers are 16 bits but must address up to 256KB**
- **Severity:** Major
- **Locations:** Phase 3 §3.8 — VBUFLO/HI (framebuffer offsets within 256KB VRAM need 18 bits), VPALBASE/VSATBASE/VTMAPBASE (general-RAM addresses up to $3FFFF need 18 bits).
- **Recommendation:** Define all five base register pairs as holding **address ÷ 16** (16-byte granularity): 16 bits × 16 = 1MB reach, all tables 16-byte aligned (trivial constraint). VBUF values are absolute addresses (must land in $40000–$7FFFF); table bases must land in $00000–$3FFFF. Alternative (third MID byte each) burns 5 registers; granularity is cleaner.

---

**G9 — 5bpp mode: pixel packing undefined; mode absent from the tile table and from the implementation plan entirely**
- **Severity:** Major
- **Locations:** Phase 3 §3.2/§3.4 list 5bpp; §3.7 tile table covers only 8/4 bpp; plan Block 6 implements 8, 4, and 1 bpp only (6.5–6.7).
- **Recommendation:** **Drop 5bpp** from v1. Packing 5-bit pixels is awkward (crosses byte boundaries every pixel), no other part of the design uses it, and the plan already votes with its feet. If kept: define 1 pixel/byte (low 5 bits) and add plan tasks.

---

**G10 — Text mode (Mode 3) cell format, screen matrix location, attribute layout, font bit order, and cursor model undefined**
- **Severity:** Major
- **Locations:** Phase 3 §3.5 ("character code and a colour attribute byte"); Phase 6 §6.5 (font is 1bpp 8×8); SYS_PUTCHAR/SETCURSOR imply a cursor.
- **Recommendation:** Define: text matrix in general RAM via VTMAPBASE, 2 bytes/cell little-endian (byte 0 = char code, byte 1 = attribute: low nibble fg index, high nibble bg index, using palette entries 0–15); cells = resX/8 × resY/8; font glyph bit 7 = leftmost pixel; cursor is **BIOS software state** in System Variables (hardware has no cursor) — document its variable address or keep it private behind syscalls.

---

**G11 — Sprite graphics storage and indexing undefined; SAT/VCTRL bit ordering ambiguous**
- **Severity:** Major
- **Locations:** Phase 3 §3.6 (SAT byte 4 "tile index" — index into what, at what stride for 16×16/32×32, in which bpp?); §3.7 VRAM layout has no sprite-graphics region; Phase 1 §1.4 says VRAM holds "sprite attribute tables & bitmaps" (contradicting Phase 3's SAT-in-general-RAM — Phase 3 should win); SAT flags byte and AUR VCTRL list fields with no MSB/LSB convention.
- **Recommendation:** Sprites read graphics from the **tile graphics RAM** at $40000: address = $40000 + index × bytes_per_sprite(size, bpp); for 16×16/32×32 the index is in units of that sprite size (so large sprites consume multiple 8×8 slots' worth of space — document the math). Adopt a global convention: *all packed bit-field lists in this spec read MSB→LSB* — then SAT byte 5 = enable(7) flipX(6) flipY(5) size(4:3) priority(2) spare(1:0), and AUR VCTRL gate=7 matches §4.4's "bit 7". Fix Phase 1 §1.4's stale "SAT in VRAM" wording.

---

**G12 — AUR-1 numeric semantics: frequency mapping, ADSR rate table, wavetable format, FM math, filter mapping, mixer clipping, ring/sync for voice 0, ASRATE effects**
- **Severity:** Major
- **Locations:** Phase 4 throughout; Phase 7 §7.8 partially implies a phase-accumulator model.
- **Recommendation (one decision per line):** Frequency: 16-bit phase increment into a 16-bit accumulator; F_out = freq_word × sample_rate ÷ 65536 (document; at 44.1kHz, A440 ≈ $0289). ADSR: publish a 16-entry rate table in ms (copy the SID's documented values — they're the stated inspiration). Wavetable: **unsigned** 8-bit samples, $80 = zero-cross (matches Phase 7's `−128` conversion; fix its scaling per E21). FM: modulator output (post-envelope) × depth ÷ 65536 added to carrier's phase increment per sample; feedback = modulator's own previous output × (fbk/8) added to its phase. Filter: state-variable filter; cutoff_hz = (value/4095)² × 12000 + 30 (or any locked curve); resonance Q = 0.5 + res × 0.9. Mixer: signed 32-bit sum, saturate to i16 after master volume. Ring/sync: voice 0's "previous voice" is **voice 3** (SID-style wraparound). ASRATE: changes synthesis tick rate; emulator may resample or run SDL stream at the selected rate — define output as always 44.1kHz host-side with internal rate per ASRATE.

---

**G13 — I/O semantics: IRQPRI meaning, mask-vs-status interaction, two-level IRQ enables, joystick-change granularity, SYSPWR behavior, NMI source**
- **Severity:** Major
- **Locations:** Phase 5 §5.5 (IRQPRI "fixed/round-robin" — priority of *what*, given a single line and software dispatch?), §5.2–5.4; Phase 2 §2.6 (NMI vector exists; no NMI source is defined anywhere).
- **Recommendation:** Delete IRQPRI (meaningless under E5's software-dispatch resolution) or redefine as reserved. Define: IRQSTAT shows raw pending status regardless of IRQMASK; the CPU line = (IRQSTAT & IRQMASK) ≠ 0; device-level enables (TxCTRL bit 2, KCTRL bit 0, VIRQEN, AIRQEN) gate whether the device *sets* its IRQSTAT bit. Joystick IRQ fires on any bit transition of either port. SYSPWR bit 0 = emulator exits cleanly (document). NMI: no hardware source in v1 — reserve it for the debugger ("break" injects NMI) or document as never raised.

---

**G14 — Memory edge semantics: per-op flag definitions, boundary-straddling word access, ROM/open-bus writes, address wraparound**
- **Severity:** Major
- **Locations:** Phase 2 §2.2 (flags defined globally, not per instruction); Phase 7 §7.4/§7.5 (illustrative only).
- **Recommendation:** (a) Per-op flag table: ADD/ADDI set ZNCV (C=carry-out, V=add overflow); SUB/SUBI/CMP/CMPI set ZNCV with **C = no-borrow (ARM convention: C=1 when RA ≥ RB unsigned)** — this makes BCS/BCC meaningful after CMP and must be stated, since 6502 and ARM agree but Z80 differs; logic ops set ZN, clear C and V; shifts set ZN, C = last bit shifted out, V cleared; shift amount uses RB low 4 bits (shift ≥ 16 impossible by construction — state it); MUL sets ZN from low 16 bits, C=V=0 (or C=high-half≠0 — pick one); DIV/MOD by zero: RD = $FFFF, set V, no trap (or trap to BRK — pick one; no-trap is simpler). LW/LB/SW/SB/LI/LUI/jumps/stack ops: flags unaffected. (b) Word access straddling a region boundary: route **per byte** through the bus (each byte goes to its own region) — simplest and matches a byte-lane bus; addresses wrap at $FFFFF→$00000. (c) Writes to non-shadowed ROM and to open bus: silently ignored (promote Phase 7's behavior to normative). (d) Unaligned word access: permitted, no penalty (promote §7.5's statement to the CPU spec, where an implementer will actually look for it).

---

**G15 — Toolchain semantics: relocation-type ↔ field mapping, ORG vs linker-script interplay, on-disk endianness/magic byte order, raw-ROM output path**
- **Severity:** Major
- **Locations:** Phase 8 §8.4 (four relocation types named, never defined against instruction fields), §8.3 (hello.asm uses ORG while §8.5's linker script places sections — which wins, and is ORG even legal in a relocatable section?), §8.2/§6.3 (is magic `$4642` stored as bytes 46 42 — readable "FB" in a dump — or little-endian 42 46? The "readable in hex dumps" rationale and a little-endian machine pull opposite ways); Block 12.16 needs a 16KB raw ROM image but `fll` only emits `.flapp` with a header.
- **Recommendation:** (a) Define relocations: ABS16 (patch a DW), ABS26 (patch J-format ADDR26 field), PCREL26 (patch J-format with target − (instr_addr+4)), LO16 (patch I-format IMM18 with addr & $FFFF), HI4 (patch I-format IMM18 with addr >> 16) — note "high-word/low-word" as named won't survive contact with the 18-bit immediate field; define them against actual fields. (b) ORG is legal only outside SECTIONs (absolute mode, no linker needed — how test ROMs get built); SECTION-based code takes placement from the script; mixing in one file is an error. (c) **All multi-byte file fields are little-endian; magics are defined as byte *sequences*** ('F' then 'B'), so they read correctly in dumps and the "$4642" notation should be annotated as byte order, not a u16. (d) Add `fll --raw --base $FC000 --size 16K` (pad, no autoboot header, verify vectors present at $FFFC0) for ROM builds — see P4.

---

**G16 — Master clock: "~14 MHz" vs "14MHz"; 14,000,000/60 is not an integer**
- **Severity:** Minor (but a one-line decision with outsized payoff)
- **Locations:** Phase 5 §5.2 ("~14 MHz"), Phase 6 banner ("@ 14MHz"), Phase 7 §7.10.
- **Recommendation:** Pick **14,400,000 Hz**: 240,000 cycles/frame exactly at 60 Hz, divides into clean scanline counts (e.g., 400 total lines × 600 cycles, or 450 × 533⅓ — choose line counts that divide; 480 lines × 500 cycles also works), and keeps the "14 MHz-class" marketing. Recompute the Phase 5 divisor table (÷8 = 1.8 MHz; 44.1 kHz reload ≈ 40).

---

**G17 — BIOS RAM locations for palette/SAT/tile map unspecified**
- **Severity:** Minor
- **Locations:** Phase 6 §6.8 Stage 4 writes the three base registers "in general RAM" with no addresses.
- **Recommendation:** Fix them in the Kernel Workspace and document (e.g., palette $02100–$023FF, SAT $02400–$025FF, text matrix $02600+), so programs can cooperate with the BIOS or know what they're clobbering.

---

**G18 — Syscall behavioral details unspecified**
- **Severity:** Minor
- **Locations:** Phase 6 §6.4 — SYS_GETLINE (echo? terminator? returns length where?), SYS_GETCHAR (which scancode→ASCII mapping, shift handling), SYS_MEMCMP (result convention: 0/±1? first-difference?), SYS_RAND (algorithm — matters for test determinism; recommend a fixed 16-bit xorshift/LCG, documented), SYS_IRQSET handler contract (called by BIOS dispatcher with plain CALL → handler ends with RET, BIOS does the RTI — recommend and document), SYS_TWAIT on a disabled timer (blocks forever? returns error?). Each is a one-line decision; list them in the ROM block's task acceptance criteria.

---

**G19 — Keyboard details: caps/num-lock ownership; HID scancodes ≤ $FF**
- **Severity:** Minor
- **Locations:** Phase 5 §5.3.
- **Recommendation:** Note that HID keyboard-page usages fit in 8 bits ($00–$E7) ✓; define KSTAT caps/num lock as mirroring host LED state via SDL. Also define KCTRL bit 1 (flush) as write-1-to-flush, self-clearing.

---

**G20 — CYC counter wrap**
- **Severity:** Minor
- **Locations:** Phase 2 §2.1 (32-bit, read-only): wraps every ~5 minutes at 14 MHz.
- **Recommendation:** Document wrap as defined behavior; read via G2's MFSR.

---

**Subsystems with no findings:** the I/O address allocation itself is clean — no register collisions, all reserved holes declared (full table in Appendix D). The VRAM budget table in §3.4 is arithmetically sound apart from one stray figure (960×540@4bpp "257 KB"; actual 253 KiB / 259 dec — cosmetic, the ✗ verdict is correct either way) and inconsistent KB-vs-KiB rounding (cosmetic). The double-buffering feasibility table checks out. The syscall table is exactly 29 entries with consistent IDs and addresses across Phase 6, master, and the plan. Magic numbers $464C/$4642/$464F decode to the claimed ASCII and don't collide.

---

## C. Implementation Plan Improvements

---

**P1 — Test-ROM chicken-and-egg: Blocks 3–8 require test ROMs, but the assembler is Block 10 / Milestone 4 (and hand-assembly is impossible while G1 stands)**
- **Severity:** Blocker
- **Locations:** Plan Block 3 tasks 3.5–3.15 ("`test_cpu_*.rom` passes"), Implementation Principle 3, vs Block 10 placement.
- **Recommended fix:** Build a shared **instruction encoder module** (`src/encode.zig`) immediately after Block 2: pure functions `addi(rd, ra, imm) u32` etc., driven by G1's opcode table. Test ROMs are then Zig programs that emit byte arrays via the encoder into `tests/roms/` at build time (a `zig build genroms` step). Later, Block 10's codegen pass 2 **imports the same encoder** — one source of encoding truth, zero duplicate bug surface, and the assembler's hardest part is pre-tested by months of CPU test use. (Alternatives considered: pull the full assembler forward — slower to first CPU test; hand-hex — error-prone and blocked by G1 anyway.)
- **Proposed task insert (new Block 2½ or tasks 2.6–2.8):**
  - 2.6 Write the opcode/FUNC assignment table into the spec (closes G1) — *done when every mnemonic has a numeric encoding*
  - 2.7 Implement `encode.zig` from that table, unit-tested round-trip against `decode` — *done when encode∘decode is identity for all opcodes*
  - 2.8 Implement `zig build genroms`: test-ROM builders emit `tests/roms/*.rom` — *done when a NOP-loop ROM generates and loads*

---

**P2 — Restructure Block 5/6 for the scanline-interleaved loop (consequence of E15) and add a raster-effect acceptance test**
- **Severity:** Major
- **Locations:** Plan 5.1 ("frame boundary at 233,333 cycles"), Block 6 render pipeline, 6.16.
- **Recommended fix:** 5.1 becomes: main loop advances in **scanline quanta** — run CYCLES_PER_LINE cycles, notify VIC of line completion; VIC renders that line and evaluates raster IRQ; at last line, VBLANK IRQ + present + audio push + events. Insert a new task before 6.15: *define timing constants per mode (G6/G16) in a shared `timing.zig`*. Strengthen 6.16's "done when": *a test ROM that changes VBGCOL in its raster handler produces a visibly split frame (verified by golden-image hash)* — this is the test that proves the architecture, not just the IRQ wire.

---

**P3 — Add a "Block 0 — Spec corrections" gate before any CPU code**
- **Severity:** Major
- **Locations:** New; blocks 3, 10, 12 all build on the broken items.
- **Recommended fix:** One or two days resolving, in writing, the decision-required findings: E1 (vector width + $FFFC0), E2 (register/LUI model), E3 (shadow window), E4 (load address + .flapp field), E5 (IRQ dispatch model), G1 (opcode table), G2 (MTSR/MFSR), G4 (SSP + frame layout), G5 (1 cycle/instr), G14 (flag table), G16 (clock). Every one is pencil-and-paper; deferring any of them turns into multi-block rework (E2 alone touches cpu.zig, encode.zig, flas, the ROM, and every test).

---

**P4 — Coverage holes: spec features with no plan task, and one plan task with no spec support**
- **Severity:** Major
- **Locations / items:**
  - *Emulator `.flapp` loading and CLI (Phase 8 §8.10) has **no task anywhere*** — `flommodore program.flapp`, `--debug`, `--sym`, `--rom` are never built. Add tasks (suggested Block 11.11–11.12 or a small Block 5½): implement CLI arg parsing; load `.flapp` to its load address (E4), seed autoboot or jump directly.
  - *ROM image emission*: 12.16 assumes the linker can produce a raw 16KB ROM — it can't (G15d). Add task 11.x: `fll --raw` mode with base/size/vector validation.
  - *5bpp mode* (G9): add tasks or formally drop — currently it's specified but unplanned, the worst of both.
  - Unplanned registers/behaviors: VSPRENA (sprite group enables), KCTRL flush bit, joystick IRQ (JCTRL — Block 8 maps state but never the IRQ), ASRATE, SYSPWR action, IRQPRI (delete per G13 or implement). Add one "register completeness sweep" task per device block with a checklist drawn from Appendix D.
  - *Sprite-behind-background priority* (E13 resolution) is implied by 6.12 "priority" — make the acceptance criterion explicit once E13 is decided.
- **Consequence if unfixed:** Milestone 4's "run in emulator" (11.10) and Milestone 5's ROM build (12.16) both dead-end on missing loader/emitter machinery discovered mid-block.

---

**P5 — Risk ordering: surface the three integration risks earlier**
- **Severity:** Major
- **Locations:** Plan 5.4, 7.20, 9.1.
- **Recommended fix:**
  - *Audio drift*: the push model accumulates latency or underruns unless managed. Add to 7.20's "done when": *queue depth (via `SDL_GetAudioStreamQueued`) stays within a defined window over 60s* — and add a task to adapt samples-per-frame to hold that window.
  - *Throttling* (5.4): specify the approach (frame-time pacing with sleep + spin remainder; never sleep inside a scanline quantum) so "approximately correct speed" is testable.
  - *Dear ImGui via cimgui under Zig 0.16*: this is the most uncertain dependency in the plan (cimgui + an SDL3 backend + Zig bindings must all line up — verify current state via Context7 at implementation time rather than assuming). Move 9.1 to a same-week spike alongside Block 5, and make the **text-console debugger the primary deliverable** of Block 9 (the spec already allows it: Phase 7 §7.11 "can also be driven from a text console"), with the ImGui overlay as a stretch task. The debugger is too valuable to be hostage to a bindings problem.

---

**P6 — Zig 0.16 / SDL3 staleness sweep**
- **Severity:** Minor
- **Locations:** Phase 7 §7.2 / §7.10, plan 1.1–1.2.
- **Recommended fix:** The docs pin Zig 0.14; the project targets 0.16. The build-system API (module wiring via `b.addModule`/`root_module`, dependency handling in `build.zig.zon`) changed across these versions — task 1.1/1.2's "done when" should add *"using current Zig 0.16 build APIs, verified against Context7 docs"* rather than transcribing Phase 7 snippets. Concrete known issue regardless of version: `14_000_000 / 60` is an inexact comptime division → compile error (E21); with G16's 14.4 MHz clock it becomes exact, killing the bug at the spec level. SDL3 calls shown (`SDL_OpenAudioDeviceStream`, `SDL_PutAudioStreamData`) match the SDL3 stream API shape — verify exact signatures at implementation time per project instructions.

---

**P7 — Missing infrastructure tasks: CI, golden tests, fuzzing, determinism**
- **Severity:** Minor
- **Recommended fix:** Add: (1.5) CI workflow — `zig build test` + cross-compile all three targets per commit; (2.9) headless/determinism mode — no SDL init, fixed RAND seed, `--max-cycles`; (6.20) golden-frame tests — hash the RGB24 buffer for each VIC test ROM against checked-in hashes; (7.22) golden-audio tests — hash N samples with fixed LFSR seed (taps are already pinned at $B400 ✓); (3.17) decoder fuzz — feed random u32s, assert "trap, never panic". All are cheap once the harness exists and convert "looks right" into regression protection — essential for a *reference* implementation.

---

**P8 — Plan text corrections**
- **Severity:** Minor
- **Items:** Block 10 dependency text vs graph (E22); 5.2 vector wording (E22); 10.5 "all 50 opcodes" → match G1's table (E20); 12.16 typo "autboots". Dependency graph otherwise validates: Block 4's dependence on 3 (IRQ delivery) and 12's on {3,4,6,10,11} are correct; Block 9's parallelism claim holds.

---

### Revised task list (only blocks with recommended changes)

**Block 0 (new) — Spec corrections (1–2 days):** lock decisions for E1–E5, G1, G2, G4, G5, G14, G16; update Phases 1/2/6/master.
**Block 2 — add 2.6 opcode table / 2.7 `encode.zig` / 2.8 `genroms` / 2.9 headless mode.**
**Block 5 — 5.1 rewritten as scanline-quantum loop; add 5.5 `.flapp` loader + CLI skeleton (or defer to 11.11).**
**Block 6 — insert timing-constants task before 6.15; 6.16 acceptance = split-screen golden image; drop or add 5bpp explicitly; add 6.20 golden-frame harness.**
**Block 7 — 7.20 acceptance includes queue-depth window; add 7.22 golden-audio.**
**Block 9 — reorder: console debugger first (9.2–9.10 against stdin/stdout), ImGui (9.1, 9.11–9.13 UI) as second pass; 9.1 spiked early.**
**Block 11 — add 11.11 `fll --raw` ROM emission; 11.12 emulator CLI flags (`--debug`, `--sym`, `--rom`).**
**Block 12 — 12.15 references the canonical load address from E4; add per-syscall behavioral criteria from G18.**

---

## D. Register Address Map (appendix)

Complete sorted I/O register table assembled from Phases 3, 4, 5. **No address collisions found.** All holes are explicitly declared reserved. The only width hazard is KDATA (E8), and the only undefined-encoding registers are VRESX/VRESY (G7) and IRQPRI (G13).

| Address | Register | Device | Note |
|---|---|---|---|
| $80000 | SYSCFG | System | bit 0 = ROM shadow |
| $80001 | SYSID | System | RO, $F1 |
| $80002 | SYSVER | System | RO |
| $80003 | SYSPWR | System | behavior undefined (G13) |
| $80004–$8000F | — | System | reserved |
| $80010 | TALOADLO | Timer A | |
| $80011 | TALOADHI | Timer A | |
| $80012 | TACNTLO | Timer A | RO |
| $80013 | TACNTHI | Timer A | RO |
| $80014 | TACTRL | Timer A | repeat/one-shot conflict (E9) |
| $80015 | TADIV | Timer A | |
| $80016 | TASTAT | Timer A | w1c |
| $80017 | — | Timer A | reserved |
| $80018–$8001F | TB* (as above) | Timer B | |
| $80020 | KSTAT | Keyboard | |
| $80021 | KDATA | Keyboard | 16-bit, dequeue-on-read (E8) |
| $80022 | KMOD | Keyboard | |
| $80023 | KCTRL | Keyboard | flush bit unplanned (P4) |
| $80024–$8002F | — | Keyboard | reserved |
| $80030 | JOY1 | Joystick | |
| $80031 | JOY2 | Joystick | |
| $80032 | JCTRL | Joystick | IRQ unplanned (P4) |
| $80033–$8003F | — | Joystick | reserved |
| $80040 | IRQSTAT | IRQ ctrl | RO |
| $80041 | IRQMASK | IRQ ctrl | |
| $80042 | IRQACK | IRQ ctrl | WO, w1c |
| $80043 | IRQPRI | IRQ ctrl | semantics undefined (G13) |
| $80044–$8004F | — | IRQ ctrl | reserved |
| $80050–$800FF | — | Expansion | reserved, 176 B |
| $80100–$8010F | Voice 0: VFREQLO/HI, VWAVE, VCTRL, VADSR0/1, VPULSE, VVOL, VMODLO/HI, VFBK, VWTBLO/HI, VVOLR, VVOLL, res | AUR-1 | VCTRL conflicts E10/E11 |
| $80110–$8011F | Voice 1 (same layout) | AUR-1 | |
| $80120–$8012F | Voice 2 (same layout) | AUR-1 | |
| $80130–$8013F | Voice 3 (same layout) | AUR-1 | |
| $80140 | AMVOL | AUR-1 | |
| $80141 | AMVOLL | AUR-1 | |
| $80142 | AMVOLR | AUR-1 | |
| $80143 | AMVOICE | AUR-1 | |
| $80144 | AMFILT | AUR-1 | dup of VCTRL bit (E10) |
| $80145 | AFCUTLO | AUR-1 | bits 3:0 |
| $80146 | AFCUTHI | AUR-1 | bits 11:4 |
| $80147 | AFRESON | AUR-1 | |
| $80148 | AFMODE | AUR-1 | |
| $80149 | ASRATE | AUR-1 | unplanned (P4) |
| $8014A | AIRQEN | AUR-1 | |
| $8014B | ASTAT | AUR-1 | w1c |
| $8014C–$801FF | — | AUR-1 | reserved |
| $80200 | VMODE | VIC-256 | |
| $80201 | VPALETTE | VIC-256 | 5bpp value: see G9 |
| $80202 | VRESX | VIC-256 | encoding undefined (G7) |
| $80203 | VRESY | VIC-256 | encoding undefined (G7) |
| $80204 | VBGCOL | VIC-256 | |
| $80205 | VTILESIZE | VIC-256 | |
| $80206 | VBUFLO | VIC-256 | width insufficient (G8) |
| $80207 | VBUFHI | VIC-256 | width insufficient (G8) |
| $80208 | VBUF2LO | VIC-256 | width insufficient (G8) |
| $80209 | VBUF2HI | VIC-256 | width insufficient (G8) |
| $8020A | VSWAP | VIC-256 | auto-clear |
| $8020B | VPALBASE_LO | VIC-256 | width insufficient (G8) |
| $8020C | VPALBASE_HI | VIC-256 | width insufficient (G8) |
| $8020D | VSATBASE_LO | VIC-256 | width insufficient (G8) |
| $8020E | VSATBASE_HI | VIC-256 | width insufficient (G8) |
| $8020F | VTMAPBASE_LO | VIC-256 | width insufficient (G8) |
| $80210 | VTMAPBASE_HI | VIC-256 | width insufficient (G8) |
| $80211 | VSCROLLX | VIC-256 | |
| $80212 | VSCROLLY | VIC-256 | |
| $80213 | VSPRENA | VIC-256 | unplanned (P4) |
| $80214 | VSCANLO | VIC-256 | |
| $80215 | VSCANHI | VIC-256 | |
| $80216 | VIRQEN | VIC-256 | |
| $80217 | VSTAT | VIC-256 | collision semantics (E12) |
| $80218–$802FF | — | VIC-256 | reserved |
| $80300–$80FFF | — | — | reserved, ~3.5 KB |

---

*Audit performed against: flommodore-master-specification.md, flommodore-phase1 … phase8, flommodore-implementation-plan.md — all read in full. Where the master and a phase document conflict, the recommendation states which version is more internally consistent rather than assuming either wins.*
