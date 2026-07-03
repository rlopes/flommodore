//! Flommodore — `cpu.zig` (Block 3).
//!
//! Gab-16 CPU core: fetch / decode / execute, flags, interrupts, per the
//! LOCKED v1.1 amendment §1.1–§1.7 (which supersedes Phase 2 where they
//! disagree). One instruction per cycle, uniform (D17).
//!
//! Points where the v1.1 spec was silent are now LOCKED by the v1.2
//! amendment (docs/flommodore-spec-amendment-v1_2.md), cited as D36-D47 at
//! their use sites: trap resume PC (D36), shift domains (D37), unsigned
//! DIV/MOD (D38), 20-bit CYC (D39), reserved sregs (D40), cycle accounting
//! (D41), MTSR violation semantics (D42), ignored encoding fields (D43),
//! supervisor-only RTI (D44), user-mode SEI/CLI ignored (D45), user-mode
//! entry (D46).

const std = @import("std");
const util = @import("util");
const bus_mod = @import("bus");
const encode = @import("encode");

const Bus = bus_mod.Bus;
const Opcode = encode.Opcode;

// FLAGS bits (Phase 2 §2.2).
pub const flag_z: u16 = 1 << 0;
pub const flag_n: u16 = 1 << 1;
pub const flag_c: u16 = 1 << 2;
pub const flag_v: u16 = 1 << 3;
pub const flag_i: u16 = 1 << 4;
pub const flag_s: u16 = 1 << 5;
/// Bits 6–15 are reserved and read as zero (§2.2).
pub const flags_defined_mask: u16 = 0x003F;

/// System vector / IVT indices (amendment §1.5).
pub const vec_reset: u4 = 0;
pub const vec_nmi: u4 = 1;
pub const vec_irq: u4 = 2;
pub const vec_brk: u4 = 3;

/// Hardware RESET vector location: system vector 0 at the top of ROM
/// (amendment §2.1). PC is loaded from here at power-on (Phase 2 §2.7);
/// the IVT *register* is set later by boot code.
pub const reset_vector_addr: u32 = 0xFFFC0;

/// What a `step` did — lets the harness/debugger react deterministically.
pub const Event = enum {
    /// Executed one instruction normally.
    executed,
    /// Halted; consumed one idle cycle.
    halted_idle,
    /// Delivered a maskable IRQ (entered the vector-2 handler).
    irq_entered,
    /// Trapped to the BRK vector (illegal instruction / privilege violation).
    trapped,
};

