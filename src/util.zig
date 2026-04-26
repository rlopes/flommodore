//! util.zig — Shared helpers for the Flommodore emulator.
//!
//! Covers:
//!   • sign_extend   — widen a narrow signed value to a larger integer type
//!   • Bit manipulation — extract, set, clear, test individual bits and fields
//!   • Logging        — lightweight compile-time-filtered log macros
//!
//! All functions are pure / no side effects unless noted.

const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// Sign extension
// ─────────────────────────────────────────────────────────────────────────────

/// Extend the `from_bits`-wide signed integer stored in the low bits of `value`
/// to a full `T`.
///
/// Example:
///   sign_extend(u32, 0b1111_0000, 8) == 0xFFFF_FFF0  (0xF0 treated as -16)
///   sign_extend(u32, 0b0111_0000, 8) == 0x0000_0070  (0x70 treated as +112)
pub fn sign_extend(comptime T: type, value: T, from_bits: u5) T {
    comptime {
        const info = @typeInfo(T);
        if (info != .int) @compileError("sign_extend: T must be an integer type");
    }
    const shift: u5 = @as(u5, @intCast(@typeInfo(T).int.bits)) - from_bits;
    // Arithmetic shift: cast to the signed peer, shift left then right.
    const Signed = std.meta.Int(.signed, @typeInfo(T).int.bits);
    const as_signed: Signed = @bitCast(value);
    return @bitCast((as_signed << shift) >> shift);
}

// ─────────────────────────────────────────────────────────────────────────────
// Bit extraction / manipulation
// ─────────────────────────────────────────────────────────────────────────────

/// Extract a single bit at position `bit` (0 = LSB).
pub inline fn bit_get(value: anytype, bit: u5) u1 {
    return @truncate((value >> bit) & 1);
}

/// Return true if bit `bit` is set.
pub inline fn bit_set(value: anytype, bit: u5) bool {
    return bit_get(value, bit) != 0;
}

/// Set bit `bit` in `value` (returns modified copy).
pub inline fn bit_set_val(comptime T: type, value: T, bit: u5) T {
    return value | (@as(T, 1) << bit);
}

/// Clear bit `bit` in `value` (returns modified copy).
pub inline fn bit_clear(comptime T: type, value: T, bit: u5) T {
    return value & ~(@as(T, 1) << bit);
}

/// Toggle bit `bit` in `value` (returns modified copy).
pub inline fn bit_toggle(comptime T: type, value: T, bit: u5) T {
    return value ^ (@as(T, 1) << bit);
}

/// Extract a contiguous bit field from `value`.
///
///   bit_field(u32, 0b1101_0110, lo=2, width=3) → 0b101 (bits 4:2)
pub inline fn bit_field(comptime T: type, value: T, lo: u5, width: u5) T {
    const mask: T = (@as(T, 1) << width) - 1;
    return (value >> lo) & mask;
}

/// Mask a value to 20 bits (Gab-16 address bus width).
pub inline fn mask20(value: u32) u20 {
    return @truncate(value & 0x000F_FFFF);
}

/// Mask a value to 16 bits (Gab-16 data width).
pub inline fn mask16(value: u32) u16 {
    return @truncate(value & 0x0000_FFFF);
}

// ─────────────────────────────────────────────────────────────────────────────
// Byte / word helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Read a little-endian 16-bit word from two consecutive bytes.
pub inline fn read_u16_le(hi: u8, lo: u8) u16 {
    return @as(u16, hi) << 8 | lo;
}

/// Split a 16-bit word into (lo, hi) byte pair (little-endian).
pub inline fn split_u16_le(word: u16) struct { lo: u8, hi: u8 } {
    return .{ .lo = @truncate(word), .hi = @truncate(word >> 8) };
}

// ─────────────────────────────────────────────────────────────────────────────
// Logging
// ─────────────────────────────────────────────────────────────────────────────
//
// Thin wrappers around std.log so that every module can call
//   util.log.debug("cpu: fetch @ ${X:0>5}", .{addr});
// and it will be silenced in ReleaseFast/ReleaseSmall builds.
//
// Log scopes keep output attributable to the correct subsystem.

pub const log = std.log.scoped(.flommodore);

