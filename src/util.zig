//! Flommodore — `util.zig` (Block 1, task 1.4).
//!
//! Shared helpers: sign extension, 20-bit address masking, 32-bit
//! instruction-word bit-field access, timing constants, and a small
//! levelled logging facility (silenceable for the Block 2 headless mode).
//!
//! Spec references use the LOCKED v1.1 amendment (`flommodore-spec-amendment-v1_1.md`),
//! which supersedes the v1.0 phase documents.

const std = @import("std");

// ---------------------------------------------------------------------------
// Timing (spec amendment D16/D17; audit E21/G16).
// ---------------------------------------------------------------------------

/// Master clock — 14,400,000 Hz exactly (D16).
pub const master_clock_hz: u32 = 14_400_000;

/// Display refresh — 60 Hz (Phase 3 / D18).
pub const frame_rate_hz: u32 = 60;

/// Cycles per frame: 14.4 MHz / 60 Hz = 240,000 exactly (audit E21/G16).
pub const cycles_per_frame: u32 = master_clock_hz / frame_rate_hz;

comptime {
    // The division must be exact and must equal the normative constant.
    std.debug.assert(master_clock_hz % frame_rate_hz == 0);
    std.debug.assert(cycles_per_frame == 240_000);
}

// ---------------------------------------------------------------------------
// Addresses (spec amendment §1.7: bus wraps at $FFFFF).
// ---------------------------------------------------------------------------

/// The Gab-16 address bus is 20 bits wide; addresses wrap at $FFFFF (§1.7).
pub const addr_mask: u32 = 0xFFFFF;

/// Mask a value to the 20-bit address space. `$FFFFF + 1 → $00000` (§1.7).
pub fn maskAddr(addr: u32) u32 {
    return addr & addr_mask;
}

// ---------------------------------------------------------------------------
// Sign extension.
//
// Needed for (LOCKED v1.1 opcode/format tables, amendment §1.2/§1.3):
//   - IMM18: I-format 18-bit signed immediate (LI sign-extends 18 → 20 bits)
//   - ADDR26: J-format 26-bit field, sign-extended for PC-relative branches
//     (`target = PC_next + sext26(ADDR26)`)
// ---------------------------------------------------------------------------

/// Sign-extend the low `from_bits` bits of `value` to a full u32
/// (two's complement). Bits of `value` at or above `from_bits` are ignored.
pub fn signExtend(value: u32, comptime from_bits: u6) u32 {
    comptime std.debug.assert(from_bits >= 1 and from_bits <= 32);
    const shift: u5 = @intCast(32 - @as(u32, from_bits));
    const shifted: i32 = @bitCast(value << shift);
    return @bitCast(shifted >> shift);
}

// ---------------------------------------------------------------------------
// Instruction-word bit fields.
//
// All Gab-16 instructions are exactly 32 bits (Phase 2 §2.3, unchanged by
// v1.1). These generic extract/insert helpers back the concrete field
// accessors that land in encode.zig (Block 2).
// ---------------------------------------------------------------------------

/// Extract `width` bits starting at bit `lsb` (little-endian bit numbering,
/// bit 0 = least significant) from a 32-bit instruction word.
pub fn extractBits(word: u32, comptime lsb: u5, comptime width: u6) u32 {
    comptime std.debug.assert(width >= 1 and width <= 32);
    comptime std.debug.assert(@as(u32, lsb) + width <= 32);
    const mask: u32 = if (width == 32) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(width)) - 1;
    return (word >> lsb) & mask;
}

/// Insert the low `width` bits of `value` into `word` at bit `lsb`,
/// returning the new word. Bits of `value` above `width` are ignored.
pub fn insertBits(word: u32, comptime lsb: u5, comptime width: u6, value: u32) u32 {
    comptime std.debug.assert(width >= 1 and width <= 32);
    comptime std.debug.assert(@as(u32, lsb) + width <= 32);
    const mask: u32 = if (width == 32) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(width)) - 1;
    return (word & ~(mask << lsb)) | ((value & mask) << lsb);
}

// ---------------------------------------------------------------------------
// Logging.
//
// A thin levelled logger writing to stderr. `setLevel(.silent)` mutes all
// output — required by the Block 2 headless/determinism mode (task 2.8).
// ---------------------------------------------------------------------------

pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    /// No output at all (headless mode).
    silent = 4,
};

var current_level: LogLevel = .info;

pub fn setLevel(level: LogLevel) void {
    current_level = level;
}

pub fn getLevel() LogLevel {
    return current_level;
}

fn logAt(comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    comptime std.debug.assert(level != .silent); // .silent is a threshold, not a message level
    if (@intFromEnum(level) < @intFromEnum(current_level)) return;
    std.debug.print("[" ++ @tagName(level) ++ "] " ++ fmt ++ "\n", args);
}