pub const Gab16 = struct {
    /// R0–R15. R0 is hardwired to zero: reads return 0, writes are
    /// discarded (`setReg`). R13=FP (convention), R14=LR, R15=SP (hardware).
    r: [16]u32,
    pc: u32,
    flags: u16,
    ivt: u32,
    usp: u32,
    ssp: u32,
    sys: u16,
    /// Cycle counter — architecturally 20 bits (D39): MFSR passes it
    /// through the masked register write, so software sees a counter that
    /// wraps every 2^20 cycles (~72.8 ms). Kept wider here for the
    /// debugger. Increments once per step of every kind (D17/D41).
    cyc: u32,
    halted: bool,
    /// Level-sensitive IRQ line, driven by the IRQ controller (Block 4) or
    /// the harness. The CPU never clears it — the source does.
    irq_line: bool,

    pub const sp = 15; // stack pointer register index
    pub const lr = 14; // link register index

    /// Power-on / reset (Phase 2 §2.7 steps 1–2): supervisor mode,
    /// interrupts disabled, PC from the 4-byte RESET vector at $FFFC0.
    /// SP/SSP/IVT are *not* set by hardware — boot code does that.
    pub fn reset(cpu: *Gab16, bus: *Bus) void {
        cpu.* = .{
            .r = @splat(0),
            .pc = util.maskAddr(read32(bus, reset_vector_addr)),
            .flags = flag_s, // S=1, I=0, condition flags clear
            .ivt = 0,
            .usp = 0,
            .ssp = 0,
            .sys = 0,
            .cyc = 0,
            .halted = false,
            .irq_line = false,
        };
    }

    // ------------------------------------------------------------------
    // Register file (task 3.4) — the amendment §1.1 normative model:
    // every write masked to $FFFFF; R0 writes discarded.
    // ------------------------------------------------------------------

    pub fn getReg(cpu: *const Gab16, reg: u4) u32 {
        return cpu.r[reg]; // r[0] is kept 0 by setReg
    }

    pub fn setReg(cpu: *Gab16, reg: u4, val: u32) void {
        if (reg != 0) cpu.r[reg] = val & util.addr_mask;
    }

    // ------------------------------------------------------------------
    // One step: deliver a pending interrupt, or idle if halted, or
    // fetch/decode/execute one instruction. Always costs one cycle (D17).
    // ------------------------------------------------------------------

    pub fn step(cpu: *Gab16, bus: *Bus) Event {
        cpu.cyc +%= 1;

        // Interrupt delivery — before fetch, and the only thing that wakes
        // HLT ("wakes only on a *delivered* interrupt", §1.5).
        if (cpu.irq_line and (cpu.flags & flag_i) != 0) {
            cpu.halted = false;
            cpu.enterVector(bus, vec_irq);
            return .irq_entered; // delivery consumes the cycle (D41)
        }
        if (cpu.halted) return .halted_idle;

        // Fetch: two 16-bit bus reads, little-endian (§1.7); PC advances by
        // 4 with 20-bit wrap before execution, so PC now names the *next*
        // instruction (the branch/CALL/trap base).
        const word = fetch(cpu, bus);

        const d = decode(word) catch {
            // Illegal instruction (unassigned opcode, or nonzero reserved
            // FUNC/FLAGS fields, D32/D35) → BRK vector.
            cpu.enterVector(bus, vec_brk); // pushed PC = next instruction (D36)
            return .trapped;
        };
        return cpu.execute(bus, d);
    }

    fn fetch(cpu: *Gab16, bus: *Bus) u32 {
        const lo: u32 = bus.read16(cpu.pc);
        const hi: u32 = bus.read16(cpu.pc +% 2);
        cpu.pc = util.maskAddr(cpu.pc +% 4);
        return lo | (hi << 16);
    }

    // ------------------------------------------------------------------
    // Interrupt / trap entry and RTI (amendment §1.5, tasks 3.14–3.16).
    // ------------------------------------------------------------------

    /// Hardware entry sequence: stack switch (only from user mode), push PC
    /// (4 B) then FLAGS (4 B, upper 16 zero) — 8-byte frame — set S,
    /// clear I, load PC from the 4-byte IVT entry.
    fn enterVector(cpu: *Gab16, bus: *Bus, index: u4) void {
        if ((cpu.flags & flag_s) == 0) {
            cpu.usp = cpu.getReg(sp);
            cpu.setReg(sp, cpu.ssp);
        } // nested entry (S=1): stack switch and USP save are skipped
        cpu.push32(bus, cpu.pc);
        cpu.push32(bus, cpu.flags);
        cpu.flags |= flag_s;
        cpu.flags &= ~flag_i;
        cpu.pc = util.maskAddr(read32(bus, cpu.ivt +% (4 * @as(u32, index))));
    }

    fn execRti(cpu: *Gab16, bus: *Bus) void {
        cpu.flags = @truncate(cpu.pop32(bus) & flags_defined_mask); // low 16 taken, reserved bits zero
        cpu.pc = util.maskAddr(cpu.pop32(bus));
        if ((cpu.flags & flag_s) == 0) {
            cpu.ssp = cpu.getReg(sp);
            cpu.setReg(sp, cpu.usp);
        }
    }

    // ------------------------------------------------------------------
    // Stack helpers — 4-byte slots (D34), composed of routed 16-bit
    // accesses like every other multi-byte operation.
    // ------------------------------------------------------------------

    fn push32(cpu: *Gab16, bus: *Bus, value: u32) void {
        const new_sp = util.maskAddr(cpu.getReg(sp) -% 4);
        cpu.setReg(sp, new_sp);
        write32(bus, new_sp, value);
    }

    fn pop32(cpu: *Gab16, bus: *Bus) u32 {
        const old_sp = cpu.getReg(sp);
        const value = read32(bus, old_sp);
        cpu.setReg(sp, util.maskAddr(old_sp +% 4));
        return value;
    }

    // ------------------------------------------------------------------
    // Execute (tasks 3.5–3.13).
    // ------------------------------------------------------------------

    fn execute(cpu: *Gab16, bus: *Bus, d: Decoded) Event {
        switch (d.op) {
            // ---- Load / store (task 3.5) ----
            .lw => cpu.setReg(d.rd, bus.read16(util.maskAddr(cpu.getReg(d.ra) +% d.imm))),
            .lb => cpu.setReg(d.rd, bus.read8(util.maskAddr(cpu.getReg(d.ra) +% d.imm))),
            // SW/SB carry the source register in the RD field (§1.3).
            .sw => bus.write16(util.maskAddr(cpu.getReg(d.ra) +% d.imm), @truncate(cpu.getReg(d.rd))),
            .sb => bus.write8(util.maskAddr(cpu.getReg(d.ra) +% d.imm), @truncate(cpu.getReg(d.rd))),
            // LI: sign-extend 18 → 20 and mask (§1.2).
            .li => cpu.setReg(d.rd, d.imm), // setReg masks to $FFFFF
            // LUI: bits 19:16 ← IMM & $F, low 16 preserved (§1.2).
            .lui => cpu.setReg(d.rd, (cpu.getReg(d.rd) & 0x0FFFF) | ((d.imm & 0xF) << 16)),

            // ---- ALU register-register (tasks 3.6–3.7) ----
            .add => cpu.aluAdd(d.rd, cpu.getReg(d.ra), cpu.getReg(d.rb)),
            .sub => cpu.aluSub(d.rd, cpu.getReg(d.ra), cpu.getReg(d.rb), true),
            .@"and" => cpu.aluLogic(d.rd, cpu.getReg(d.ra) & cpu.getReg(d.rb)),
            .@"or" => cpu.aluLogic(d.rd, cpu.getReg(d.ra) | cpu.getReg(d.rb)),
            .xor => cpu.aluLogic(d.rd, cpu.getReg(d.ra) ^ cpu.getReg(d.rb)),
            .not => cpu.aluLogic(d.rd, ~cpu.getReg(d.ra)),
            .shl => cpu.aluShl(d.rd, cpu.getReg(d.ra), shiftAmount(cpu.getReg(d.rb))),
            .shr => cpu.aluShr(d.rd, cpu.getReg(d.ra), shiftAmount(cpu.getReg(d.rb))),
            .asr => cpu.aluAsr(d.rd, cpu.getReg(d.ra), shiftAmount(cpu.getReg(d.rb))),
            .mul => cpu.aluMul(d.rd, cpu.getReg(d.ra), cpu.getReg(d.rb)),
            .div => cpu.aluDivMod(d.rd, cpu.getReg(d.ra), cpu.getReg(d.rb), .quotient),
            .mod => cpu.aluDivMod(d.rd, cpu.getReg(d.ra), cpu.getReg(d.rb), .remainder),
            .cmp => cpu.aluSub(0, cpu.getReg(d.ra), cpu.getReg(d.rb), false),

            // ---- ALU immediate (task 3.8) ----
            .addi => cpu.aluAdd(d.rd, cpu.getReg(d.ra), d.imm),
            .subi => cpu.aluSub(d.rd, cpu.getReg(d.ra), d.imm, true),
            .andi => cpu.aluLogic(d.rd, cpu.getReg(d.ra) & d.imm),
            .ori => cpu.aluLogic(d.rd, cpu.getReg(d.ra) | d.imm),
            .xori => cpu.aluLogic(d.rd, cpu.getReg(d.ra) ^ d.imm),
            .cmpi => cpu.aluSub(0, cpu.getReg(d.ra), d.imm, false),

            // ---- Branches (task 3.9): PC-relative byte offset from the
            // *next* instruction, which is what PC already holds (§1.3) ----
            .beq => cpu.branchIf(d, (cpu.flags & flag_z) != 0),
            .bne => cpu.branchIf(d, (cpu.flags & flag_z) == 0),
            .blt => cpu.branchIf(d, cpu.nBit() != cpu.vBit()),
            .bgt => cpu.branchIf(d, (cpu.flags & flag_z) == 0 and cpu.nBit() == cpu.vBit()),
            .ble => cpu.branchIf(d, (cpu.flags & flag_z) != 0 or cpu.nBit() != cpu.vBit()),
            .bge => cpu.branchIf(d, cpu.nBit() == cpu.vBit()),
            .bcs => cpu.branchIf(d, (cpu.flags & flag_c) != 0),
            .bcc => cpu.branchIf(d, (cpu.flags & flag_c) == 0),

            // ---- Jumps / calls (task 3.10) ----
            .jmp => cpu.pc = cpu.getReg(d.ra), // register values are already masked
            .jmpa => cpu.pc = util.maskAddr(d.addr26),
            .call => {
                cpu.setReg(lr, cpu.pc); // address of the following instruction
                cpu.pc = cpu.getReg(d.ra);
            },
            .calla => {
                cpu.setReg(lr, cpu.pc);
                cpu.pc = util.maskAddr(d.addr26);
            },
            .ret => cpu.pc = cpu.getReg(lr),

            // ---- Stack (task 3.11): 4-byte slots (D34) ----
            .push => cpu.push32(bus, cpu.getReg(d.ra)),
            .pop => cpu.setReg(d.rd, cpu.pop32(bus)),
            .pusha => {
                // Push R1–R12, then LR — 13 slots, 52 bytes (§1.3).
                var reg: u4 = 1;
                while (reg <= 12) : (reg += 1) cpu.push32(bus, cpu.getReg(reg));
                cpu.push32(bus, cpu.getReg(lr));
            },
            .popa => {
                // Pop LR, then R12–R1 (§1.3).
                cpu.setReg(lr, cpu.pop32(bus));
                var reg: u4 = 12;
                while (reg >= 1) : (reg -= 1) cpu.setReg(reg, cpu.pop32(bus));
            },

            // ---- System (task 3.12) ----
            .nop => {},
            .hlt => cpu.halted = true, // unprivileged (D45)
            .rti => {
                // RTI is supervisor-only (D44): user code controls its own
                // stack, so a user-mode RTI would be a privilege escalation.
                if ((cpu.flags & flag_s) == 0) {
                    cpu.enterVector(bus, vec_brk);
                    return .trapped;
                }
                cpu.execRti(bus);
            },
            // SEI/CLI are silently ignored in user mode (D45), consistent
            // with user-mode FLAGS writes ignoring the I bit (§1.4).
            .sei => if ((cpu.flags & flag_s) != 0) {
                cpu.flags |= flag_i;
            },
            .cli => if ((cpu.flags & flag_s) != 0) {
                cpu.flags &= ~flag_i;
            },
            .mfsr => cpu.setReg(d.rd, cpu.readSreg(d.ra)), // n in the RA field (§1.4)
            .mtsr => {
                // n in the RD field (§1.4). Privilege violations trap to BRK.
                if (!cpu.writeSreg(d.rd, cpu.getReg(d.ra))) {
                    cpu.enterVector(bus, vec_brk);
                    return .trapped;
                }
            },
        }
        return .executed;
    }

    fn branchIf(cpu: *Gab16, d: Decoded, taken: bool) void {
        if (taken) cpu.pc = util.maskAddr(cpu.pc +% signExtend26(d.addr26));
    }

    fn nBit(cpu: *const Gab16) u1 {
        return @truncate(cpu.flags >> 1);
    }
    fn vBit(cpu: *const Gab16) u1 {
        return @truncate(cpu.flags >> 3);
    }

    // ------------------------------------------------------------------
    // Special registers (amendment §1.4, task 3.12).
    // ------------------------------------------------------------------

    fn readSreg(cpu: *const Gab16, n: u4) u32 {
        return switch (n) {
            0 => cpu.flags,
            1 => cpu.ivt,
            2 => cpu.usp,
            3 => cpu.ssp,
            4 => cpu.sys,
            // Architecturally 20-bit (D39): masked by the register write.
            5 => cpu.cyc,
            else => 0, // reserved sregs read 0 (D40)
        };
    }

    /// Returns false on a privilege violation (caller traps to BRK).
    fn writeSreg(cpu: *Gab16, n: u4, val: u32) bool {
        const supervisor = (cpu.flags & flag_s) != 0;
        switch (n) {
            0 => {
                var new: u16 = @truncate(val & flags_defined_mask);
                if (!supervisor) {
                    // User-mode FLAGS writes ignore I and S (§1.4) — no
                    // privilege escalation.
                    new = (new & ~(flag_i | flag_s)) | (cpu.flags & (flag_i | flag_s));
                }
                cpu.flags = new;
            },
            1 => {
                if (!supervisor) return false;
                cpu.ivt = val & util.addr_mask;
            },
            2 => cpu.usp = val & util.addr_mask, // read/write in any mode
            3 => {
                if (!supervisor) return false;
                cpu.ssp = val & util.addr_mask;
            },
            4 => {
                if (!supervisor) return false;
                cpu.sys = @truncate(val);
            },
            5 => {}, // CYC writes are ignored (§1.4)
            else => {}, // reserved sreg writes are ignored (D40)
        }
        return true;
    }

    // ------------------------------------------------------------------
    // ALU + flags (amendment §1.6 table, tasks 3.6–3.8).
    // Results compute on full 20-bit register values; FLAGS always derive
    // from the low 16 bits (§1.1).
    // ------------------------------------------------------------------

    fn setZN(cpu: *Gab16, r16: u16) void {
        cpu.flags &= ~(flag_z | flag_n);
        if (r16 == 0) cpu.flags |= flag_z;
        if ((r16 & 0x8000) != 0) cpu.flags |= flag_n;
    }

    fn setC(cpu: *Gab16, c: bool) void {
        if (c) cpu.flags |= flag_c else cpu.flags &= ~flag_c;
    }

    fn setV(cpu: *Gab16, v: bool) void {
        if (v) cpu.flags |= flag_v else cpu.flags &= ~flag_v;
    }

    fn aluAdd(cpu: *Gab16, rd: u4, a: u32, b: u32) void {
        cpu.setReg(rd, a +% b);
        const a16: u16 = @truncate(a);
        const b16: u16 = @truncate(b);
        const wide: u32 = @as(u32, a16) + @as(u32, b16);
        const r16: u16 = @truncate(wide);
        cpu.setZN(r16);
        cpu.setC(wide > 0xFFFF); // carry out of bit 15
        cpu.setV((~(a16 ^ b16) & (a16 ^ r16)) & 0x8000 != 0); // §1.6 add overflow
    }

    /// SUB/SUBI (write=true) and CMP/CMPI (write=false) share flags:
    /// C = no-borrow, ARM style: C=1 iff a ≥ b unsigned (§1.6).
    fn aluSub(cpu: *Gab16, rd: u4, a: u32, b: u32, write: bool) void {
        if (write) cpu.setReg(rd, a -% b);
        const a16: u16 = @truncate(a);
        const b16: u16 = @truncate(b);
        const r16 = a16 -% b16;
        cpu.setZN(r16);
        cpu.setC(a16 >= b16);
        cpu.setV(((a16 ^ b16) & (a16 ^ r16)) & 0x8000 != 0); // §1.6 sub overflow
    }

    /// AND/OR/XOR/NOT and their immediate forms: Z/N set, C and V cleared.
    fn aluLogic(cpu: *Gab16, rd: u4, result: u32) void {
        cpu.setReg(rd, result);
        cpu.setZN(@truncate(result));
        cpu.setC(false);
        cpu.setV(false);
    }

    /// SHL on the full 20-bit value (D37); carry = last bit shifted out of
    /// the 16-bit field (bit 16−n of the original), 0 if shift = 0.
    fn aluShl(cpu: *Gab16, rd: u4, a: u32, n: u4) void {
        const result = (a << n) & util.addr_mask;
        cpu.setReg(rd, result);
        cpu.setZN(@truncate(result));
        const a16: u16 = @truncate(a);
        cpu.setC(n != 0 and (a16 >> @intCast(16 - @as(u5, n))) & 1 != 0);
        cpu.setV(false);
    }

    /// SHR on the full 20-bit value (D37) — pointer bits 19:16 participate;
    /// carry = last bit shifted out (bit n−1 of the original), 0 if
    /// shift = 0.
    fn aluShr(cpu: *Gab16, rd: u4, a: u32, n: u4) void {
        const result = a >> n;
        cpu.setReg(rd, result);
        cpu.setZN(@truncate(result));
        cpu.setC(n != 0 and (a >> (n - 1)) & 1 != 0);
        cpu.setV(false);
    }

    /// ASR on the 16-bit signed domain ("sign from bit 15", D37), result
    /// zero-extended into the register; carry as SHR.
    fn aluAsr(cpu: *Gab16, rd: u4, a: u32, n: u4) void {
        const a16: u16 = @truncate(a);
        const r16: u16 = @bitCast(@as(i16, @bitCast(a16)) >> n);
        cpu.setReg(rd, r16);
        cpu.setZN(r16);
        cpu.setC(n != 0 and (a16 >> (n - 1)) & 1 != 0);
        cpu.setV(false);
    }

    /// MUL: RD ← low 16 bits of the product; C=0, V=0 (§1.6).
    fn aluMul(cpu: *Gab16, rd: u4, a: u32, b: u32) void {
        const r16: u16 = @truncate(a *% b);
        cpu.setReg(rd, r16);
        cpu.setZN(r16);
        cpu.setC(false);
        cpu.setV(false);
    }

    /// Unsigned, full 20-bit operands (D38). Divide by zero: RD ← $FFFF,
    /// V ← 1, no trap — for both DIV and MOD (§1.6).
    fn aluDivMod(cpu: *Gab16, rd: u4, a: u32, b: u32, comptime kind: enum { quotient, remainder }) void {
        if (b == 0) {
            cpu.setReg(rd, 0xFFFF);
            cpu.setZN(0xFFFF);
            cpu.setC(false);
            cpu.setV(true);
            return;
        }
        const result = switch (kind) {
            .quotient => a / b,
            .remainder => a % b,
        };
        cpu.setReg(rd, result);
        cpu.setZN(@truncate(result));
        cpu.setC(false);
        cpu.setV(false);
    }
};

