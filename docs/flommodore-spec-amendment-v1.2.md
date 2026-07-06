# Flommodore — Block 3 Specification Amendments (v1.2)

**Status: LOCKED — supersedes the listed sections of the v1.1 documents upon acceptance.
Amendment v1.1 (Block 0) remains LOCKED and in force except where explicitly amended here.**

This document is the output of the Block 2–3 reference implementation (memory subsystem,
encoder, Gab-16 CPU core). Every decision below covers a point where the v1.1 spec was
silent, ambiguous, or — in two cases (D44, D45) — where the silence concealed a defect.
Each section contains normative replacement text; §4 maps every decision to the
implementation finding that raised it. Where this document and a v1.1 or v1.0 document
disagree, this document wins.

---

## 0. Decision Register (continued from v1.1)

| # | Decision | Outcome |
|---|---|---|
| D36 | Trap/interrupt resume PC | Pushed PC = address of the **following** instruction |
| D37 | Shift semantics | SHL/SHR on the full 20-bit value; ASR on the 16-bit signed domain, zero-extended; carry from the 16-bit view; amount = RB **value** bits 3:0; "SHR by 16" prose corrected |
| D38 | DIV/MOD signedness | **Unsigned**, full 20-bit operands |
| D39 | CYC width | CYC is architecturally **20-bit** (wraps every 2²⁰ cycles ≈ 72.8 ms); §2.1's "32-bit" deleted |
| D40 | Reserved sregs 6–15 | MFSR reads `$00000`; MTSR is ignored — no trap |
| D41 | Cycle accounting | Interrupt/trap **delivery costs 1 cycle**; a halted CPU costs 1 cycle per idle step; CYC counts every cycle |
| D42 | MTSR privilege violation | Traps to BRK; the write does **not** take effect |
| D43 | Unused encoding fields | Unused register fields and LUI's IMM18 bits 17:4 are **ignored**, never validated |
| D44 | RTI privilege | RTI is **supervisor-only**; user-mode RTI traps to BRK (closes an escalation hole) |
| D45 | SEI/CLI/HLT privilege | SEI/CLI are **silently ignored in user mode** (consistent with §1.4); HLT is unprivileged |
| D46 | Entering user mode | Canonical transition is the **RTI-frame method**; supervisor `MTSR FLAGS` clearing S is defined but performs **no stack switch** |
| D47 | I/O byte writes & region straddles | SB to I/O is a **read-modify-write of the low byte**; the per-byte routing rule applies **only** to region-straddling accesses |

---

## 1. Gab-16 CPU — Corrections (supersedes Phase 2 §2.4/§2.6 excerpts and amendment v1.1 §1.4–§1.6 excerpts)

### 1.1 Trap and interrupt resume point (D36 — new)

For **every** vectored entry — IRQ delivery, NMI, BRK, illegal instruction (unassigned
opcode or nonzero reserved FUNC/FLAGS fields), and privilege violation — the PC value
pushed in the 8-byte frame is the address of the instruction **following** the point of
entry:

- For an interrupt delivered between instructions, this is the next instruction that
  would have executed — RTI resumes exactly where the program left off.
- For a trap raised *by* an instruction (illegal word, privilege violation), PC has
  already advanced past the fetch, so RTI resumes **after** the trapping instruction.
  The trapping instruction is *not* re-executed. A debugger or emulation trap handler
  that wants to retry or inspect the faulting word must subtract 4 from the PC slot of
  the frame (`[SP+4]`).

Rationale: one uniform rule; the resume-after model makes the BRK vector directly usable
as a "skip and continue" software breakpoint, and a cleared-RAM runaway (D35) makes
forward progress through the handler instead of re-faulting on the same word.

### 1.2 Shift instructions (D37 — replaces the Phase 2 §2.4 shift rows and the §1.1 "SHR by 16" prose)

Shift amount is **bits 3:0 of the RB register's value** (0–15). Bits 4+ of RB are
ignored: a shift by 17 is a shift by 1.

| Op | Domain | Result | Carry (n > 0) | Carry (n = 0) |
|---|---|---|---|---|
| `SHL` | full 20-bit value | `(RA << n) & $FFFFF` | last bit shifted out of **bit 15** — bit `16−n` of RA | 0 |
| `SHR` | full 20-bit value | `RA >> n` (logical) | last bit shifted out — bit `n−1` of RA | 0 |
| `ASR` | **low 16 bits, signed** | `sext16(RA[15:0]) >> n`, **zero-extended** into the register (bits 19:16 = 0) | bit `n−1` of RA[15:0] | 0 |

Z and N derive from the low 16 bits of the result as always (§1.6); V is cleared.

- SHL and SHR operate on the full 20-bit register value so that pointer bits 19:16
  participate — `SHL` can build addresses and `SHR` can expose the high nibble.
- ASR is a **16-bit signed data operation** ("sign from bit 15", Phase 2 §2.4): the sign
  replicated is bit 15, and the 16-bit result is written with bits 19:16 clear.
- Carry always reflects the 16-bit programming model, matching the rule that FLAGS
  derive from the low 16 bits.

