//! ram.zig — 512KB flat RAM.
//!
//! The Flommodore has a single 512KB RAM array shared between general RAM and VRAM.
//!
//!   $00000 – $3FFFF   256KB   General RAM
//!   $40000 – $7FFFF   256KB   VIC-256 VRAM
//!
//! Byte order: little-endian — low byte at lower address.
//! Unaligned word accesses are permitted (no bus fault).
//!
//! Implemented in Block 2.1.

const std = @import("std");

pub const RAM_SIZE: u32 = 512 * 1024; // 0x80000

var data: [RAM_SIZE]u8 = std.mem.zeroes([RAM_SIZE]u8);

/// Reset all RAM to zero.
pub fn reset() void {
    @memset(&data, 0);
}

// ---------------------------------------------------------------------------
// Byte access
// ---------------------------------------------------------------------------

pub fn read_byte(addr: u32) u8 {
    std.debug.assert(addr < RAM_SIZE);
    return data[addr];
}

pub fn write_byte(addr: u32, value: u8) void {
    std.debug.assert(addr < RAM_SIZE);
    data[addr] = value;
}

// ---------------------------------------------------------------------------
// Word (16-bit) access — little-endian
// ---------------------------------------------------------------------------

pub fn read_u16(addr: u32) u16 {
    std.debug.assert(addr + 1 < RAM_SIZE);
    // Low byte at addr, high byte at addr+1.
    return @as(u16, data[addr]) | (@as(u16, data[addr + 1]) << 8);
}

pub fn write_u16(addr: u32, value: u16) void {
    std.debug.assert(addr + 1 < RAM_SIZE);
    data[addr]     = @truncate(value);
    data[addr + 1] = @truncate(value >> 8);
}

// ---------------------------------------------------------------------------
// Direct slice access (for ROM load, DMA, etc.)
// ---------------------------------------------------------------------------

/// Return a mutable slice starting at addr of length len.
pub fn slice(addr: u32, len: u32) []u8 {
    std.debug.assert(addr + len <= RAM_SIZE);
    return data[addr .. addr + len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ram: reset zeroes all bytes" {
    data[0] = 0xAB;
    data[RAM_SIZE - 1] = 0xCD;
    reset();
    try std.testing.expect(data[0] == 0);
    try std.testing.expect(data[RAM_SIZE - 1] == 0);
}

test "ram: read_byte / write_byte round-trip" {
    reset();
    write_byte(0x00100, 0x42);
    try std.testing.expect(read_byte(0x00100) == 0x42);
    write_byte(0x7FFFF, 0xFF);
    try std.testing.expect(read_byte(0x7FFFF) == 0xFF);
}

test "ram: read_u16 / write_u16 little-endian byte order" {
    reset();
    // Write the value $BEEF to address $00200.
    // Expect data[$00200] == $EF, data[$00201] == $BE.
    write_u16(0x00200, 0xBEEF);
    try std.testing.expect(data[0x00200] == 0xEF);
    try std.testing.expect(data[0x00201] == 0xBE);
    try std.testing.expect(read_u16(0x00200) == 0xBEEF);
}

test "ram: unaligned word access" {
    reset();
    // Odd address — must not crash or fault.
    write_u16(0x00301, 0x1234);
    try std.testing.expect(read_u16(0x00301) == 0x1234);
    try std.testing.expect(data[0x00301] == 0x34);
    try std.testing.expect(data[0x00302] == 0x12);
}

test "ram: boundary byte — last address" {
    reset();
    write_byte(0x7FFFE, 0xAA);
    write_byte(0x7FFFF, 0xBB);
    try std.testing.expect(read_u16(0x7FFFE) == 0xBBAA);
}

test "ram: VRAM region accessible" {
    reset();
    // Write into VRAM region ($40000–$7FFFF).
    write_u16(0x40000, 0xDEAD);
    try std.testing.expect(read_u16(0x40000) == 0xDEAD);
}