/// Shift amount = RB bits 3:0 (0–15; larger shifts are unencodable, §1.6).
fn shiftAmount(rb_value: u32) u4 {
    return @truncate(rb_value);
}

fn signExtend26(addr26: u32) u32 {
    return util.signExtend(addr26, 26);
}

// ---------------------------------------------------------------------------
// 32-bit bus helpers — composed of routed 16-bit accesses, little-endian,
// like instruction fetch (§1.7). Used for vectors and 4-byte stack slots.
// ---------------------------------------------------------------------------

pub fn read32(bus: *Bus, addr: u32) u32 {
    const lo: u32 = bus.read16(addr);
    const hi: u32 = bus.read16(addr +% 2);
    return lo | (hi << 16);
}

pub fn write32(bus: *Bus, addr: u32, value: u32) void {
    bus.write16(addr, @truncate(value));
    bus.write16(addr +% 2, @truncate(value >> 16));
}

// ---------------------------------------------------------------------------
// Decode (task 3.3).
// ---------------------------------------------------------------------------

pub const Format = enum { r, i, j };

/// Instruction format per opcode (amendment §1.3 table).
pub fn formatOf(op: Opcode) Format {
    return switch (op) {
        .lw, .lb, .sw, .sb, .li, .lui, .addi, .subi, .andi, .ori, .xori, .cmpi => .i,
        .beq, .bne, .blt, .bgt, .ble, .bge, .bcs, .bcc, .jmpa, .calla => .j,
        else => .r,
    };
}

pub const Decoded = struct {
    op: Opcode,
    rd: u4,
    ra: u4,
    rb: u4,
    /// IMM18 sign-extended to 32 bits (as u32 for wrapping arithmetic).
    imm: u32,
    /// Raw 26-bit ADDR26 field (sign-extend for PCREL via `signExtend26`).
    addr26: u32,
};