/// Subsystem-scoped loggers — import these in each module:
///
///   const log = util.log_cpu;
pub const log_cpu     = std.log.scoped(.cpu);
pub const log_bus     = std.log.scoped(.bus);
pub const log_vic     = std.log.scoped(.vic256);
pub const log_aur     = std.log.scoped(.aur1);
pub const log_io      = std.log.scoped(.io);
pub const log_rom     = std.log.scoped(.rom);
pub const log_ram     = std.log.scoped(.ram);
pub const log_dbg     = std.log.scoped(.debugger);

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

test "sign_extend — positive value, 8→32" {
    // 0x70 = 0111_0000, top bit 0 ⇒ positive ⇒ zero-extended
    const result = sign_extend(u32, 0x70, 8);
    try std.testing.expectEqual(@as(u32, 0x0000_0070), result);
}

test "sign_extend — negative value, 8→32" {
    // 0xF0 = 1111_0000, top bit 1 ⇒ negative ⇒ sign-extended
    const result = sign_extend(u32, 0xF0, 8);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF0), result);
}

test "sign_extend — negative value, 5→16 (branch offsets)" {
    // 5-bit field, value = 0b1_1110 = 30 decimal, but signed = -2
    const result = sign_extend(u16, 0b1_1110, 5);
    try std.testing.expectEqual(@as(u16, 0xFFFE), result);
}

test "sign_extend — positive value, 5→16" {
    // 5-bit field, value = 0b0_1110 = 14 (positive)
    const result = sign_extend(u16, 0b0_1110, 5);
    try std.testing.expectEqual(@as(u16, 14), result);
}

test "sign_extend — all-ones 8-bit is -1 in u32" {
    const result = sign_extend(u32, 0xFF, 8);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), result);
}

test "bit_get — LSB" {
    try std.testing.expectEqual(@as(u1, 1), bit_get(@as(u8, 0b0000_0001), 0));
    try std.testing.expectEqual(@as(u1, 0), bit_get(@as(u8, 0b0000_0010), 0));
}

test "bit_get — MSB of u8" {
    try std.testing.expectEqual(@as(u1, 1), bit_get(@as(u8, 0b1000_0000), 7));
    try std.testing.expectEqual(@as(u1, 0), bit_get(@as(u8, 0b0111_1111), 7));
}

test "bit_set returns true for set bit" {
    try std.testing.expect(bit_set(@as(u8, 0b0000_0100), 2));
    try std.testing.expect(!bit_set(@as(u8, 0b1111_1011), 2));
}

test "bit_set_val — set bit 3 in u8" {
    const v = bit_set_val(u8, 0b0000_0000, 3);
    try std.testing.expectEqual(@as(u8, 0b0000_1000), v);
}

test "bit_clear — clear bit 3 in u8" {
    const v = bit_clear(u8, 0b1111_1111, 3);
    try std.testing.expectEqual(@as(u8, 0b1111_0111), v);
}

test "bit_toggle — toggle bit 1" {
    const v0 = bit_toggle(u8, 0b0000_0000, 1);
    try std.testing.expectEqual(@as(u8, 0b0000_0010), v0);
    const v1 = bit_toggle(u8, v0, 1);
    try std.testing.expectEqual(@as(u8, 0b0000_0000), v1);
}

test "bit_field — extract bits 4:2" {
    // value = 0b1101_0110
    //                ^^^  bits 4:2 = 101 = 5
    const v = bit_field(u8, 0b1101_0110, 2, 3);
    try std.testing.expectEqual(@as(u8, 0b101), v);
}

test "bit_field — extract full byte width" {
    const v = bit_field(u8, 0xAB, 0, 8);
    try std.testing.expectEqual(@as(u8, 0xAB), v);
}

test "mask20 — masks to 20 bits" {
    try std.testing.expectEqual(@as(u20, 0xFFFFF), mask20(0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u20, 0x12345), mask20(0xAB1_2345));
}

test "mask16 — masks to 16 bits" {
    try std.testing.expectEqual(@as(u16, 0xFFFF), mask16(0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u16, 0x1234), mask16(0xABCD_1234));
}

test "read_u16_le — little-endian reconstruction" {
    // lo byte = 0x34, hi byte = 0x12 → word = 0x1234
    try std.testing.expectEqual(@as(u16, 0x1234), read_u16_le(0x12, 0x34));
}

test "split_u16_le — round-trip" {
    const word: u16 = 0xBEEF;
    const parts = split_u16_le(word);
    try std.testing.expectEqual(@as(u8, 0xEF), parts.lo);
    try std.testing.expectEqual(@as(u8, 0xBE), parts.hi);
}
