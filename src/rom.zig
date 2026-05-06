//! rom.zig — 16KB ROM image.
//!
//! The ROM occupies $FC000–$FFFFF (16KB) in the address space.
//! This module holds the ROM buffer and handles byte/word reads.
//!
//! Reads beyond the 16KB buffer return $0000 (open bus behaviour).
//! Writes are always silently ignored (ROM is read-only).
//!
//! The ROM file is a raw binary loaded at startup.  If no ROM file is
//! provided (e.g. in unit tests) the buffer stays zero-filled.
//!
//! Implemented in Block 2.2.

const std = @import("std");

pub const ROM_SIZE: u32 = 16 * 1024; // 0x4000 — $FC000–$FFFFF

/// The physical ROM base address in the 20-bit address space.
pub const ROM_BASE: u32 = 0xFC000;

var data: [ROM_SIZE]u8 = std.mem.zeroes([ROM_SIZE]u8);

/// Reset ROM buffer to all zeroes (useful in tests).
pub fn reset() void {
    @memset(&data, 0);
}

/// Load a ROM binary from a file path.
/// Returns an error if the file cannot be opened or is larger than ROM_SIZE.
pub fn load(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size > ROM_SIZE) {
        return error.RomTooLarge;
    }

    @memset(&data, 0);
    const bytes_read = try file.readAll(&data);
    _ = bytes_read; // partial ROM is valid — remainder stays zero
}

/// Load ROM from a byte slice (used in tests and for embedded ROM data).
pub fn load_bytes(bytes: []const u8) !void {
    if (bytes.len > ROM_SIZE) return error.RomTooLarge;
    @memset(&data, 0);
    @memcpy(data[0..bytes.len], bytes);
}

// ---------------------------------------------------------------------------
// Read interface
//
// Callers pass a *physical* address in $FC000–$FFFFF.
// We offset by ROM_BASE to get the buffer index.
// Out-of-range addresses return 0.
// ---------------------------------------------------------------------------

pub fn read_byte(addr: u32) u8 {
    if (addr < ROM_BASE or addr >= ROM_BASE + ROM_SIZE) return 0x00;
    return data[addr - ROM_BASE];
}

pub fn read_u16(addr: u32) u16 {
    if (addr < ROM_BASE or addr + 1 >= ROM_BASE + ROM_SIZE) return 0x0000;
    const offset = addr - ROM_BASE;
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "rom: default buffer is all zeroes" {
    reset();
    try std.testing.expect(read_byte(ROM_BASE) == 0x00);
    try std.testing.expect(read_u16(ROM_BASE) == 0x0000);
}

test "rom: load_bytes and read back" {
    reset();
    const img = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    try load_bytes(&img);
    try std.testing.expect(read_byte(ROM_BASE + 0) == 0x11);
    try std.testing.expect(read_byte(ROM_BASE + 1) == 0x22);
    try std.testing.expect(read_byte(ROM_BASE + 2) == 0x33);
    try std.testing.expect(read_byte(ROM_BASE + 3) == 0x44);
}

test "rom: read_u16 little-endian" {
    reset();
    const img = [_]u8{ 0xEF, 0xBE }; // little-endian $BEEF
    try load_bytes(&img);
    try std.testing.expect(read_u16(ROM_BASE) == 0xBEEF);
}

test "rom: out-of-range read returns 0x00 / 0x0000" {
    reset();
    // Below ROM_BASE
    try std.testing.expect(read_byte(0x00000) == 0x00);
    try std.testing.expect(read_byte(0x7FFFF) == 0x00);
    // Beyond end of ROM
    try std.testing.expect(read_byte(ROM_BASE + ROM_SIZE) == 0x00);
    try std.testing.expect(read_u16(ROM_BASE + ROM_SIZE) == 0x0000);
}

test "rom: load_bytes rejects oversized image" {
    reset();
    var big: [ROM_SIZE + 1]u8 = undefined;
    @memset(&big, 0xAA);
    const result = load_bytes(&big);
    try std.testing.expectError(error.RomTooLarge, result);
}

test "rom: system vectors at expected offsets" {
    // Spec §1.6: RESET vector at $FFBC0 — offset 0x3BC0 from ROM_BASE ($FC000).
    // Just verify the offset arithmetic is correct, buffer is all-zero here.
    reset();
    const reset_offset: u32 = 0xFFBC0 - ROM_BASE; // 0x3BC0
    try std.testing.expect(reset_offset == 0x3BC0);
    try std.testing.expect(read_u16(0xFFBC0) == 0x0000);
}