pub const DecodeError = error{IllegalInstruction};

/// Decode a 32-bit instruction word. Errors on unassigned opcodes (including
/// $00 — D35) and on R-format words with nonzero reserved FUNC/FLAGS fields
/// (D32). Field extraction per Phase 2 §2.3.
pub fn decode(word: u32) DecodeError!Decoded {
    const opbits: u6 = @truncate(util.extractBits(word, 26, 6));
    const op = std.enums.fromInt(Opcode, opbits) orelse return error.IllegalInstruction;
    if (formatOf(op) == .r and util.extractBits(word, 0, 14) != 0) {
        return error.IllegalInstruction; // FUNC[13:5] / FLAGS[4:0] reserved-zero
    }
    return .{
        .op = op,
        .rd = @truncate(util.extractBits(word, 22, 4)),
        .ra = @truncate(util.extractBits(word, 18, 4)),
        .rb = @truncate(util.extractBits(word, 14, 4)),
        .imm = util.signExtend(util.extractBits(word, 0, 18), 18),
        .addr26 = util.extractBits(word, 0, 26),
    };
}

/// Retained for the Block 1 module-liveness check in main.zig.
pub fn init() void {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ram_mod = @import("ram");
const rom_mod = @import("rom");
const io_mod = @import("io");

const Fixture = struct {
    ram: *ram_mod.Ram,
    rom: *rom_mod.Rom,
    io: *io_mod.Io,
    bus: Bus,
    cpu: Gab16,

    /// Machine with RESET vectoring to RAM $01000 (code under test lives in
    /// writable RAM so tests can plant instructions), SP pre-set to $01100.
    fn setup() !Fixture {
        const ram = try testing.allocator.create(ram_mod.Ram);
        errdefer testing.allocator.destroy(ram);
        const rom = try testing.allocator.create(rom_mod.Rom);
        errdefer testing.allocator.destroy(rom);
        const io = try testing.allocator.create(io_mod.Io);
        ram.init();
        rom.init();
        io.* = io_mod.Io.init();
        var f = Fixture{ .ram = ram, .rom = rom, .io = io, .bus = undefined, .cpu = undefined };
        f.bus = Bus.init(ram, rom, io);
        var image: [rom_mod.size]u8 = @splat(0);
        std.mem.writeInt(u32, image[rom_mod.vectors_offset..][0..4], 0x01000, .little);
        try rom.loadFromSlice(&image);
        f.cpu.reset(&f.bus);
        f.cpu.setReg(Gab16.sp, 0x01100); // boot SP (D12)
        return f;
    }

    fn teardown(f: *Fixture) void {
        testing.allocator.destroy(f.ram);
        testing.allocator.destroy(f.rom);
        testing.allocator.destroy(f.io);
    }

    /// Plant a program at $01000 and reposition PC there.
    fn load(f: *Fixture, words: []const u32) void {
        var addr: u32 = 0x01000;
        for (words) |w| {
            write32(&f.bus, addr, w);
            addr += 4;
        }
        f.cpu.pc = 0x01000;
    }

    fn run(f: *Fixture, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) _ = f.cpu.step(&f.bus);
    }
};

test "3.1 reset: supervisor, interrupts off, PC from $FFFC0 vector" {
    var f = try Fixture.setup();
    defer f.teardown();
    var cpu = &f.cpu;
    cpu.reset(&f.bus);
    try testing.expectEqual(@as(u32, 0x01000), cpu.pc);
    try testing.expectEqual(flag_s, cpu.flags); // S=1, I=0, cond flags clear
    try testing.expectEqual(@as(u32, 0), cpu.cyc);
    try testing.expectEqual(@as(u32, 0), cpu.ivt);
    try testing.expect(!cpu.halted);
    for (cpu.r) |reg| try testing.expectEqual(@as(u32, 0), reg);
}

test "3.2 fetch: NOPs advance PC by 4 with 20-bit wrap; CYC counts" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.load(&.{ encode.nop(), encode.nop(), encode.nop() });
    f.run(3);
    try testing.expectEqual(@as(u32, 0x0100C), f.cpu.pc);
    try testing.expectEqual(@as(u32, 3), f.cpu.cyc);
    // Fetch at the top of the address space wraps: NOP = $E0000000 planted
    // across the boundary — low bytes $00,$00 are the ROM's top two bytes
    // (already zero), high bytes land in RAM at $00000/$00001.
    f.bus.write8(0x00000, 0x00);
    f.bus.write8(0x00001, 0xE0);
    f.cpu.pc = 0xFFFFE;
    try testing.expectEqual(Event.executed, f.cpu.step(&f.bus));
    try testing.expectEqual(@as(u32, 0x00002), f.cpu.pc);
}

test "3.3 decode: encode∘decode identity for all 49 opcodes" {
    // One representative word per opcode, produced by the shared encoder.
    const samples = [_]struct { word: u32, op: Opcode, rd: u4 = 0, ra: u4 = 0, rb: u4 = 0 }{
        .{ .word = encode.lw(1, 2, -3), .op = .lw, .rd = 1, .ra = 2 },
        .{ .word = encode.lb(3, 4, 5), .op = .lb, .rd = 3, .ra = 4 },
        .{ .word = encode.sw(6, 7, 5), .op = .sw, .rd = 5, .ra = 6 },
        .{ .word = encode.sb(8, -9, 7), .op = .sb, .rd = 7, .ra = 8 },
        .{ .word = encode.li(9, -131072), .op = .li, .rd = 9 },
        .{ .word = encode.lui(10, 0xF), .op = .lui, .rd = 10 },
        .{ .word = encode.add(1, 2, 3), .op = .add, .rd = 1, .ra = 2, .rb = 3 },
        .{ .word = encode.sub(4, 5, 6), .op = .sub, .rd = 4, .ra = 5, .rb = 6 },
        .{ .word = encode.@"and"(7, 8, 9), .op = .@"and", .rd = 7, .ra = 8, .rb = 9 },
        .{ .word = encode.@"or"(1, 2, 3), .op = .@"or", .rd = 1, .ra = 2, .rb = 3 },
        .{ .word = encode.xor(1, 2, 3), .op = .xor, .rd = 1, .ra = 2, .rb = 3 },
        .{ .word = encode.not(1, 2), .op = .not, .rd = 1, .ra = 2 },
        .{ .word = encode.shl(1, 2, 3), .op = .shl, .rd = 1, .ra = 2, .rb = 3 },
        .{ .word = encode.shr(1, 2, 3), .op = .shr, .rd = 1, .ra = 2, .rb = 3 },
        .{ .word = encode.asr(1, 2, 3), .op = .asr, .rd = 1, .ra = 2, .rb = 3 },
        .{ .word = encode.mul(1, 2, 3), .op = .mul, .rd = 1, .ra = 2, .rb = 3 },
        .{ .word = encode.div(1, 2, 3), .op = .div, .rd = 1, .ra = 2, .rb = 3 },
        .{ .word = encode.mod(1, 2, 3), .op = .mod, .rd = 1, .ra = 2, .rb = 3 },
        .{ .word = encode.cmp(2, 3), .op = .cmp, .ra = 2, .rb = 3 },
        .{ .word = encode.addi(1, 2, 100), .op = .addi, .rd = 1, .ra = 2 },
        .{ .word = encode.subi(1, 2, -100), .op = .subi, .rd = 1, .ra = 2 },
        .{ .word = encode.andi(1, 2, 0xFF), .op = .andi, .rd = 1, .ra = 2 },
        .{ .word = encode.ori(1, 2, 0xFF), .op = .ori, .rd = 1, .ra = 2 },
        .{ .word = encode.xori(1, 2, 0xFF), .op = .xori, .rd = 1, .ra = 2 },
        .{ .word = encode.cmpi(2, 5), .op = .cmpi, .ra = 2 },
        .{ .word = encode.beq(4), .op = .beq },
        .{ .word = encode.bne(-4), .op = .bne },
        .{ .word = encode.blt(8), .op = .blt },
        .{ .word = encode.bgt(8), .op = .bgt },
        .{ .word = encode.ble(8), .op = .ble },
        .{ .word = encode.bge(8), .op = .bge },
        .{ .word = encode.bcs(8), .op = .bcs },
        .{ .word = encode.bcc(8), .op = .bcc },
        .{ .word = encode.jmp(5), .op = .jmp, .ra = 5 },
        .{ .word = encode.jmpa(0xFC000), .op = .jmpa },
        .{ .word = encode.call(6), .op = .call, .ra = 6 },
        .{ .word = encode.calla(0x04100), .op = .calla },
        .{ .word = encode.ret(), .op = .ret },
        .{ .word = encode.push(7), .op = .push, .ra = 7 },
        .{ .word = encode.pop(8), .op = .pop, .rd = 8 },
        .{ .word = encode.pusha(), .op = .pusha },
        .{ .word = encode.popa(), .op = .popa },
        .{ .word = encode.nop(), .op = .nop },
        .{ .word = encode.hlt(), .op = .hlt },
        .{ .word = encode.rti(), .op = .rti },
        .{ .word = encode.sei(), .op = .sei },
        .{ .word = encode.cli(), .op = .cli },
        .{ .word = encode.mfsr(1, .cyc), .op = .mfsr, .rd = 1, .ra = 5 },
        .{ .word = encode.mtsr(.ivt, 2), .op = .mtsr, .rd = 1, .ra = 2 },
    };
    try testing.expectEqual(encode.opcode_count, samples.len); // all 49 covered
    for (samples) |s| {
        const d = try decode(s.word);
        try testing.expectEqual(s.op, d.op);
        // Register fields exist only in R and I formats; in J format those
        // bits are ADDR26 payload.
        if (formatOf(s.op) != .j) {
            try testing.expectEqual(s.rd, d.rd);
            try testing.expectEqual(s.ra, d.ra);
        }
        if (formatOf(s.op) == .r) try testing.expectEqual(s.rb, d.rb);
    }
    // Field payloads survive the round trip.
    const d_li = try decode(encode.li(9, -131072));
    try testing.expectEqual(@as(u32, 0xFFFE_0000), d_li.imm);
    const d_j = try decode(encode.jmpa(0xFC000));
    try testing.expectEqual(@as(u32, 0xFC000), d_j.addr26);
    const d_b = try decode(encode.bne(-4));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFC), signExtend26(d_b.addr26));
}

