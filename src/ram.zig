//! Flommodore — `ram.zig` (Block 2, task 2.1).
//!
//! The 512KB flat RAM array backing bus region `$00000–$7FFFF` (Phase 1 §1.2).
//! This single array covers both general RAM (`$00000–$3FFFF`) and VRAM
//! (`$40000–$7FFFF`) — the VIC-256 (Block 6) reads VRAM straight out of it.
//! The top 16KB of general RAM (`$3C000–$3FFFF`) doubles as the fixed ROM
//! shadow window (amendment D9); the mapping itself lives in `bus.zig`.

const std = @import("std");

/// RAM size: 512 KB (Phase 1 §1.2 — 256KB general + 256KB VRAM).
pub const size: u32 = 512 * 1024;

pub const Ram = struct {
    data: [size]u8,

    /// Power-on state: all zeros. (A `$0000 0000` instruction word traps to
    /// BRK per D35, so cleared RAM can never execute silently.)
    pub fn init(ram: *Ram) void {
        @memset(&ram.data, 0);
    }

    /// `offset` is the RAM-relative offset, already routed and range-checked
    /// by the bus (`< size`). Asserted here to catch bus bugs in Debug builds.
    pub fn readByte(ram: *const Ram, offset: u32) u8 {
        std.debug.assert(offset < size);
        return ram.data[offset];
    }

    pub fn writeByte(ram: *Ram, offset: u32, value: u8) void {
        std.debug.assert(offset < size);
        ram.data[offset] = value;
    }
};

const testing = std.testing;

test "ram: init zeroes, contents round-trip, bounds" {
    const ram = try testing.allocator.create(Ram);
    defer testing.allocator.destroy(ram);
    ram.init();

    try testing.expectEqual(@as(u8, 0), ram.readByte(0));
    try testing.expectEqual(@as(u8, 0), ram.readByte(size - 1));

    ram.writeByte(0, 0xAA);
    ram.writeByte(size - 1, 0x55);
    ram.writeByte(0x3C000, 0x11); // shadow window base
    ram.writeByte(0x40000, 0x22); // VRAM base
    try testing.expectEqual(@as(u8, 0xAA), ram.readByte(0));
    try testing.expectEqual(@as(u8, 0x55), ram.readByte(size - 1));
    try testing.expectEqual(@as(u8, 0x11), ram.readByte(0x3C000));
    try testing.expectEqual(@as(u8, 0x22), ram.readByte(0x40000));
}
