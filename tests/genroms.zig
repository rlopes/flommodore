//! Flommodore — `tests/genroms.zig` (Block 2, task 2.7).
//!
//! Test-ROM builders: emit `tests/roms/*.rom` — full 16KB ROM images with
//! 4-byte system vectors at `$FFFC0` (amendment D3/§2.1) — using
//! `src/encode.zig` as the single source of encoding truth (audit P1).
//!
//! Invoked as `zig build genroms`; build.zig passes the output directory as
//! argv[1] so the emitted files land in `tests/roms/` regardless of cwd.
//! The Block 3 CPU test suite adds one builder per instruction group here.

const std = @import("std");
const encode = @import("encode");
const rom = @import("rom");
const util = @import("util");

/// A 16KB ROM image under construction, addressed in machine addresses
/// (`$FC000–$FFFFF`) so builders read like memory maps, not file offsets.
pub const RomImage = struct {
    bytes: [rom.size]u8 = @splat(0),

    pub fn init() RomImage {
        return .{};
    }

    fn offsetOf(addr: u32) u32 {
        std.debug.assert(addr >= 0xFC000 and addr <= 0xFFFFF);
        return addr - 0xFC000;
    }

    /// Write one 32-bit little-endian word (instruction or DD-style data)
    /// at a machine address inside the ROM.
    pub fn writeWord32(image: *RomImage, addr: u32, word: u32) void {
        const off = offsetOf(addr);
        std.debug.assert(off + 4 <= rom.size);
        std.mem.writeInt(u32, image.bytes[off..][0..4], word, .little);
    }

    /// A code cursor: emit consecutive instructions from a start address.
    pub const Cursor = struct {
        image: *RomImage,
        addr: u32,

        pub fn emit(cur: *Cursor, word: u32) void {
            cur.image.writeWord32(cur.addr, word);
            cur.addr += 4;
        }
    };

    pub fn codeAt(image: *RomImage, addr: u32) Cursor {
        return .{ .image = image, .addr = addr };
    }

    /// Set system vector `index` (0=RESET, 1=NMI, 2=IRQ, 3=BRK, 4–15
    /// reserved) at `$FFFC0 + 4×index` — a 32-bit LE value masked to 20 bits
    /// when loaded (amendment §1.5/§2.1).
    pub fn setVector(image: *RomImage, index: u4, target: u32) void {
        std.debug.assert(target <= util.addr_mask);
        image.writeWord32(0xFFFC0 + 4 * @as(u32, index), target);
    }
};

/// nop_loop.rom — the plan 2.7 acceptance ROM. RESET vectors to $FC200
/// (the BIOS-kernel-area address, §2.1); the code is four NOPs followed by
/// a JMPA back to the start: an infinite, side-effect-free loop the harness
/// can run under `--max-cycles`.
fn buildNopLoop() RomImage {
    var image = RomImage.init();
    const entry: u32 = 0xFC200;
    image.setVector(0, entry); // RESET
    var code = image.codeAt(entry);
    code.emit(encode.nop());
    code.emit(encode.nop());
    code.emit(encode.nop());
    code.emit(encode.nop());
    code.emit(encode.jmpa(entry));
    return image;
}

const Builder = struct {
    name: []const u8,
    build: *const fn () RomImage,
};

const builders = [_]Builder{
    .{ .name = "nop_loop.rom", .build = buildNopLoop },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.log.err("usage: genroms <output-dir>", .{});
        return error.BadUsage;
    }
    const out_dir_path = args[1];

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, out_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var out_dir = try cwd.openDir(io, out_dir_path, .{});
    defer out_dir.close(io);

    for (builders) |b| {
        const image = b.build();
        var file = try out_dir.createFile(io, b.name, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, &image.bytes);
        std.log.info("wrote {s}/{s} ({d} bytes)", .{ out_dir_path, b.name, image.bytes.len });
    }
}

// ---------------------------------------------------------------------------
// Tests — the image builder itself is unit-tested; file emission is
// exercised by `zig build genroms` in CI.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "genroms: nop_loop image has vectors and code where the spec says" {
    const image = buildNopLoop();
    try testing.expectEqual(@as(usize, rom.size), image.bytes.len);
    // RESET vector at file offset $3FC0 (= $FFFC0 − $FC000), LE, → $FC200.
    const reset = std.mem.readInt(u32, image.bytes[rom.vectors_offset..][0..4], .little);
    try testing.expectEqual(@as(u32, 0xFC200), reset);
    // Remaining vectors are zero (reserved entries are defined zeros, §2.1).
    var i: u32 = 1;
    while (i < 16) : (i += 1) {
        const v = std.mem.readInt(u32, image.bytes[rom.vectors_offset + 4 * i ..][0..4], .little);
        try testing.expectEqual(@as(u32, 0), v);
    }
    // Code at $FC200 (file offset $0200): NOP ×4 then JMPA $FC200.
    const code_off = 0x0200;
    var n: u32 = 0;
    while (n < 4) : (n += 1) {
        const w = std.mem.readInt(u32, image.bytes[code_off + 4 * n ..][0..4], .little);
        try testing.expectEqual(encode.nop(), w);
    }
    const jump = std.mem.readInt(u32, image.bytes[code_off + 16 ..][0..4], .little);
    try testing.expectEqual(encode.jmpa(0xFC200), jump);
    // Everything before the entry point is zero → would trap to BRK (D35),
    // never execute silently.
    try testing.expectEqual(@as(u8, 0), image.bytes[0]);
}
