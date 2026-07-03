//! Flommodore — `flapp.zig` (Block 5, task 5.5).
//!
//! The `.flapp` executable format, v1.1 header (amendment v1.1 §8.2 /
//! Phase 8 §8.6). This module is the single source of format truth: the
//! emulator and harness load through it now; the `fll` linker (Block 11)
//! writes through it. (Layout note: added beyond the Block 1 file list —
//! a shared reader/writer has no natural home in any existing module.)
//!
//! ```
//! +00  2 B   Magic bytes 'F','B' ($46, $42)
//! +02  2 B   Program version
//! +04  2 B   Entry point offset from file start (≥ 12)
//! +06  2 B   Minimum RAM required (KB)
//! +08  4 B   Load address (little-endian, masked to 20 bits)
//! +0C  N B   Raw binary
//! ```
//!
//! The file image — **header and payload** — is loaded verbatim at the load
//! address; execution begins at `load_address + entry_offset`. All fields
//! little-endian; the magic is normatively a byte *sequence* (§8.2).

const std = @import("std");
const util = @import("util");
const bus_mod = @import("bus");

pub const header_size: usize = 12;
pub const magic = [2]u8{ 'F', 'B' }; // $46, $42

pub const Header = struct {
    version: u16,
    entry_offset: u16,
    min_ram_kb: u16,
    load_addr: u32,
};

pub const ParseError = error{
    FileTooShort,
    BadMagic,
    /// Entry offset < 12 would point into (or before) the header.
    BadEntryOffset,
    /// Entry offset beyond the end of the file image.
    EntryOutsideImage,
};

pub const LoadError = ParseError || error{
    /// min-RAM field exceeds the machine's 512KB.
    InsufficientRam,
    /// load_addr + file length crosses out of the RAM region — loading
    /// would poke I/O registers or vanish into open bus.
    ImageOutsideRam,
};

pub fn parseHeader(bytes: []const u8) ParseError!Header {
    if (bytes.len < header_size) return error.FileTooShort;
    if (bytes[0] != magic[0] or bytes[1] != magic[1]) return error.BadMagic;
    const h = Header{
        .version = std.mem.readInt(u16, bytes[2..4], .little),
        .entry_offset = std.mem.readInt(u16, bytes[4..6], .little),
        .min_ram_kb = std.mem.readInt(u16, bytes[6..8], .little),
        .load_addr = util.maskAddr(std.mem.readInt(u32, bytes[8..12], .little)),
    };
    if (h.entry_offset < header_size) return error.BadEntryOffset;
    if (h.entry_offset >= bytes.len) return error.EntryOutsideImage;
    return h;
}

/// Serialise a header (Block 11: the linker's autoboot header injection).
pub fn writeHeader(buf: *[header_size]u8, h: Header) void {
    buf[0] = magic[0];
    buf[1] = magic[1];
    std.mem.writeInt(u16, buf[2..4], h.version, .little);
    std.mem.writeInt(u16, buf[4..6], h.entry_offset, .little);
    std.mem.writeInt(u16, buf[6..8], h.min_ram_kb, .little);
    std.mem.writeInt(u32, buf[8..12], h.load_addr, .little);
}

