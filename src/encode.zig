//! Flommodore — `encode.zig` (Block 2, task 2.6).
//!
//! Gab-16 instruction encoder: pure functions producing 32-bit instruction
//! words for all 49 assigned opcodes of the LOCKED v1.1 opcode table
//! (spec amendment §1.3 / D32). This module is the single source of encoding
//! truth (audit P1): the Block 2 test-ROM generator, the Block 3 CPU tests
//! (encode∘decode identity), and the Block 10 `flas` codegen backend all
//! import it — encoding logic exists nowhere else.
//!
//! Field layout (Phase 2 §2.3, unchanged by v1.1; all widths sum to 32):
//!
//! ```
//! R: OPCODE[31:26] RD[25:22] RA[21:18] RB[17:14] FUNC[13:5]=0 FLAGS[4:0]=0
//! I: OPCODE[31:26] RD[25:22] RA[21:18] IMM18[17:0]
//! J: OPCODE[31:26] ADDR26[25:0]
//! ```
//!
//! R-format FUNC and FLAGS are reserved and MUST be zero — nonzero traps as
//! an illegal instruction (D32); this encoder never sets them.
//! I-format has no RB field: SW/SB carry their source register in the RD
//! field (§1.3 footnote).

const std = @import("std");
const util = @import("util");

/// The 49 assigned opcodes (amendment §1.3). `$00` and every unlisted value
/// trap to the BRK vector (D35) and are deliberately absent.
pub const Opcode = enum(u6) {
    // Load / store
    lw = 0x01,
    lb = 0x02,
    sw = 0x03,
    sb = 0x04,
    li = 0x05,
    lui = 0x06,
    // ALU register-register
    add = 0x08,
    sub = 0x09,
    @"and" = 0x0A,
    @"or" = 0x0B,
    xor = 0x0C,
    not = 0x0D,
    shl = 0x0E,
    shr = 0x0F,
    asr = 0x10,
    mul = 0x11,
    div = 0x12,
    mod = 0x13,
    cmp = 0x14,
    // ALU immediate
    addi = 0x18,
    subi = 0x19,
    andi = 0x1A,
    ori = 0x1B,
    xori = 0x1C,
    cmpi = 0x1D,
    // Branches (J, PC-relative) and jumps
    beq = 0x20,
    bne = 0x21,
    blt = 0x22,
    bgt = 0x23,
    ble = 0x24,
    bge = 0x25,
    bcs = 0x26,
    bcc = 0x27,
    jmp = 0x28,
    jmpa = 0x29,
    call = 0x2A,
    calla = 0x2B,
    ret = 0x2C,
    // Stack
    push = 0x30,
    pop = 0x31,
    pusha = 0x32,
    popa = 0x33,
    // System
    nop = 0x38,
    hlt = 0x39,
    rti = 0x3A,
    sei = 0x3B,
    cli = 0x3C,
    mfsr = 0x3D,
    mtsr = 0x3E,
};

/// Number of assigned opcodes — 49 (+1 MOV pseudo), per §1.3.
pub const opcode_count = @typeInfo(Opcode).@"enum".fields.len;
comptime {
    std.debug.assert(opcode_count == 49);
}

/// IMM18 range: signed 18-bit, −131072 … +131071 (Phase 2 §2.3).
pub const imm18_min: i32 = -131_072;
pub const imm18_max: i32 = 131_071;

/// PCREL26 branch offset range: signed 26-bit, in bytes (§1.3).
pub const pcrel26_min: i32 = -(1 << 25);
pub const pcrel26_max: i32 = (1 << 25) - 1;

// ---------------------------------------------------------------------------
// Format constructors.
// ---------------------------------------------------------------------------

/// R-format word. FUNC and FLAGS are emitted as zero (reserved, D32).
pub fn formatR(op: Opcode, rd: u4, ra: u4, rb: u4) u32 {
    var w: u32 = 0;
    w = util.insertBits(w, 26, 6, @intFromEnum(op));
    w = util.insertBits(w, 22, 4, rd);
    w = util.insertBits(w, 18, 4, ra);
    w = util.insertBits(w, 14, 4, rb);
    return w;
}