**Prose correction:** §1.1's pointer-comparison example "SHR by 16 and CMP again" is
unencodable in one instruction (shift amounts cap at 15). The technique is two
instructions; the canonical idiom, used by the reference test ROMs, is:

```asm
; R2 = bits 19:16 of pointer R1
LI  R12, 8
SHR R2, R1, R12
SHR R2, R2, R12
```

### 1.3 DIV and MOD (D38 — clarifies Phase 2 §2.4)

`DIV` and `MOD` are **unsigned**, computed on the full 20-bit register values. The
divide-by-zero rule is unchanged (v1.1 §1.6): `RD ← $FFFF`, `V ← 1`, `C ← 0`, Z/N from
the `$FFFF` result (Z=0, N=1), no trap. Signed division is a software sequence.

### 1.4 CYC is 20 bits (D39 — replaces the CYC rows of Phase 2 §2.1 and amendment v1.1 §1.4; re-answers audit G20)

The v1.1 register model masks **every** register write to `$FFFFF` with no exceptions
(the normative `set_reg` in §1.1). A "32-bit" CYC would be invisible above bit 19 the
moment `MFSR` transfers it. The counter is therefore defined as what software can
actually observe:

- `CYC` is a **20-bit** read-only cycle counter. It wraps every 2²⁰ cycles —
  **≈ 72.8 ms at 14.4 MHz** — and the wrap is defined behaviour.
- `MFSR RD, CYC` writes the counter through the standard register path.
- Interval measurement uses modular 20-bit subtraction and is exact for intervals under
  72 ms; longer measurements should use a hardware timer (Phase 5 §5.2), which is what
  they are for.
- Emulators may keep a wider counter internally for debugger displays; only the low
  20 bits are architectural.

(Alternative considered and rejected for v1: a `CYCH` special register exposing high
bits. It spends a reserved sreg on a need the timers already serve.)

### 1.5 Reserved special registers (D40 — completes amendment v1.1 §1.4)

`MFSR` of a reserved sreg number (6–15) returns `$00000`. `MTSR` to one is silently
ignored in any mode. Neither traps — the same convention as writes to `CYC`. (Future
sregs will therefore read as benign zeros on v1 CPUs.)

### 1.6 Cycle accounting (D41 — completes D17)

D17's "1 cycle per instruction, uniform" is extended to every kind of step, so total
machine time is exactly the step count:

- Executing any instruction: **1 cycle** (unchanged).
- **Delivering** an interrupt or trap (the full entry sequence: stack switch, 8-byte
  frame push, vector load): **1 cycle**. The handler's first instruction executes in the
  following cycle.
- A **halted** CPU consumes **1 cycle per step** doing nothing. Timers and video keep
  advancing (they count cycles, not instructions).
- `CYC` increments on every cycle of every kind.

Consequence for the main loop (plan Block 5): a frame is exactly 240,000 steps
regardless of the mix of instructions, traps, and halted time.

### 1.7 Privilege model — completed (D42, D44, D45, D46; supersedes amendment v1.1 §1.4–§1.5 excerpts)

The complete privilege matrix. "Trap" means the BRK-vector entry of §1.1 (D36 resume
rule applies; a trapped write never takes effect).

| Operation | Supervisor (S=1) | User (S=0) |
|---|---|---|
| `MTSR IVT / SSP / SYS` | performs the write | **trap**, write discarded (D42) |
| `MTSR USP` | write | write |
| `MTSR FLAGS` | writes all defined bits (may clear S — see below) | writes Z/N/C/V only; **I and S bits are ignored** (v1.1 §1.4) |
| `MTSR CYC` / reserved sreg | ignored | ignored |
| `MFSR` (any sreg) | read | read |
| `RTI` | executes | **trap** (D44) |
| `SEI` / `CLI` | sets/clears I | **silently ignored** (D45) |
| `HLT` | halts | halts (unprivileged; D45) |
| All other instructions | execute | execute |

**D44 rationale (defect fix):** user code controls its own stack contents. If RTI
executed in user mode, a program could push a crafted FLAGS image with S=1 and RTI into
supervisor mode — a straight privilege escalation. RTI is therefore supervisor-only,
matching its sole architectural purpose (unwinding a vectored entry, which always runs
with S=1).

**D45 rationale:** §1.4 already forbids user code from touching FLAGS.I via MTSR; SEI
and CLI must not be a side door. They are *ignored* rather than trapped to match the
established FLAGS-write convention (silent bit-masking, not a fault). HLT stays
unprivileged: a user program that halts with interrupts enabled is woken by the next
delivered IRQ exactly like supervisor code, and one that could not HLT would spin-wait
instead — no protection is gained by restricting it.

**D46 — entering user mode.** The canonical transition is the **RTI-frame method**,
performed in supervisor mode:

```asm
; prerequisites: SSP set (MTSR), USP set to the user stack (MTSR)
LI   R15, <supervisor stack top>   ; build the frame on the supervisor stack
LOAD_ADDR R3, user_entry
PUSH R3                            ; frame: resume PC
LI   R4, $10                       ; frame: FLAGS with S=0, I=1
PUSH R4
RTI                                ; pops FLAGS/PC; S=0 → SSP←SP, SP←USP
```