test "3.3/3.13 decode: $00, unassigned opcodes, nonzero FUNC/FLAGS are illegal" {
    try testing.expectError(error.IllegalInstruction, decode(0x0000_0000)); // D35
    try testing.expectError(error.IllegalInstruction, decode(0x1C00_0000)); // $07 reserved
    try testing.expectError(error.IllegalInstruction, decode(0xFC00_0000)); // $3F reserved
    // R-format with nonzero reserved fields (D32).
    try testing.expectError(error.IllegalInstruction, decode(encode.add(1, 2, 3) | 1)); // FLAGS
    try testing.expectError(error.IllegalInstruction, decode(encode.nop() | (1 << 5))); // FUNC
    // I/J formats have no reserved fields — low bits are payload.
    _ = try decode(encode.li(1, 1));
    _ = try decode(encode.beq(4));
}

test "3.4 registers: R0 guard and 20-bit write mask" {
    var f = try Fixture.setup();
    defer f.teardown();
    var cpu = &f.cpu;
    cpu.setReg(0, 0xFFFF_FFFF);
    try testing.expectEqual(@as(u32, 0), cpu.getReg(0));
    cpu.setReg(1, 0xFFF4_0000); // $40000 must survive a round-trip
    try testing.expectEqual(@as(u32, 0x40000), cpu.getReg(1));
    // ADD with RD=R0 is discarded (and is what MOV to R0 / a flags-only add does).
    f.load(&.{encode.add(0, 1, 1)});
    f.run(1);
    try testing.expectEqual(@as(u32, 0), f.cpu.getReg(0));
}

test "3.5 load/store: LW/LB/SW/SB, LI sign-extension, LUI preserves low 16" {
    var f = try Fixture.setup();
    defer f.teardown();
    f.load(&.{
        encode.li(1, 0x1234),
        encode.sw(0, 0x80, 1), //   [$80] ← $1234
        encode.lw(2, 0, 0x80), //   R2 ← $1234
        encode.sb(0, 0x84, 1), //   [$84] ← $34
        encode.lb(3, 0, 0x84), //   R3 ← $34 zero-extended
        encode.li(4, 0), //         LOAD_ADDR R4, $40000 (§1.2)
        encode.lui(4, 4),
        encode.sw(4, 0, 1), //      VRAM[$40000] ← $1234
        encode.lw(5, 4, 0),
        encode.li(6, -1), //        R6 ← $FFFFF
        encode.li(7, 0x2BCD), //    LUI must preserve these low 16 bits
        encode.lui(7, 0x3),
    });
    f.run(12);
    try testing.expectEqual(@as(u16, 0x1234), f.bus.read16(0x80));
    try testing.expectEqual(@as(u32, 0x1234), f.cpu.getReg(2));
    try testing.expectEqual(@as(u32, 0x34), f.cpu.getReg(3));
    try testing.expectEqual(@as(u32, 0x40000), f.cpu.getReg(4));
    try testing.expectEqual(@as(u32, 0x1234), f.cpu.getReg(5));
    try testing.expectEqual(@as(u32, 0xFFFFF), f.cpu.getReg(6)); // LI sext18 → 20, masked
    try testing.expectEqual(@as(u32, 0x32BCD), f.cpu.getReg(7)); // LUI: 19:16 ← 3, low 16 kept
    // Negative base+offset addressing wraps in 20 bits.
    f.load(&.{ encode.li(1, 0x10), encode.sw(1, -4, 1), encode.lw(2, 1, -4) });
    f.run(3);
    try testing.expectEqual(@as(u32, 0x10), f.cpu.getReg(2));
    try testing.expectEqual(@as(u16, 0x10), f.bus.read16(0x0C));
}