/// I-format word. `imm` must be in the signed 18-bit range; values 0…$FFFF
/// therefore always encode verbatim (the LOAD_ADDR macro relies on this —
/// amendment §1.2).
pub fn formatI(op: Opcode, rd: u4, ra: u4, imm: i32) u32 {
    std.debug.assert(imm >= imm18_min and imm <= imm18_max);
    var w: u32 = 0;
    w = util.insertBits(w, 26, 6, @intFromEnum(op));
    w = util.insertBits(w, 22, 4, rd);
    w = util.insertBits(w, 18, 4, ra);
    w = util.insertBits(w, 0, 18, @bitCast(imm));
    return w;
}

/// J-format word with a raw 26-bit field value.
pub fn formatJ(op: Opcode, addr26: u32) u32 {
    std.debug.assert(addr26 <= 0x3FF_FFFF);
    var w: u32 = 0;
    w = util.insertBits(w, 26, 6, @intFromEnum(op));
    w = util.insertBits(w, 0, 26, addr26);
    return w;
}

/// J-format word for a PC-relative branch: `offset` is the signed byte
/// distance from the *next* instruction (`target − (instr_addr + 4)`, §1.3).
fn formatJRel(op: Opcode, offset: i32) u32 {
    std.debug.assert(offset >= pcrel26_min and offset <= pcrel26_max);
    return formatJ(op, @as(u32, @bitCast(offset)) & 0x3FF_FFFF);
}

// ---------------------------------------------------------------------------
// Load / store (§1.3). Assembly operand order is preserved in the argument
// order; note SW/SB place the source register in the RD field.
// ---------------------------------------------------------------------------

/// `LW RD, [RA + IMM]`
pub fn lw(rd: u4, ra: u4, imm: i32) u32 {
    return formatI(.lw, rd, ra, imm);
}
/// `LB RD, [RA + IMM]` — zero-extends the byte.
pub fn lb(rd: u4, ra: u4, imm: i32) u32 {
    return formatI(.lb, rd, ra, imm);
}
/// `SW [RA + IMM], RS` — RS is encoded in the RD field (I-format has no RB).
pub fn sw(ra: u4, imm: i32, rs: u4) u32 {
    return formatI(.sw, rs, ra, imm);
}
/// `SB [RA + IMM], RS` — RS in the RD field; stores the low 8 bits.
pub fn sb(ra: u4, imm: i32, rs: u4) u32 {
    return formatI(.sb, rs, ra, imm);
}
/// `LI RD, IMM18` — RD = sign_extend_18_to_20(IMM18) & $FFFFF (§1.2).
pub fn li(rd: u4, imm: i32) u32 {
    return formatI(.li, rd, 0, imm);
}
/// `LUI RD, IMM` — RD bits 19:16 = IMM & $F, low 16 bits preserved (§1.2).
pub fn lui(rd: u4, imm: i32) u32 {
    return formatI(.lui, rd, 0, imm);
}

// ---------------------------------------------------------------------------
// ALU register-register.
// ---------------------------------------------------------------------------

pub fn add(rd: u4, ra: u4, rb: u4) u32 {
    return formatR(.add, rd, ra, rb);
}
pub fn sub(rd: u4, ra: u4, rb: u4) u32 {
    return formatR(.sub, rd, ra, rb);
}
pub fn @"and"(rd: u4, ra: u4, rb: u4) u32 {
    return formatR(.@"and", rd, ra, rb);
}
pub fn @"or"(rd: u4, ra: u4, rb: u4) u32 {
    return formatR(.@"or", rd, ra, rb);
}
pub fn xor(rd: u4, ra: u4, rb: u4) u32 {
    return formatR(.xor, rd, ra, rb);
}
/// `NOT RD, RA` — unary; RB field is zero.
pub fn not(rd: u4, ra: u4) u32 {
    return formatR(.not, rd, ra, 0);
}
pub fn shl(rd: u4, ra: u4, rb: u4) u32 {
    return formatR(.shl, rd, ra, rb);
}
pub fn shr(rd: u4, ra: u4, rb: u4) u32 {
    return formatR(.shr, rd, ra, rb);
}
pub fn asr(rd: u4, ra: u4, rb: u4) u32 {
    return formatR(.asr, rd, ra, rb);
}
pub fn mul(rd: u4, ra: u4, rb: u4) u32 {
    return formatR(.mul, rd, ra, rb);
}
pub fn div(rd: u4, ra: u4, rb: u4) u32 {
    return formatR(.div, rd, ra, rb);
}
pub fn mod(rd: u4, ra: u4, rb: u4) u32 {
    return formatR(.mod, rd, ra, rb);
}
/// `CMP RA, RB` — flags only; RD field is zero and ignored (§1.3).
pub fn cmp(ra: u4, rb: u4) u32 {
    return formatR(.cmp, 0, ra, rb);
}
/// `MOV RD, RA` — assembler pseudo for `ADD RD, RA, R0` (§1.3).
pub fn mov(rd: u4, ra: u4) u32 {
    return add(rd, ra, 0);
}

