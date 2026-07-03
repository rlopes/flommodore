//! Flommodore — `rom.zig` (Block 2, task 2.2).
//!
//! The 16KB ROM image mapped at `$FC000–$FFFFF` (Phase 1 §1.2). Holds the
//! BIOS in the real machine and generated test images under the harness.
//! Reads outside the image return `$00` per byte (task 2.2: out-of-range
//! reads return `$0000`); writes never reach here — the bus ignores writes
//! to non-shadowed ROM (amendment §1.7).

const std = @import("std");

/// ROM size: 16 KB (Phase 1 §1.2).
pub const size: u32 = 16 * 1024;

/// ROM system vectors live at `$FFFC0–$FFFFF` (amendment D3/§2.1), i.e. at
/// this offset within the image: `$FFFC0 - $FC000 = $3FC0`.
pub const vectors_offset: u32 = 0x3FC0;

pub const Rom = struct {
    data: [size]u8,

    /// Power-on state without an image: all zeros (an all-zero vector/word
    /// traps to BRK per D35 rather than executing silently).
    pub fn init(rom: *Rom) void {
        @memset(&rom.data, 0);
    }

    /// Load an image from memory. Images shorter than 16KB are zero-padded;
    /// longer images are rejected.
    pub fn loadFromSlice(rom: *Rom, image: []const u8) error{RomImageTooLarge}!void {
        if (image.len > size) return error.RomImageTooLarge;
        @memset(&rom.data, 0);
        @memcpy(rom.data[0..image.len], image);
    }

    /// Load an image from a file (emulator `--rom` path / harness).
    pub fn loadFromFile(
        rom: *Rom,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
    ) !void {
        var buffer: [size]u8 = undefined;
        var file = try dir.openFile(io, path, .{});
        defer file.close(io);
        var file_reader = file.reader(io, &.{});
        const n = file_reader.interface.readSliceShort(&buffer) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
        };
        // Reject trailing bytes beyond 16KB.
        if (n == size) {
            var probe: [1]u8 = undefined;
            if (try file_reader.interface.readSliceShort(&probe) != 0) return error.RomImageTooLarge;
        }
        try rom.loadFromSlice(buffer[0..n]);
    }

    /// Range-checked read: offsets past the image return `$00`.
    pub fn readByte(rom: *const Rom, offset: u32) u8 {
        if (offset >= size) return 0x00;
        return rom.data[offset];
    }
};

const testing = std.testing;

test "rom: load, range-checked reads, oversize rejection" {
    const rom = try testing.allocator.create(Rom);
    defer testing.allocator.destroy(rom);
    rom.init();
    try testing.expectEqual(@as(u8, 0), rom.readByte(0));

    // Short image is zero-padded.
    try rom.loadFromSlice(&.{ 0xDE, 0xAD, 0xBE, 0xEF });
    try testing.expectEqual(@as(u8, 0xDE), rom.readByte(0));
    try testing.expectEqual(@as(u8, 0xEF), rom.readByte(3));
    try testing.expectEqual(@as(u8, 0x00), rom.readByte(4));
    try testing.expectEqual(@as(u8, 0x00), rom.readByte(size - 1));

    // Out-of-range reads return $00 (→ $0000 for a 16-bit access).
    try testing.expectEqual(@as(u8, 0x00), rom.readByte(size));
    try testing.expectEqual(@as(u8, 0x00), rom.readByte(0xFFFF_FFFF));

    // Oversize image rejected, previous contents preserved.
    const too_big = try testing.allocator.alloc(u8, size + 1);
    defer testing.allocator.free(too_big);
    @memset(too_big, 0xFF);
    try testing.expectError(error.RomImageTooLarge, rom.loadFromSlice(too_big));
    try testing.expectEqual(@as(u8, 0xDE), rom.readByte(0));

    // Exactly-16KB image accepted; vectors offset addressable.
    const exact = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(exact);
    @memset(exact, 0x00);
    exact[vectors_offset] = 0x42; // RESET vector low byte
    try rom.loadFromSlice(exact);
    try testing.expectEqual(@as(u8, 0x42), rom.readByte(vectors_offset));
}