test "3.6/3.7 ALU: results and the §1.6 flag table" {
    var f = try Fixture.setup();
    defer f.teardown();
    const cpu = &f.cpu;

    // ADD carry + 20-bit result: $0FFFF + $0FFFF = $1FFFE, C=1 (bit-15 carry).
    f.load(&.{ encode.li(1, 0xFFFF), encode.add(2, 1, 1) });
    f.run(2);
    try testing.expectEqual(@as(u32, 0x1FFFE), cpu.getReg(2)); // bit 16 survives (20-bit model)
    try testing.expect(cpu.flags & flag_c != 0);
    try testing.expect(cpu.flags & flag_z == 0);
    try testing.expect(cpu.flags & flag_n != 0); // low16 $FFFE bit 15
    try testing.expect(cpu.flags & flag_v == 0); // -1 + -1 = -2, no signed overflow

    // ADD signed overflow: $7FFF + 1 → V=1, N=1, C=0.
    f.load(&.{ encode.li(1, 0x7FFF), encode.addi(2, 1, 1) });
    f.run(2);
    try testing.expect(cpu.flags & flag_v != 0);
    try testing.expect(cpu.flags & flag_n != 0);
    try testing.expect(cpu.flags & flag_c == 0);

    // SUB borrow (ARM no-borrow C): 1 − 2 → C=0, N=1, V=0; result low16 $FFFF.
    f.load(&.{ encode.li(1, 1), encode.subi(2, 1, 2) });
    f.run(2);
    try testing.expectEqual(@as(u32, 0xFFFFF), cpu.getReg(2)); // full 20-bit wrap
    try testing.expect(cpu.flags & flag_c == 0);
    try testing.expect(cpu.flags & flag_n != 0);
    try testing.expect(cpu.flags & flag_v == 0);

    // SUB no-borrow: 2 − 1 → C=1.
    f.load(&.{ encode.li(1, 2), encode.subi(2, 1, 1) });
    f.run(2);
    try testing.expect(cpu.flags & flag_c != 0);

    // CMP signed overflow: $7FFF − $FFFF(−1) → V=1, N=1 (N=V: signed ≥).
    f.load(&.{ encode.li(1, 0x7FFF), encode.li(2, 0xFFFF), encode.cmp(1, 2) });
    f.run(3);
    try testing.expect(cpu.flags & flag_v != 0);
    try testing.expect(cpu.flags & flag_n != 0);
    try testing.expect(cpu.flags & flag_c == 0); // unsigned: $7FFF < $FFFF

    // Logic clears C and V; Z on zero result.
    f.load(&.{ encode.li(1, 0xFF), encode.xor(2, 1, 1) });
    f.run(2);
    try testing.expect(cpu.flags & flag_z != 0);
    try testing.expect(cpu.flags & (flag_c | flag_v) == 0);

    // NOT on a 20-bit value.
    f.load(&.{ encode.li(1, 0), encode.not(2, 1) });
    f.run(2);
    try testing.expectEqual(@as(u32, 0xFFFFF), cpu.getReg(2));

    // MUL keeps low 16 only: $100 × $300 = $30000 → RD=0, Z=1.
    f.load(&.{ encode.li(1, 0x100), encode.li(2, 0x300), encode.mul(3, 1, 2) });
    f.run(3);
    try testing.expectEqual(@as(u32, 0), cpu.getReg(3));
    try testing.expect(cpu.flags & flag_z != 0);

    // DIV/MOD and divide-by-zero → $FFFF, V=1 (no trap).
    f.load(&.{
        encode.li(1, 100),   encode.li(2, 7),
        encode.div(3, 1, 2), encode.mod(4, 1, 2),
        encode.div(5, 1, 0), // ÷ R0 = ÷ 0
    });
    f.run(5);
    try testing.expectEqual(@as(u32, 14), cpu.getReg(3));
    try testing.expectEqual(@as(u32, 2), cpu.getReg(4));
    try testing.expectEqual(@as(u32, 0xFFFF), cpu.getReg(5));
    try testing.expect(cpu.flags & flag_v != 0);
    try testing.expect(cpu.flags & flag_n != 0);

    // Shifts: SHL keeps 20-bit bits, carry from the 16-bit field;
    // SHR by 16 exposes pointer bits 19:16 (§1.1 technique);
    // ASR is 16-bit signed with zero-extended result.
    f.load(&.{
        encode.li(1, 0xC000), encode.li(2, 2), encode.shl(3, 1, 2), // $C000<<2 = $30000, C=1
        encode.li(4, -4), // $FFFFC
        // Shift amounts are RB[3:0] (0-15) - "SHR by 16" from §1.1 is two
        // shifts of 8. The 20-bit domain carries bits 19:16 down.
        encode.li(5, 8), encode.shr(6, 4, 5), encode.shr(6, 6, 5), // $FFFFC>>8>>8 = $F
        encode.li(7, 1), encode.asr(8, 4, 7), // low16 $FFFC asr 1 = $FFFE
    });
    f.run(9);
    try testing.expectEqual(@as(u32, 0x30000), cpu.getReg(3));
    try testing.expectEqual(@as(u32, 0xF), cpu.getReg(6));
    try testing.expectEqual(@as(u32, 0xFFFE), cpu.getReg(8)); // bits 19:16 zeroed (D37)
    // Zero shift: C=0.
    f.load(&.{ encode.li(1, 0x8000), encode.shl(2, 1, 0) });
    f.run(2);
    try testing.expect(cpu.flags & flag_c == 0);
    // SHL carry: $8000 << 1 → C=1, low16 0 → Z=... result $10000 low16=0, Z=1.
    f.load(&.{ encode.li(1, 0x8000), encode.li(2, 1), encode.shl(3, 1, 2) });
    f.run(3);
    try testing.expect(cpu.flags & flag_c != 0);
    try testing.expect(cpu.flags & flag_z != 0);
    try testing.expectEqual(@as(u32, 0x10000), cpu.getReg(3));
    // Shift amount comes from RB bits 3:0 only: shift by 17 ≡ shift by 1.
    f.load(&.{ encode.li(1, 2), encode.li(2, 17), encode.shr(3, 1, 2) });
    f.run(3);
    try testing.expectEqual(@as(u32, 1), cpu.getReg(3));
}

test "3.9 branches: every condition, taken and not taken, byte offsets" {
    var f = try Fixture.setup();
    defer f.teardown();
    // After CMP 5,5 (equal): Z=1, C=1, N=V=0.
    f.load(&.{ encode.li(1, 5), encode.cmp(1, 1), encode.beq(8) });
    f.run(3);
    // beq at $01008; next = $0100C; +8 → $01014.
    try testing.expectEqual(@as(u32, 0x01014), f.cpu.pc);
    // Not taken: PC just falls through.
    f.load(&.{ encode.li(1, 5), encode.cmp(1, 1), encode.bne(8) });
    f.run(3);
    try testing.expectEqual(@as(u32, 0x0100C), f.cpu.pc);
    // Backward branch: offset −12 from next.
    f.load(&.{ encode.li(1, 5), encode.cmp(1, 1), encode.beq(-12) });
    f.run(3);
    try testing.expectEqual(@as(u32, 0x01000), f.cpu.pc);

    const Case = struct { a: i32, b: i32, taken: []const Opcode, not_taken: []const Opcode };
    const cases = [_]Case{
        // equal
        .{ .a = 5, .b = 5, .taken = &.{ .beq, .ble, .bge, .bcs }, .not_taken = &.{ .bne, .blt, .bgt, .bcc } },
        // 1 vs 2: signed less, unsigned less
        .{ .a = 1, .b = 2, .taken = &.{ .bne, .blt, .ble, .bcc }, .not_taken = &.{ .beq, .bgt, .bge, .bcs } },
        // 2 vs 1: signed greater, unsigned greater-or-equal
        .{ .a = 2, .b = 1, .taken = &.{ .bne, .bgt, .bge, .bcs }, .not_taken = &.{ .beq, .blt, .ble, .bcc } },
        // $7FFF vs $FFFF: signed 32767 > −1 (V=1 makes N=V), unsigned less
        .{ .a = 0x7FFF, .b = 0xFFFF, .taken = &.{ .bne, .bgt, .bge, .bcc }, .not_taken = &.{ .beq, .blt, .ble, .bcs } },
    };
    for (cases) |c| {
        for (c.taken) |op| {
            f.load(&.{ encode.li(1, c.a), encode.li(2, c.b), encode.cmp(1, 2), encode.formatJ(op, 8) });
            f.run(4);
            try testing.expectEqual(@as(u32, 0x01018), f.cpu.pc); // $01010 + 8
        }
        for (c.not_taken) |op| {
            f.load(&.{ encode.li(1, c.a), encode.li(2, c.b), encode.cmp(1, 2), encode.formatJ(op, 8) });
            f.run(4);
            try testing.expectEqual(@as(u32, 0x01010), f.cpu.pc); // fell through
        }
    }
}

test "3.10 jumps and calls: JMP/JMPA/CALL/CALLA/RET chain with 20-bit LR" {
    var f = try Fixture.setup();
    defer f.teardown();
    // CALLA to a subroutine planted high in RAM, above $FFFF.
    write32(&f.bus, 0x40000, encode.addi(1, 1, 1));
    write32(&f.bus, 0x40004, encode.ret());
    f.load(&.{ encode.calla(0x40000), encode.hlt() });
    f.run(4);
    try testing.expect(f.cpu.halted);
    try testing.expectEqual(@as(u32, 1), f.cpu.getReg(1));
    try testing.expectEqual(@as(u32, 0x01004), f.cpu.getReg(Gab16.lr));
    // JMP/CALL register-indirect with a 20-bit target.
    var f2 = try Fixture.setup();
    defer f2.teardown();
    write32(&f2.bus, 0x40000, encode.hlt());
    f2.load(&.{ encode.li(2, 0), encode.lui(2, 4), encode.jmp(2) });
    f2.run(4);
    try testing.expect(f2.cpu.halted);
    try testing.expectEqual(@as(u32, 0x40004), f2.cpu.pc);
    // CALL: LR = following instruction.
    f2.cpu.halted = false;
    write32(&f2.bus, 0x40000, encode.ret());
    f2.load(&.{ encode.li(2, 0), encode.lui(2, 4), encode.call(2), encode.hlt() });
    f2.run(5);
    try testing.expect(f2.cpu.halted);
    try testing.expectEqual(@as(u32, 0x0100C), f2.cpu.getReg(Gab16.lr));
}