pub fn logDebug(comptime fmt: []const u8, args: anytype) void {
    logAt(.debug, fmt, args);
}
pub fn logInfo(comptime fmt: []const u8, args: anytype) void {
    logAt(.info, fmt, args);
}
pub fn logWarn(comptime fmt: []const u8, args: anytype) void {
    logAt(.warn, fmt, args);
}
pub fn logErr(comptime fmt: []const u8, args: anytype) void {
    logAt(.err, fmt, args);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expectEqual = std.testing.expectEqual;

test "signExtend: 18-bit immediates (IMM18, LI semantics)" {
    // Sign bit clear: value unchanged.
    try expectEqual(@as(u32, 0x00000), signExtend(0x00000, 18));
    try expectEqual(@as(u32, 0x1FFFF), signExtend(0x1FFFF, 18)); // +131071 (max)
    // Sign bit (bit 17) set: extends through bit 31.
    try expectEqual(@as(u32, 0xFFFF_FFFF), signExtend(0x3FFFF, 18)); // -1
    try expectEqual(@as(u32, 0xFFFE_0000), signExtend(0x20000, 18)); // -131072 (min)
    // LI masks the extension to 20 bits (amendment §1.2): -1 → $FFFFF.
    try expectEqual(@as(u32, 0xFFFFF), maskAddr(signExtend(0x3FFFF, 18)));
    // Junk above the field is ignored.
    try expectEqual(@as(u32, 0x00001), signExtend(0xFFFC_0001, 18));
}

test "signExtend: 26-bit branch offsets (ADDR26, PCREL)" {
    try expectEqual(@as(u32, 0x1FF_FFFF), signExtend(0x1FF_FFFF, 26)); // max positive
    try expectEqual(@as(u32, 0xFFFF_FFFF), signExtend(0x3FF_FFFF, 26)); // -1
    try expectEqual(@as(u32, 0xFE00_0000), signExtend(0x200_0000, 26)); // min negative
    // Branch arithmetic wraps in the 20-bit space: PC_next=0 + (-4) → $FFFFC.
    const pc_next: u32 = 0;
    const offset = signExtend(0x3FF_FFFC, 26); // -4
    try expectEqual(@as(u32, 0xFFFFC), maskAddr(pc_next +% offset));
}

test "signExtend: width edge cases (1 and 32)" {
    // Width 1: bit 0 is the sign bit.
    try expectEqual(@as(u32, 0), signExtend(0, 1));
    try expectEqual(@as(u32, 0xFFFF_FFFF), signExtend(1, 1));
    // Full width: identity.
    try expectEqual(@as(u32, 0xDEAD_BEEF), signExtend(0xDEAD_BEEF, 32));
    try expectEqual(@as(u32, 0x0000_0000), signExtend(0x0000_0000, 32));
}

test "maskAddr: 20-bit wrap at $FFFFF" {
    try expectEqual(@as(u32, 0x00000), maskAddr(0x100000)); // $FFFFF + 1 → $00000
    try expectEqual(@as(u32, 0xFFFFF), maskAddr(0xFFFFF));
    try expectEqual(@as(u32, 0x04100), maskAddr(0x04100)); // canonical load address (D10)
    try expectEqual(@as(u32, 0x00001), maskAddr(0xFFF0_0001));
}

test "extractBits: v1.1 instruction field layout" {
    // R-format (Phase 2 §2.3): OPCODE[31:26] RD[25:22] RA[21:18] RB[17:14]
    //                          FUNC[13:5] FLAGS[4:0]
    // Construct ADD R1, R2, R3 → opcode $08, RD=1, RA=2, RB=3, FUNC=FLAGS=0.
    const word: u32 = (0x08 << 26) | (1 << 22) | (2 << 18) | (3 << 14);
    try expectEqual(@as(u32, 0x08), extractBits(word, 26, 6)); // OPCODE
    try expectEqual(@as(u32, 1), extractBits(word, 22, 4)); // RD
    try expectEqual(@as(u32, 2), extractBits(word, 18, 4)); // RA
    try expectEqual(@as(u32, 3), extractBits(word, 14, 4)); // RB
    try expectEqual(@as(u32, 0), extractBits(word, 5, 9)); // FUNC (reserved-zero)
    try expectEqual(@as(u32, 0), extractBits(word, 0, 5)); // FLAGS (reserved-zero)
    // I-format IMM18 is bits [17:0]; J-format ADDR26 is bits [25:0].
    const li: u32 = (0x05 << 26) | (4 << 22) | (0 << 18) | 0x2ABCD;
    try expectEqual(@as(u32, 0x2ABCD), extractBits(li, 0, 18));
    const jmpa: u32 = (0x29 << 26) | 0x123_4567;
    try expectEqual(@as(u32, 0x123_4567), extractBits(jmpa, 0, 26));
}

test "insertBits: round-trips with extractBits" {
    var word: u32 = 0;
    word = insertBits(word, 26, 6, 0x14); // CMP opcode
    word = insertBits(word, 18, 4, 0xA); // RA = R10
    word = insertBits(word, 14, 4, 0xB); // RB = R11
    try expectEqual(@as(u32, 0x14), extractBits(word, 26, 6));
    try expectEqual(@as(u32, 0xA), extractBits(word, 18, 4));
    try expectEqual(@as(u32, 0xB), extractBits(word, 14, 4));
    // Overwriting a field replaces it without touching neighbours.
    word = insertBits(word, 18, 4, 0x5);
    try expectEqual(@as(u32, 0x5), extractBits(word, 18, 4));
    try expectEqual(@as(u32, 0x14), extractBits(word, 26, 6));
    try expectEqual(@as(u32, 0xB), extractBits(word, 14, 4));
    // Excess bits in the inserted value are ignored.
    word = insertBits(word, 22, 4, 0xFFFF_FFF7);
    try expectEqual(@as(u32, 0x7), extractBits(word, 22, 4));
    // Full-width insert/extract.
    try expectEqual(@as(u32, 0xCAFE_F00D), extractBits(insertBits(0, 0, 32, 0xCAFE_F00D), 0, 32));
}

test "logging: level threshold and silence" {
    const saved = getLevel();
    defer setLevel(saved);
    setLevel(.silent);
    // Must be a no-op (and must compile for every message level).
    logDebug("unseen {d}", .{1});
    logInfo("unseen {d}", .{2});
    logWarn("unseen {d}", .{3});
    logErr("unseen {d}", .{4});
    try expectEqual(LogLevel.silent, getLevel());
}
