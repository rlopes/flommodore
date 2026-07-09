//! Flommodore — `disasm.zig` (Block 9, task 9.4).
//!
//! Gab-16 disassembler. The inverse of encode.zig, built on the SAME
//! opcode table (encode.Opcode / encode.formatOf) and the Block 3 decoder
//! (cpu.decode) — no second copy of encoding knowledge exists (audit P1).
//! Used by the debugger's `d` command; the Block 10 assembler's `.flst`
//! listing writer will reuse it.
//!
//! Output shape follows the master spec §8.8 listing format:
//!
//! ```
//! LI    R1, $600D
//! SW    [R1+4], R2
//! BEQ   $FC220
//! MFSR  R5, CYC
//! ```
//!
//! Formatting rules (deterministic, unit-tested):
//!   - mnemonics upper-case, padded to 5 columns;
//!   - addresses (branch/jump targets, LI/LUI values) as `$HEX`;
//!   - ALU/offset immediates as signed decimal;
//!   - branch targets shown ABSOLUTE (PC+4+offset), so `target` lets the
//!     debugger annotate with symbols.

const std = @import("std");
const util = @import("util");
const encode = @import("encode");
const cpu_mod = @import("cpu");

/// One disassembled instruction. `text` points into the caller's buffer.
pub const Line = struct {
    text: []const u8,
    /// Absolute control-flow target for J-format branches/JMPA/CALLA —
    /// the debugger resolves it against the symbol table.
    target: ?u32 = null,
    /// True when the word failed to decode (traps to BRK at execution, D35).
    illegal: bool = false,
};

/// Disassemble one 32-bit word fetched from `pc`. `buf` must be at least
/// 48 bytes; the returned slices point into it.
pub fn disassemble(word: u32, pc: u32, buf: []u8) Line {
    const d = cpu_mod.decode(word) catch {
        const text = std.fmt.bufPrint(buf, "???   ; illegal word ${X:0>8}", .{word}) catch unreachable;
        return .{ .text = text, .illegal = true };
    };
    const m = mnemonic(d.op);
    const t = fmtOperands(d, pc, m, buf);
    return t;
}

fn mnemonic(op: encode.Opcode) []const u8 {
    // @tagName gives lower-case ("and", "jmpa"); the table below is the
    // display form. Comptime-derived upper-casing keeps the single table.
    return switch (op) {
        inline else => |o| comptime blk: {
            const lower = @tagName(o);
            var upper: [lower.len]u8 = undefined;
            for (lower, 0..) |ch, i| upper[i] = std.ascii.toUpper(ch);
            const frozen = upper;
            break :blk &frozen;
        },
    };
}

fn signChar(v: i32) u8 {
    return if (v < 0) '-' else '+';
}

fn absOf(v: i32) u32 {
    return @abs(v);
}

fn sregName(field: u4) []const u8 {
    return if (std.enums.fromInt(encode.Sreg, field)) |s| switch (s) {
        .flags => "FLAGS",
        .ivt => "IVT",
        .usp => "USP",
        .ssp => "SSP",
        .sys => "SYS",
        .cyc => "CYC",
    } else "SR?";
}

fn fmtOperands(d: cpu_mod.Decoded, pc: u32, m: []const u8, buf: []u8) Line {
    const imm_s: i32 = @bitCast(d.imm); // sign-extended IMM18
    const p = std.fmt.bufPrint;
    return switch (d.op) {
        // Load/store: base+offset addressing (sign always shown).
        .lw, .lb => .{ .text = p(buf, "{s: <5} R{d}, [R{d}{c}{d}]", .{ m, d.rd, d.ra, signChar(imm_s), absOf(imm_s) }) catch unreachable },
        // SW/SB carry the SOURCE in the RD field (§1.3 footnote).
        .sw, .sb => .{ .text = p(buf, "{s: <5} [R{d}{c}{d}], R{d}", .{ m, d.ra, signChar(imm_s), absOf(imm_s), d.rd }) catch unreachable },
        // Immediates loads: hex (they build addresses/masks).
        .li => .{ .text = p(buf, "{s: <5} R{d}, ${X:0>4}", .{ m, d.rd, @as(u32, @bitCast(imm_s)) & 0xFFFF }) catch unreachable },
        .lui => .{ .text = p(buf, "{s: <5} R{d}, ${X}", .{ m, d.rd, @as(u32, @bitCast(imm_s)) & 0xF }) catch unreachable },
        // ALU register-register.
        .add, .sub, .@"and", .@"or", .xor, .shl, .shr, .asr, .mul, .div, .mod => .{ .text = p(buf, "{s: <5} R{d}, R{d}, R{d}", .{ m, d.rd, d.ra, d.rb }) catch unreachable },
        .not => .{ .text = p(buf, "{s: <5} R{d}, R{d}", .{ m, d.rd, d.ra }) catch unreachable },
        .cmp => .{ .text = p(buf, "{s: <5} R{d}, R{d}", .{ m, d.ra, d.rb }) catch unreachable },
        // ALU immediate: signed decimal.
        .addi, .subi, .andi, .ori, .xori => .{ .text = p(buf, "{s: <5} R{d}, R{d}, {d}", .{ m, d.rd, d.ra, imm_s }) catch unreachable },
        .cmpi => .{ .text = p(buf, "{s: <5} R{d}, {d}", .{ m, d.ra, imm_s }) catch unreachable },
        // Branches: PC-relative in the encoding, absolute in the display.
        .beq, .bne, .blt, .bgt, .ble, .bge, .bcs, .bcc => blk: {
            const off: i32 = @bitCast(util.signExtend(d.addr26, 26));
            const target = util.maskAddr(pc +% 4 +% @as(u32, @bitCast(off)));
            break :blk .{
                .text = p(buf, "{s: <5} ${X:0>5}", .{ m, target }) catch unreachable,
                .target = target,
            };
        },
        .jmpa, .calla => blk: {
            const target = util.maskAddr(d.addr26);
            break :blk .{
                .text = p(buf, "{s: <5} ${X:0>5}", .{ m, target }) catch unreachable,
                .target = target,
            };
        },
        .jmp, .call => .{ .text = p(buf, "{s: <5} R{d}", .{ m, d.ra }) catch unreachable },
        .push => .{ .text = p(buf, "{s: <5} R{d}", .{ m, d.ra }) catch unreachable },
        .pop => .{ .text = p(buf, "{s: <5} R{d}", .{ m, d.rd }) catch unreachable },
        .mfsr => .{ .text = p(buf, "{s: <5} R{d}, {s}", .{ m, d.rd, sregName(d.ra) }) catch unreachable },
        .mtsr => .{ .text = p(buf, "{s: <5} {s}, R{d}", .{ m, sregName(d.rd), d.ra }) catch unreachable },
        .ret, .pusha, .popa, .nop, .hlt, .rti, .sei, .cli => .{ .text = p(buf, "{s}", .{m}) catch unreachable },
    };
}