test "3.11 stack: PUSH/POP 4-byte slots, 20-bit values, PUSHA/POPA 52 bytes" {
    var f = try Fixture.setup();
    defer f.teardown();
    const cpu = &f.cpu;
    f.load(&.{
        encode.li(1, 0xEDCB), encode.lui(1, 0xF), // R1 = $FEDCB
        encode.push(1),       encode.pop(2),
    });
    f.run(4);
    try testing.expectEqual(@as(u32, 0xFEDCB), cpu.getReg(2)); // 20-bit round-trip
    try testing.expectEqual(@as(u32, 0x01100), cpu.getReg(Gab16.sp)); // balanced
    // Slot layout: PUSH writes 4 bytes at SP−4.
    f.load(&.{ encode.li(1, 0xEDCB), encode.lui(1, 0xF), encode.push(1) });
    f.run(3);
    try testing.expectEqual(@as(u32, 0x010FC), cpu.getReg(Gab16.sp));
    try testing.expectEqual(@as(u32, 0x000FEDCB), read32(&f.bus, 0x010FC));
    // PUSHA/POPA: R1–R12 + LR = 13 slots = 52 bytes; restores everything.
    var f3 = try Fixture.setup();
    defer f3.teardown();
    var setup_prog: [16]u32 = undefined;
    for (0..12) |i| setup_prog[i] = encode.li(@intCast(i + 1), @intCast(i + 1));
    setup_prog[12] = encode.pusha();
    setup_prog[13] = encode.li(1, 0x0BAD); // clobber
    setup_prog[14] = encode.li(12, 0x0BAD);
    setup_prog[15] = encode.popa();
    f3.cpu.setReg(Gab16.lr, 0x12345);
    f3.load(&setup_prog);
    f3.run(13);
    try testing.expectEqual(@as(u32, 0x01100 - 52), f3.cpu.getReg(Gab16.sp));
    f3.run(3);
    try testing.expectEqual(@as(u32, 0x01100), f3.cpu.getReg(Gab16.sp));
    try testing.expectEqual(@as(u32, 1), f3.cpu.getReg(1));
    try testing.expectEqual(@as(u32, 12), f3.cpu.getReg(12));
    try testing.expectEqual(@as(u32, 0x12345), f3.cpu.getReg(Gab16.lr));
}

test "3.12 system: HLT halts and idles; SEI/CLI; MFSR/MTSR + privilege" {
    var f = try Fixture.setup();
    defer f.teardown();
    const cpu = &f.cpu;
    f.load(&.{ encode.sei(), encode.cli(), encode.hlt(), encode.nop() });
    f.run(2);
    try testing.expect(cpu.flags & flag_i == 0); // SEI then CLI
    f.run(1);
    try testing.expect(cpu.halted);
    const pc_at_halt = cpu.pc;
    try testing.expectEqual(Event.halted_idle, f.cpu.step(&f.bus));
    try testing.expectEqual(pc_at_halt, cpu.pc); // idle cycles don't fetch
    try testing.expectEqual(@as(u32, 4), cpu.cyc); // but do count (D41)

    // Supervisor MTSR/MFSR round-trips.
    var f2 = try Fixture.setup();
    defer f2.teardown();
    f2.load(&.{
        encode.li(1, 0xFFC0), encode.lui(1, 0xF), // $FFFC0
        encode.mtsr(.ivt, 1), encode.mfsr(2, .ivt),
        encode.li(3, 0x20F0), encode.mtsr(.ssp, 3),
        encode.li(4, 0x1100), encode.mtsr(.usp, 4),
        encode.mfsr(5, .cyc),
        encode.mtsr(.cyc, 1), // ignored
        encode.mfsr(6, .flags),
    });
    f2.run(11);
    try testing.expectEqual(@as(u32, 0xFFFC0), f2.cpu.ivt);
    try testing.expectEqual(@as(u32, 0xFFFC0), f2.cpu.getReg(2));
    try testing.expectEqual(@as(u32, 0x20F0), f2.cpu.ssp);
    try testing.expectEqual(@as(u32, 0x1100), f2.cpu.usp);
    try testing.expectEqual(@as(u32, 9), f2.cpu.getReg(5)); // CYC when MFSR ran (masked write)
    try testing.expect(f2.cpu.getReg(6) & flag_s != 0);
    // Supervisor FLAGS write can set/clear I and S... clearing S drops to
    // user mode; covered in the mode-transition test below.
}

test "3.13 illegal opcode trap: $00000000 traps to BRK, never executes" {
    var f = try Fixture.setup();
    defer f.teardown();
    const cpu = &f.cpu;
    // IVT = 0 → BRK vector read from RAM $0000C; plant a handler.
    write32(&f.bus, 0x0000C, 0x02000); // BRK vector → $02000
    write32(&f.bus, 0x02000, encode.hlt());
    f.load(&.{0x0000_0000}); // cleared-RAM word
    try testing.expectEqual(Event.trapped, f.cpu.step(&f.bus));
    try testing.expectEqual(@as(u32, 0x02000), cpu.pc);
    // 8-byte frame on the supervisor path (S was already 1 → no switch):
    // [SP] = FLAGS, [SP+4] = resume PC (the word after the illegal one).
    try testing.expectEqual(@as(u32, 0x01100 - 8), cpu.getReg(Gab16.sp));
    try testing.expectEqual(@as(u32, flag_s), read32(&f.bus, cpu.getReg(Gab16.sp)));
    try testing.expectEqual(@as(u32, 0x01004), read32(&f.bus, cpu.getReg(Gab16.sp) + 4));
    f.run(1);
    try testing.expect(cpu.halted);
}

test "3.14/3.15 IRQ entry and RTI: 8-byte frame, stack switch, nesting" {
    var f = try Fixture.setup();
    defer f.teardown();
    const cpu = &f.cpu;
    // Supervisor setup: IVT at $00000 (RAM) with IRQ vector → $03000.
    write32(&f.bus, 0x00008, 0x03000); // IVT entry 2 (IRQ)
    write32(&f.bus, 0x03000, encode.addi(1, 1, 1));
    write32(&f.bus, 0x03004, encode.rti());
    cpu.ssp = 0x020F0;
    cpu.usp = 0;
    f.load(&.{ encode.sei(), encode.nop(), encode.nop(), encode.nop() });
    f.run(1); // SEI
    cpu.irq_line = true;
    // Nested path (S=1): no stack switch; frame lands on the current SP.
    try testing.expectEqual(Event.irq_entered, f.cpu.step(&f.bus));
    cpu.irq_line = false;
    try testing.expectEqual(@as(u32, 0x03000), cpu.pc);
    try testing.expect(cpu.flags & flag_i == 0); // I cleared on entry
    try testing.expectEqual(@as(u32, 0x01100 - 8), cpu.getReg(Gab16.sp)); // 8-byte frame
    const frame_flags = read32(&f.bus, cpu.getReg(Gab16.sp));
    try testing.expectEqual(@as(u32, flag_s | flag_i), frame_flags); // pre-entry FLAGS, upper 16 zero
    try testing.expectEqual(@as(u32, 0x01004), read32(&f.bus, cpu.getReg(Gab16.sp) + 4)); // resume PC
    f.run(2); // handler body + RTI
    try testing.expectEqual(@as(u32, 1), cpu.getReg(1));
    try testing.expectEqual(@as(u32, 0x01004), cpu.pc); // resumed
    try testing.expectEqual(@as(u32, 0x01100), cpu.getReg(Gab16.sp)); // balanced
    try testing.expect(cpu.flags & flag_i != 0); // I restored

    // User-mode entry: stack switch USP←SP, SP←SSP; RTI switches back.
    var f2 = try Fixture.setup();
    defer f2.teardown();
    const c2 = &f2.cpu;
    write32(&f2.bus, 0x00008, 0x03000);
    write32(&f2.bus, 0x03000, encode.rti());
    c2.ssp = 0x020F0;
    c2.flags = flag_i; // user mode (S=0), interrupts enabled
    c2.setReg(Gab16.sp, 0x01100);
    c2.pc = 0x01000;
    write32(&f2.bus, 0x01000, encode.nop());
    c2.irq_line = true;
    try testing.expectEqual(Event.irq_entered, c2.step(&f2.bus));
    c2.irq_line = false;
    try testing.expectEqual(@as(u32, 0x01100), c2.usp); // user SP saved
    try testing.expectEqual(@as(u32, 0x020F0 - 8), c2.getReg(Gab16.sp)); // on supervisor stack
    try testing.expect(c2.flags & flag_s != 0);
    _ = c2.step(&f2.bus); // RTI
    try testing.expect(c2.flags & flag_s == 0); // back to user
    try testing.expectEqual(@as(u32, 0x01100), c2.getReg(Gab16.sp)); // SP ← USP
    try testing.expectEqual(@as(u32, 0x020F0), c2.ssp); // SSP recaptured

    // HLT wakes only on a delivered interrupt (§1.5).
    var f3 = try Fixture.setup();
    defer f3.teardown();
    const c3 = &f3.cpu;
    write32(&f3.bus, 0x00008, 0x03000);
    write32(&f3.bus, 0x03000, encode.rti());
    c3.ssp = 0x020F0;
    f3.load(&.{ encode.hlt(), encode.nop() });
    f3.run(1);
    try testing.expect(c3.halted);
    c3.irq_line = true; // I=0 → masked → stays halted
    try testing.expectEqual(Event.halted_idle, c3.step(&f3.bus));
    try testing.expect(c3.halted);
    c3.flags |= flag_i; // (a real program would have SEI'd before HLT)
    try testing.expectEqual(Event.irq_entered, c3.step(&f3.bus));
    c3.irq_line = false;
    try testing.expect(!c3.halted);
}