// ---------------------------------------------------------------------------
// ALU immediate.
// ---------------------------------------------------------------------------

pub fn addi(rd: u4, ra: u4, imm: i32) u32 {
    return formatI(.addi, rd, ra, imm);
}
pub fn subi(rd: u4, ra: u4, imm: i32) u32 {
    return formatI(.subi, rd, ra, imm);
}
pub fn andi(rd: u4, ra: u4, imm: i32) u32 {
    return formatI(.andi, rd, ra, imm);
}
pub fn ori(rd: u4, ra: u4, imm: i32) u32 {
    return formatI(.ori, rd, ra, imm);
}
pub fn xori(rd: u4, ra: u4, imm: i32) u32 {
    return formatI(.xori, rd, ra, imm);
}
/// `CMPI RA, IMM` — flags only; RD field is zero.
pub fn cmpi(ra: u4, imm: i32) u32 {
    return formatI(.cmpi, 0, ra, imm);
}

// ---------------------------------------------------------------------------
// Branches (PC-relative, byte offset from the next instruction) and jumps.
// ---------------------------------------------------------------------------

pub fn beq(offset: i32) u32 {
    return formatJRel(.beq, offset);
}
pub fn bne(offset: i32) u32 {
    return formatJRel(.bne, offset);
}
pub fn blt(offset: i32) u32 {
    return formatJRel(.blt, offset);
}
pub fn bgt(offset: i32) u32 {
    return formatJRel(.bgt, offset);
}
pub fn ble(offset: i32) u32 {
    return formatJRel(.ble, offset);
}
pub fn bge(offset: i32) u32 {
    return formatJRel(.bge, offset);
}
pub fn bcs(offset: i32) u32 {
    return formatJRel(.bcs, offset);
}
pub fn bcc(offset: i32) u32 {
    return formatJRel(.bcc, offset);
}
/// `JMP RA` — register indirect; RA field only.
pub fn jmp(ra: u4) u32 {
    return formatR(.jmp, 0, ra, 0);
}
/// `JMPA ADDR` — ADDR26 is an absolute byte address, masked to 20 bits at
/// execution (§1.3).
pub fn jmpa(addr: u32) u32 {
    std.debug.assert(addr <= util.addr_mask);
    return formatJ(.jmpa, addr);
}
/// `CALL RA` — LR ← next instruction; PC ← RA.
pub fn call(ra: u4) u32 {
    return formatR(.call, 0, ra, 0);
}
/// `CALLA ADDR`
pub fn calla(addr: u32) u32 {
    std.debug.assert(addr <= util.addr_mask);
    return formatJ(.calla, addr);
}
pub fn ret() u32 {
    return formatR(.ret, 0, 0, 0);
}

// ---------------------------------------------------------------------------
// Stack.
// ---------------------------------------------------------------------------

/// `PUSH RA`
pub fn push(ra: u4) u32 {
    return formatR(.push, 0, ra, 0);
}
/// `POP RD`
pub fn pop(rd: u4) u32 {
    return formatR(.pop, rd, 0, 0);
}
pub fn pusha() u32 {
    return formatR(.pusha, 0, 0, 0);
}
pub fn popa() u32 {
    return formatR(.popa, 0, 0, 0);
}