// ---------------------------------------------------------------------------
// Tests — encode→disassemble round trips over every operand shape.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectDis(word: u32, pc: u32, expected: []const u8) !void {
    var buf: [48]u8 = undefined;
    const line = disassemble(word, pc, &buf);
    try testing.expectEqualStrings(expected, line.text);
}

test "9.4 disassembler: every format and operand shape" {
    try expectDis(encode.li(1, 0x600D), 0, "LI    R1, $600D");
    try expectDis(encode.li(6, -1), 0, "LI    R6, $FFFF");
    try expectDis(encode.lui(3, 0xF), 0, "LUI   R3, $F");
    try expectDis(encode.lw(2, 1, 4), 0, "LW    R2, [R1+4]");
    try expectDis(encode.sw(1, -4, 2), 0, "SW    [R1-4], R2");
    try expectDis(encode.sb(0, 0x90, 11), 0, "SB    [R0+144], R11");
    try expectDis(encode.add(3, 1, 2), 0, "ADD   R3, R1, R2");
    try expectDis(encode.not(9, 8), 0, "NOT   R9, R8");
    try expectDis(encode.cmp(1, 2), 0, "CMP   R1, R2");
    try expectDis(encode.addi(2, 2, 1), 0, "ADDI  R2, R2, 1");
    try expectDis(encode.subi(5, 5, 1), 0, "SUBI  R5, R5, 1");
    try expectDis(encode.cmpi(7, -3), 0, "CMPI  R7, -3");
    try expectDis(encode.andi(6, 5, 0x10), 0, "ANDI  R6, R5, 16");
    try expectDis(encode.jmp(4), 0, "JMP   R4");
    try expectDis(encode.jmpa(0xFC200), 0, "JMPA  $FC200");
    try expectDis(encode.call(4), 0, "CALL  R4");
    try expectDis(encode.calla(0xFC700), 0, "CALLA $FC700");
    try expectDis(encode.push(14), 0, "PUSH  R14");
    try expectDis(encode.pop(9), 0, "POP   R9");
    try expectDis(encode.pusha(), 0, "PUSHA");
    try expectDis(encode.ret(), 0, "RET");
    try expectDis(encode.nop(), 0, "NOP");
    try expectDis(encode.hlt(), 0, "HLT");
    try expectDis(encode.rti(), 0, "RTI");
    try expectDis(encode.sei(), 0, "SEI");
    try expectDis(encode.mfsr(5, .cyc), 0, "MFSR  R5, CYC");
    try expectDis(encode.mtsr(.ivt, 1), 0, "MTSR  IVT, R1");
}

test "9.4 disassembler: branch targets are absolute and reported" {
    var buf: [48]u8 = undefined;
    // Forward: BEQ +4 from $FC200 → next-instruction base $FC204 + 4.
    const fwd = disassemble(encode.formatJ(.beq, 4), 0xFC200, &buf);
    try testing.expectEqualStrings("BEQ   $FC208", fwd.text);
    try testing.expectEqual(@as(?u32, 0xFC208), fwd.target);
    // Backward: offset −8 from $FC210 → $FC20C.
    var buf2: [48]u8 = undefined;
    const off: i32 = -8;
    const back = disassemble(encode.formatJ(.bne, @as(u32, @bitCast(off)) & 0x3FF_FFFF), 0xFC210, &buf2);
    try testing.expectEqualStrings("BNE   $FC20C", back.text);
    try testing.expectEqual(@as(?u32, 0xFC20C), back.target);
    // CALLA reports its target too (step-over and symbol annotation).
    var buf3: [48]u8 = undefined;
    const c = disassemble(encode.calla(0xFC700), 0, &buf3);
    try testing.expectEqual(@as(?u32, 0xFC700), c.target);
}

test "9.4 disassembler: illegal words flagged, never panic" {
    var buf: [48]u8 = undefined;
    const zero = disassemble(0, 0, &buf); // $00 traps (D35)
    try testing.expect(zero.illegal);
    // R-format with nonzero reserved FUNC bits is illegal (D32).
    const bad = disassemble(encode.add(1, 2, 3) | 0x20, 0, &buf);
    try testing.expect(bad.illegal);
    // Fuzz: every word must produce SOME line without panicking.
    var prng = std.Random.DefaultPrng.init(0x600D);
    for (0..10_000) |_| {
        _ = disassemble(prng.random().int(u32), 0xFC200, &buf);
    }
}