test "3.16 mode transitions: MTSR privilege traps; user FLAGS write ignores I/S" {
    var f = try Fixture.setup();
    defer f.teardown();
    const cpu = &f.cpu;
    write32(&f.bus, 0x0000C, 0x02000); // BRK vector (IVT=0)
    write32(&f.bus, 0x02000, encode.hlt());
    cpu.ssp = 0x020F0;
    cpu.flags = 0; // user mode, I=0
    f.load(&.{encode.mtsr(.ivt, 1)}); // supervisor-only → trap
    try testing.expectEqual(Event.trapped, f.cpu.step(&f.bus));
    try testing.expectEqual(@as(u32, 0x02000), cpu.pc);
    try testing.expect(cpu.flags & flag_s != 0); // trap entered supervisor
    try testing.expectEqual(@as(u32, 0x01100), cpu.usp); // user SP was saved
    try testing.expectEqual(@as(u32, 0x020F0 - 8), cpu.getReg(Gab16.sp));

    // MTSR SSP and SYS also trap in user mode; USP does not.
    var f2 = try Fixture.setup();
    defer f2.teardown();
    f2.cpu.ssp = 0x020F0;
    f2.cpu.flags = 0;
    write32(&f2.bus, 0x0000C, 0x02000);
    f2.load(&.{encode.mtsr(.usp, 1)});
    try testing.expectEqual(Event.executed, f2.cpu.step(&f2.bus));
    f2.cpu.pc = 0x01000;
    f2.load(&.{encode.mtsr(.sys, 1)});
    try testing.expectEqual(Event.trapped, f2.cpu.step(&f2.bus));

    // User-mode MTSR FLAGS cannot set I or S (§1.4).
    var f3 = try Fixture.setup();
    defer f3.teardown();
    f3.cpu.flags = 0; // user, I=0
    f3.load(&.{ encode.li(1, 0x3F), encode.mtsr(.flags, 1) });
    f3.run(2);
    try testing.expectEqual(flag_z | flag_n | flag_c | flag_v, f3.cpu.flags); // I,S unchanged (0)
    // Supervisor can clear S (dropping to user mode).
    var f4 = try Fixture.setup();
    defer f4.teardown();
    f4.load(&.{ encode.li(1, 0), encode.mtsr(.flags, 1) });
    f4.run(2);
    try testing.expect(f4.cpu.flags & flag_s == 0);
}

test "D44: RTI is supervisor-only — user-mode RTI traps, no escalation" {
    var f = try Fixture.setup();
    defer f.teardown();
    const cpu = &f.cpu;
    write32(&f.bus, 0x0000C, 0x02000); // BRK vector (IVT = 0)
    write32(&f.bus, 0x02000, encode.hlt());
    cpu.ssp = 0x020F0;
    cpu.flags = 0; // user mode
    // The attack: craft a frame with S=1 and RTI into supervisor mode.
    f.load(&.{
        encode.li(1, 0x30), // FLAGS image: S=1, I=1
        encode.push(1),
        encode.rti(),
    });
    // (frame layout irrelevant — the RTI must trap before touching it)
    f.run(2);
    try testing.expectEqual(Event.trapped, f.cpu.step(&f.bus));
    try testing.expectEqual(@as(u32, 0x02000), cpu.pc); // in the BRK handler
    // Supervisor mode was entered by the *trap*, with a proper frame on the
    // supervisor stack — not by the forged RTI.
    try testing.expectEqual(@as(u32, 0x020F0 - 8), cpu.getReg(Gab16.sp));
    const pushed_flags = read32(&f.bus, cpu.getReg(Gab16.sp));
    try testing.expectEqual(@as(u32, 0), pushed_flags & flag_s); // pre-trap S=0 preserved
}

test "D45: SEI/CLI are ignored in user mode; supervisor unaffected" {
    var f = try Fixture.setup();
    defer f.teardown();
    const cpu = &f.cpu;
    // User mode with I=1: CLI must not clear it, SEI must be a no-op too.
    cpu.flags = flag_i;
    f.load(&.{ encode.cli(), encode.sei(), encode.nop() });
    f.run(2);
    try testing.expectEqual(flag_i, cpu.flags); // untouched, no trap
    // User mode with I=0: SEI must not enable interrupts.
    cpu.flags = 0;
    f.load(&.{encode.sei()});
    f.run(1);
    try testing.expectEqual(@as(u16, 0), cpu.flags);
    // Supervisor semantics unchanged.
    cpu.flags = flag_s;
    f.load(&.{ encode.sei(), encode.cli() });
    f.run(1);
    try testing.expect(cpu.flags & flag_i != 0);
    f.run(1);
    try testing.expect(cpu.flags & flag_i == 0);
}

test "D46: supervisor MTSR FLAGS clearing S performs no stack switch" {
    var f = try Fixture.setup();
    defer f.teardown();
    const cpu = &f.cpu;
    cpu.ssp = 0x020F0;
    cpu.usp = 0x00500;
    f.load(&.{ encode.li(1, 0), encode.mtsr(.flags, 1) });
    f.run(2);
    try testing.expect(cpu.flags & flag_s == 0); // dropped to user…
    try testing.expectEqual(@as(u32, 0x01100), cpu.getReg(Gab16.sp)); // …but SP untouched
    try testing.expectEqual(@as(u32, 0x00500), cpu.usp); // USP untouched
    try testing.expectEqual(@as(u32, 0x020F0), cpu.ssp); // SSP untouched
}

test "3.17 decoder fuzz: random instruction words never panic" {
    var f = try Fixture.setup();
    defer f.teardown();
    var prng = std.Random.DefaultPrng.init(0x600D_F10E); // fixed seed — deterministic
    const random = prng.random();
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        const word = random.int(u32);
        f.cpu.pc = 0x01000;
        write32(&f.bus, 0x01000, word);
        _ = f.cpu.step(&f.bus); // trap or execute — never panic
        // Architectural invariants hold whatever happened.
        try testing.expect(f.cpu.pc <= util.addr_mask);
        try testing.expectEqual(@as(u32, 0), f.cpu.getReg(0));
        for (f.cpu.r) |reg| try testing.expect(reg <= util.addr_mask);
        f.cpu.halted = false; // keep the loop moving past HLTs
    }
}