// ---------------------------------------------------------------------------
// System.
// ---------------------------------------------------------------------------

pub fn nop() u32 {
    return formatR(.nop, 0, 0, 0);
}
pub fn hlt() u32 {
    return formatR(.hlt, 0, 0, 0);
}
pub fn rti() u32 {
    return formatR(.rti, 0, 0, 0);
}
pub fn sei() u32 {
    return formatR(.sei, 0, 0, 0);
}
pub fn cli() u32 {
    return formatR(.cli, 0, 0, 0);
}

/// Special register numbers for MFSR/MTSR (amendment §1.4).
pub const Sreg = enum(u4) {
    flags = 0,
    ivt = 1,
    usp = 2,
    ssp = 3,
    sys = 4,
    cyc = 5,
};

/// `MFSR RD, n` — n encoded in the RA field (§1.4).
pub fn mfsr(rd: u4, sreg: Sreg) u32 {
    return formatR(.mfsr, rd, @intFromEnum(sreg), 0);
}
/// `MTSR n, RA` — n encoded in the RD field (§1.4).
pub fn mtsr(sreg: Sreg, ra: u4) u32 {
    return formatR(.mtsr, @intFromEnum(sreg), ra, 0);
}

// ---------------------------------------------------------------------------
// Tests — exact bit vectors computed by hand from Phase 2 §2.3 + §1.3.
// The encode∘decode identity test lands with the CPU decoder (Block 3.3).
// ---------------------------------------------------------------------------

const expectEqual = std.testing.expectEqual;

test "encode: R-format field placement and reserved-zero FUNC/FLAGS" {
    // ADD R1, R2, R3: op $08 → 001000 | RD 0001 | RA 0010 | RB 0011 | 0…0
    // = 0b0010_0000_0100_1000_1100_0000_0000_0000 = $2048C000
    try expectEqual(@as(u32, 0x2048_C000), add(1, 2, 3));
    // FUNC[13:5] and FLAGS[4:0] must be zero in every R encoding (D32).
    inline for (.{
        add(15, 15, 15), sub(1, 2, 3),  @"and"(1, 2, 3), @"or"(1, 2, 3),
        xor(1, 2, 3),    not(1, 2),     shl(1, 2, 3),    shr(1, 2, 3),
        asr(1, 2, 3),    mul(1, 2, 3),  div(1, 2, 3),    mod(1, 2, 3),
        cmp(2, 3),       jmp(4),        call(4),         ret(),
        push(5),         pop(6),        pusha(),         popa(),
        nop(),           hlt(),         rti(),           sei(),
        cli(),           mfsr(1, .cyc), mtsr(.ivt, 2),
    }) |word| {
        try expectEqual(@as(u32, 0), util.extractBits(word, 0, 14)); // FUNC+FLAGS
    }
}

test "encode: hand-checked vectors across all three formats" {
    // NOP: op $38 → 111000 << 26 = $E0000000.
    try expectEqual(@as(u32, 0xE000_0000), nop());
    // HLT: op $39 → $E4000000.
    try expectEqual(@as(u32, 0xE400_0000), hlt());
    // LI R4, -1: op $05, RD=4, RA=0, IMM18=$3FFFF
    // = (5<<26)|(4<<22)|$3FFFF = $14000000|$01000000|$3FFFF = $1503FFFF.
    try expectEqual(@as(u32, 0x1503_FFFF), li(4, -1));
    // LW R1, [R2 + 4]: op $01 → (1<<26)|(1<<22)|(2<<18)|4 = $04480004.
    try expectEqual(@as(u32, 0x0448_0004), lw(1, 2, 4));
    // SW [R2 + 4], R7 — source register in the RD field:
    // (3<<26)|(7<<22)|(2<<18)|4 = $0DC80004.
    try expectEqual(@as(u32, 0x0DC8_0004), sw(2, 4, 7));
    // JMPA $FC000: op $29 → (0x29<<26)|$FC000 = $A40FC000.
    try expectEqual(@as(u32, 0xA40F_C000), jmpa(0xFC000));
    // BEQ −8 (backwards two instructions): op $20, ADDR26 = $3FFFFF8
    // = (0x20<<26)|$3FFFFF8 = $83FFFFF8.
    try expectEqual(@as(u32, 0x83FF_FFF8), beq(-8));
    // CALLA $04100 (canonical load address, D10).
    try expectEqual(@as(u32, (0x2B << 26) | 0x04100), calla(0x04100));
}