/// Load a `.flapp` image into the machine through the bus and return the
/// entry address. The whole file (header included) lands verbatim at
/// `load_addr` (§8.6).
pub fn load(bus: *bus_mod.Bus, bytes: []const u8) LoadError!u32 {
    const h = try parseHeader(bytes);
    if (@as(u32, h.min_ram_kb) * 1024 > 512 * 1024) return error.InsufficientRam;
    if (h.load_addr + bytes.len > bus_mod.ram_end + 1) return error.ImageOutsideRam;
    for (bytes, 0..) |byte, i| {
        bus.write8(h.load_addr + @as(u32, @intCast(i)), byte);
    }
    return util.maskAddr(h.load_addr + h.entry_offset);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ram_mod = @import("ram");
const rom_mod = @import("rom");
const io_mod = @import("io");

test "flapp: header round-trip and field layout" {
    var buf: [header_size]u8 = undefined;
    writeHeader(&buf, .{
        .version = 3,
        .entry_offset = 12,
        .min_ram_kb = 64,
        .load_addr = 0x04100,
    });
    // Byte sequence per §8.2: 'F','B', then LE fields.
    try testing.expectEqualSlices(u8, &.{ 'F', 'B', 3, 0, 12, 0, 64, 0, 0x00, 0x41, 0x00, 0x00 }, &buf);
    var file: [16]u8 = undefined;
    @memcpy(file[0..12], &buf);
    @memset(file[12..], 0xEE);
    const h = try parseHeader(&file);
    try testing.expectEqual(@as(u16, 3), h.version);
    try testing.expectEqual(@as(u16, 12), h.entry_offset);
    try testing.expectEqual(@as(u16, 64), h.min_ram_kb);
    try testing.expectEqual(@as(u32, 0x04100), h.load_addr);
}

test "flapp: parse rejections" {
    var buf: [header_size]u8 = undefined;
    try testing.expectError(error.FileTooShort, parseHeader(buf[0..4]));
    writeHeader(&buf, .{ .version = 1, .entry_offset = 12, .min_ram_kb = 0, .load_addr = 0 });
    buf[0] = 'X';
    try testing.expectError(error.BadMagic, parseHeader(&buf));
    writeHeader(&buf, .{ .version = 1, .entry_offset = 8, .min_ram_kb = 0, .load_addr = 0 });
    var file: [20]u8 = @splat(0);
    @memcpy(file[0..12], &buf);
    try testing.expectError(error.BadEntryOffset, parseHeader(&file));
    writeHeader(&buf, .{ .version = 1, .entry_offset = 40, .min_ram_kb = 0, .load_addr = 0 });
    @memcpy(file[0..12], &buf);
    try testing.expectError(error.EntryOutsideImage, parseHeader(&file));
}

test "flapp: loads verbatim through the bus; entry computed; range-checked" {
    const ram = try testing.allocator.create(ram_mod.Ram);
    defer testing.allocator.destroy(ram);
    const rom = try testing.allocator.create(rom_mod.Rom);
    defer testing.allocator.destroy(rom);
    const io = try testing.allocator.create(io_mod.Io);
    defer testing.allocator.destroy(io);
    ram.init();
    rom.init();
    io.* = io_mod.Io.init();
    var bus = bus_mod.Bus.init(ram, rom, io);

    var file: [header_size + 8]u8 = undefined;
    writeHeader(file[0..header_size], .{
        .version = 1,
        .entry_offset = 12,
        .min_ram_kb = 4,
        .load_addr = 0x04100, // canonical autoboot address (D10)
    });
    const payload = [8]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    @memcpy(file[header_size..], &payload);

    const entry = try load(&bus, &file);
    try testing.expectEqual(@as(u32, 0x0410C), entry);
    // Verbatim: header bytes land at the load address, payload after.
    try testing.expectEqual(@as(u8, 'F'), bus.read8(0x04100));
    try testing.expectEqual(@as(u8, 'B'), bus.read8(0x04101));
    try testing.expectEqual(@as(u8, 0x11), bus.read8(0x0410C));
    try testing.expectEqual(@as(u8, 0x88), bus.read8(0x04113));

    // min-RAM beyond the machine.
    writeHeader(file[0..header_size], .{ .version = 1, .entry_offset = 12, .min_ram_kb = 513, .load_addr = 0x04100 });
    try testing.expectError(error.InsufficientRam, load(&bus, &file));
    // Image that would spill past RAM into the I/O region.
    writeHeader(file[0..header_size], .{ .version = 1, .entry_offset = 12, .min_ram_kb = 0, .load_addr = 0x7FFF8 });
    try testing.expectError(error.ImageOutsideRam, load(&bus, &file));
}