A supervisor `MTSR FLAGS` that clears S also drops to user mode and is defined, but it
performs **no stack switch**: SP, USP, and SSP are all left as they are, so SP still
points at the supervisor stack. It is a sharp edge, permitted for kernels that manage
stacks manually; the RTI-frame method is the documented default.

### 1.8 Unused encoding fields (D43 — completes D32)

D32's reserved-zero validation applies to **exactly** the R-format FUNC[13:5] and
FLAGS[4:0] fields — nonzero values there trap as illegal instructions. Every other
unused bit is **ignored, never validated**:

- Register fields not used by an instruction (CMP's RD; NOT's RB; JMP/CALL's RD and RB;
  PUSH's RD and RB; POP's RA and RB; MFSR's RB; MTSR's RB; all three in
  NOP/HLT/RTI/SEI/CLI/RET/PUSHA/POPA) — any value executes identically.
- `LUI` reads only IMM18 bits 3:0; bits 17:4 are ignored.
- In J format, bits 25:0 are ADDR26 payload; no register fields exist.

Assemblers **must emit zeros** in ignored fields (the reference encoder does); the
freedom is granted to the CPU, not to code generators. Rationale: keeping validation
confined to one contiguous field (D32) keeps decode simple and the fuzz surface small,
while the emit-zeros rule preserves the option of assigning those bits meaning later.

---

## 2. Bus & I/O — Clarifications (D47 — completes amendment v1.1 §1.7/§3.1; supersedes nothing)

The two v1.1 rules — per-byte routing (§1.7) and the 16-bit-register-per-address I/O
model (D14/§3.1) — compose as follows. This section makes the composition normative.

1. **Wholly inside the I/O region** (`$80000–$80FFF`): a 16-bit access is a single
   operation on the register at the **exact** address (D14). Adjacent addresses never
   combine.
2. **Straddling any region edge** (RAM/I-O at `$7FFFF`, I-O/open-bus at `$80FFF`,
   open-bus/ROM at `$FBFFF`, ROM/RAM across the `$FFFFF→$00000` wrap): the access is
   routed **per byte** (§1.7). A byte that lands in I/O follows the byte rules below.
3. **Byte reads from I/O** return the register's **low byte**.
4. **Byte writes to I/O** are a **read-modify-write**: the register's low byte is
   replaced, its high byte preserved. (For registers with side effects on read —
   KDATA — the side effect is that of the register's own definition; KDATA dequeues on
   any access width, v1.1 §3.1.)
5. Register bits that are architecturally undefined read as zero and ignore writes;
   e.g. `SYSCFG` has exactly one defined bit (bit 0), so `SYSCFG ← $FFFF` reads back
   `$0001`.

---

## 3. Test infrastructure conventions (informative, not machine-architectural)

Recorded so tooling stays consistent across blocks:

- **Test-ROM result protocol:** a generated test ROM writes a 16-bit result to
  `$00080` — `$600D` = pass, `$0BAD` = fail — with the failing check number at
  `$00084`, then executes HLT. The harness's `--expect-pass` flag enforces halt +
  `$600D`.
- **Harness IRQ injection:** `--irq-at N` (repeatable, strictly ascending) asserts the
  CPU IRQ line once cycle N is reached and holds it **until delivered**
  (assert-until-delivered). Deterministic without being brittle against code-length
  changes; delivery order is the argument order.
- Register conventions inside test ROMs: R11 = current check number, R12 = scratch.

---

## 4. Mapping: decision → origin

| # | Raised by |
|---|---|
| D36 | cpu.zig: trap entry needed a defined pushed-PC; spec gave the frame layout but not the value for traps |
| D37 | Two findings: the flag table's "last bit shifted out" had no domain, and §1.1's "SHR by 16" example is unencodable under the RB[3:0] amount rule |
| D38 | Phase 2 §2.4 says "integer quotient" with no signedness |
| D39 | Contradiction: v1.1 §1.1 masks every register write to 20 bits, while §1.4/G20 described CYC as a 32-bit readable counter — the high 12 bits were unobservable |
| D40 | §1.4 lists sregs 6–15 as "reserved" with no access behaviour |
| D41 | D17 priced instructions only; delivery and halted time had no defined cost, making frame timing (E21/G16) underdetermined |
| D42 | §1.4 marks writes "supervisor-only" without saying what a violation does |
| D43 | Decode validation scope: D32 covers FUNC/FLAGS, silent on other unused fields and LUI's high immediate bits |
| D44 | **Defect:** user-mode RTI + user-controlled stack = privilege escalation to S=1 |
| D45 | **Defect adjacent:** SEI/CLI had no privilege, bypassing §1.4's user-mode I-bit protection |
| D46 | No documented way to enter user mode; the MTSR-FLAGS path silently skips the stack switch |
| D47 | Block 2: §1.7 (per-byte routing) and D14 (exact-register I/O) conflict for 16-bit accesses inside I/O unless composition is defined; SB-to-I/O high-byte fate was unspecified |

---

*Flommodore Fantasy Computer — Design Document*
*Block 3 Specification Amendments — Status: LOCKED (v1.2)*
