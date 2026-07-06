# Flommodore Documentation Audit & Implementation Plan Review

You are performing a pre-implementation design review of the Flommodore fantasy computer project. The full specification is in the project documents:

- `flommodore-master-specification.md` — consolidated spec, all 8 phases
- `flommodore-phase1-memory-map.md` through `flommodore-phase8-toolchain.md` — per-phase detail documents
- `flommodore-implementation-plan.md` — block-by-block implementation plan

Implementation will be in Zig 0.16 with SDL3 (treat any mention of Zig 0.14 in the docs as Zig 0.16). No code has been written yet, so this is the last cheap moment to catch design errors — be rigorous and skeptical, not polite.

## Objective

Produce a single audit report with three sections: **(A) Errors**, **(B) Gaps**, **(C) Implementation Plan Improvements**. Every finding must cite the document and section where it occurs, quote or describe the conflicting/missing text, and explain the concrete consequence for the emulator or toolchain if left unfixed.

## Methodology — perform these passes in order

### Pass 1 — Internal consistency of the master spec
Cross-check every numeric fact that appears in more than one place. Specifically verify:
- **Memory map**: every address range mentioned anywhere (RAM, VRAM, I/O region, open bus, ROM, shadow region) agrees with the Phase 1 map. Check that ranges are contiguous, non-overlapping, and that stated sizes match their address spans (e.g., does $80000–$80FFF actually equal the stated I/O size?).
- **CPU**: instruction format bit fields must sum to 32 in all three formats (R, I, J). Check that field widths claimed in one section (e.g., IMM18, ADDR26, register fields of 4 bits) are consistent everywhere they appear, and that 4-bit register fields match the stated register file size. Verify the opcode count claimed matches the opcodes actually listed. Verify a 20-bit address bus is consistent with how JMP/CALL absolute targets, the IVT, vectors, and PC width are described.
- **Video**: VRAM size vs. display mode requirements (resolution × bpp for each of the 4 modes must fit), sprite count vs. sprite attribute table size, register map addresses vs. the I/O region boundaries.
- **Audio**: voice count, register layout per voice, sample rate, and mixing math — do the per-voice register blocks fit in their allocated address range without overlap?
- **I/O**: every register address in Phase 5 must fall inside the I/O region and must not collide with VIC-256 or AUR-1 registers. Build a complete sorted register address table as part of this pass and flag any collision or unexplained hole.
- **ROM/Boot**: BIOS jump table addresses, vector locations, syscall numbers (the spec claims 29 system calls — count them), reset behavior, and the ROM shadow mechanism must agree between Phase 1, Phase 6, and the implementation plan.
- **Toolchain**: file format magic numbers ($464F, $4642), autoboot header layout, relocation types — must agree between Phase 8, the linker tasks in the plan, and any example shown.

### Pass 2 — Master spec vs. phase documents
The master spec claims to consolidate the phase docs. Diff them: report any fact present in a phase doc but missing or altered in the master, and vice versa. Where they disagree, state which version is more internally consistent and recommend which should win.

### Pass 3 — Semantic completeness (gaps)
For each subsystem, ask: could an engineer implement this with zero additional decisions? Flag every place where the answer is no. Areas notorious for underspecification — check each explicitly:
- Unaligned 16-bit memory access behavior; reads/writes straddling region boundaries; writes to ROM; reads/writes to open bus (read is specified as $0000 — is write specified?)
- Flag semantics for every ALU op: which of Z/N/C/V each instruction updates, carry/overflow definition for SUB and CMP, behavior of DIV and MOD by zero, MUL overflow behavior, shift-by-zero and shift-amount > 15 behavior
- Interrupt edge cases: IRQ during HLT, nested interrupts, SEI/CLI timing, what happens if an IRQ fires while S=1, the exact stack layout pushed on entry and popped by RTI, USP/SSP switching rules
- Exact per-instruction cycle counts (needed for timer/raster accuracy) — are they specified at all?
- VIC-256: raster interrupt timing, sprite priority/collision rules, what happens when CPU writes VRAM mid-scanline, palette format
- AUR-1: ADSR rate units, FM algorithm definition, wavetable format, output clipping/mixing rule
- Endianness: stated once or assumed? Consistent across instruction fetch, data access, and file formats?
- File formats: are `.flobj` and `.flapp` specified field-by-field with offsets and sizes, or just described prose-level?
- Test ROM result convention: is the $00010 PASS/FAIL convention compatible with the memory map (is $00010 ordinary RAM)?

### Pass 4 — Implementation plan review
Evaluate the plan against the spec and against good engineering practice:
1. **Coverage**: map every spec feature to a plan task. List spec features with no corresponding task, and plan tasks referencing things not in the spec.
2. **Dependency order**: validate the dependency graph. In particular, scrutinize the claim that Block 10 (assembler) depends only on Block 2 — and how test ROMs for Block 3 (CPU) are supposed to be produced *before* the assembler exists in Milestone 4. If there's a chicken-and-egg problem in the testing strategy, propose a fix (e.g., hand-assembled ROMs, a minimal bootstrap assembler task, or reordering).
3. **Task granularity and "done when" criteria**: flag tasks whose completion criteria are untestable or circular.
4. **Risk ordering**: identify the riskiest unknowns (e.g., SDL3 audio callback timing, cycle-accurate raster IRQs) and whether the plan surfaces them early enough.
5. **Zig 0.16 / SDL3 specifics**: flag any plan or spec assumption that is stale for Zig 0.16 (build system APIs, package management in `build.zig.zon`) or SDL3 (callback model, audio stream API). Where you are unsure of current Zig 0.16 or SDL3 API details, say so explicitly rather than guessing.
6. **Missing infrastructure tasks**: CI, golden-image/regression testing for video, audio output verification strategy, fuzzing the decoder, determinism/headless mode — recommend additions where justified.

## Output format

```
# Flommodore Design Audit — <date>

## Summary
<5–10 lines: overall health, count of findings by severity, top 3 issues>

## A. Errors (spec says two incompatible things, or a stated fact is internally impossible)
For each: ID (E1, E2…), Severity (Blocker / Major / Minor), Location(s), Description, Evidence, Consequence, Recommended fix

## B. Gaps (spec is silent or ambiguous on something implementation requires)
Same structure, IDs G1, G2…

## C. Implementation Plan Improvements
Same structure, IDs P1, P2…, plus a proposed revised task list ONLY for blocks where you recommend changes

## D. Register Address Map (appendix)
The complete sorted I/O register table you built in Pass 1, with collisions/holes annotated
```

## Rules

- Cite document + section for every finding. Never report an issue without evidence.
- Distinguish clearly between "the spec is wrong" (error) and "the spec doesn't say" (gap). Do not pad the report: if a subsystem is clean, say so in one line.
- Do not invent spec details to fill gaps — recommend a decision, mark it as a recommendation, and note alternatives where the choice is non-obvious.
- Where the master spec and a phase doc conflict, neither automatically wins; argue from internal consistency.
- Severity definitions: **Blocker** = implementation cannot proceed correctly; **Major** = will cause rework or incompatibility later; **Minor** = cosmetic, documentation-only.
- If the full audit exceeds a single response, complete passes 1–2 fully first and say where you stopped, rather than doing all passes shallowly.