test "encode: LOAD_ADDR sequence for $40000 (amendment §1.2)" {
    // LI R1, $40000 & $FFFF = LI R1, 0 ; LUI R1, $40000 >> 16 = LUI R1, 4.
    const target: u32 = 0x40000;
    const lo = li(1, @intCast(target & 0xFFFF));
    const hi = lui(1, @intCast(target >> 16));
    // LI low half is unsigned 16-bit in the 18-bit field → sign bit clear.
    try expectEqual(@as(u32, 0), util.extractBits(lo, 0, 18));
    try expectEqual(@as(u32, 4), util.extractBits(hi, 0, 18));
    try expectEqual(@as(u32, @intFromEnum(Opcode.li)), util.extractBits(lo, 26, 6));
    try expectEqual(@as(u32, @intFromEnum(Opcode.lui)), util.extractBits(hi, 26, 6));
}

test "encode: MFSR/MTSR sreg field placement (§1.4)" {
    // MFSR RD, n — n in the RA field.
    const rd_read = mfsr(3, .cyc);
    try expectEqual(@as(u32, 3), util.extractBits(rd_read, 22, 4)); // RD
    try expectEqual(@as(u32, 5), util.extractBits(rd_read, 18, 4)); // n=CYC in RA
    // MTSR n, RA — n in the RD field.
    const sr_write = mtsr(.ssp, 7);
    try expectEqual(@as(u32, 3), util.extractBits(sr_write, 22, 4)); // n=SSP in RD
    try expectEqual(@as(u32, 7), util.extractBits(sr_write, 18, 4)); // RA
}

test "encode: immediate and offset range asserts hold at the boundaries" {
    _ = li(0, imm18_max);
    _ = li(0, imm18_min);
    _ = addi(1, 1, imm18_max);
    _ = subi(1, 1, imm18_min);
    _ = beq(pcrel26_max);
    _ = bne(pcrel26_min);
    _ = jmpa(util.addr_mask);
    // Round-trip the extremes through the raw fields.
    try expectEqual(@as(u32, 0x1FFFF), util.extractBits(li(0, imm18_max), 0, 18));
    try expectEqual(@as(u32, 0x20000), util.extractBits(li(0, imm18_min), 0, 18));
    try expectEqual(@as(u32, 0x1FF_FFFF), util.extractBits(beq(pcrel26_max), 0, 26));
    try expectEqual(@as(u32, 0x200_0000), util.extractBits(bne(pcrel26_min), 0, 26));
}

test "encode: every opcode value matches the §1.3 table" {
    try expectEqual(@as(u6, 0x01), @intFromEnum(Opcode.lw));
    try expectEqual(@as(u6, 0x06), @intFromEnum(Opcode.lui));
    try expectEqual(@as(u6, 0x08), @intFromEnum(Opcode.add));
    try expectEqual(@as(u6, 0x14), @intFromEnum(Opcode.cmp));
    try expectEqual(@as(u6, 0x18), @intFromEnum(Opcode.addi));
    try expectEqual(@as(u6, 0x1D), @intFromEnum(Opcode.cmpi));
    try expectEqual(@as(u6, 0x20), @intFromEnum(Opcode.beq));
    try expectEqual(@as(u6, 0x27), @intFromEnum(Opcode.bcc));
    try expectEqual(@as(u6, 0x28), @intFromEnum(Opcode.jmp));
    try expectEqual(@as(u6, 0x2C), @intFromEnum(Opcode.ret));
    try expectEqual(@as(u6, 0x30), @intFromEnum(Opcode.push));
    try expectEqual(@as(u6, 0x33), @intFromEnum(Opcode.popa));
    try expectEqual(@as(u6, 0x38), @intFromEnum(Opcode.nop));
    try expectEqual(@as(u6, 0x3E), @intFromEnum(Opcode.mtsr));
    try expectEqual(49, opcode_count);
}
