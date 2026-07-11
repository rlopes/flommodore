//! cmprom — Block 10 end-to-end acceptance comparator.
//!
//! Usage: cmprom <object.flobj> <original.rom>
//!
//! Reconstructs the 16KB ROM frame from an ABSOLUTE .flobj (each section
//! carries its final load address; materializing is a pair of memcpys)
//! and byte-compares it against the genroms-generated original. This is
//! TEST-ONLY scaffolding, not a second linker — fll is Block 11.
//!
//! Wired into `zig build test` (and `zig build asmtest`): genroms writes
//! tests/roms/test_cpu_alu.rom, flas assembles tests/asm/test_cpu_alu.asm,
//! and this tool must report byte identity.

const std = @import("std");
const rom = @import("rom");

const rom_base: u32 = 0xFC000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: cmprom <object.flobj> <original.rom>\n", .{});
        return error.BadUsage;
    }

    const obj = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 20));
    const orig = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(1 << 20));

    if (orig.len != rom.size) {
        std.debug.print("cmprom: {s}: expected a {d}-byte ROM image, got {d}\n", .{ args[2], rom.size, orig.len });
        return error.BadRomImage;
    }
    // .flobj v1.1 header (Phase 8 §8.4): 'F','O', version, section count,
    // symbol count u16, reloc count u16.
    if (obj.len < 8 or obj[0] != 'F' or obj[1] != 'O' or obj[2] != 1) {
        std.debug.print("cmprom: {s}: not a .flobj v1 file\n", .{args[1]});
        return error.BadObject;
    }
    const nsec: usize = obj[3];
    const nsym: usize = std.mem.readInt(u16, obj[4..6], .little);
    const nrel: usize = std.mem.readInt(u16, obj[6..8], .little);
    if (nrel != 0) {
        // Absolute-mode files fold everything (amendment §8.5).
        std.debug.print("cmprom: {s}: {d} relocations — not an absolute object\n", .{ args[1], nrel });
        return error.NotAbsolute;
    }
    const payload_base = 8 + nsec * 21 + nsym * 38;

    var image: [rom.size]u8 = @splat(0);
    for (0..nsec) |i| {
        const e = 8 + i * 21; // name 8B | type 1B | payload off 4B | size 4B | load 4B
        const poff = std.mem.readInt(u32, obj[e + 9 ..][0..4], .little);
        const size = std.mem.readInt(u32, obj[e + 13 ..][0..4], .little);
        const load = std.mem.readInt(u32, obj[e + 17 ..][0..4], .little);
        if (load < rom_base or load + size > rom_base + rom.size) {
            std.debug.print("cmprom: section {d} at ${X:0>5}+{d} falls outside the ROM window\n", .{ i, load, size });
            return error.OutOfRomWindow;
        }
        @memcpy(image[load - rom_base ..][0..size], obj[payload_base + poff ..][0..size]);
    }

    if (!std.mem.eql(u8, &image, orig)) {
        var first: usize = 0;
        while (image[first] == orig[first]) first += 1;
        std.debug.print("cmprom: MISMATCH at ROM offset ${X:0>4} (addr ${X:0>5}): got ${X:0>2}, want ${X:0>2}\n", .{ first, rom_base + first, image[first], orig[first] });
        return error.Mismatch;
    }
    std.debug.print("cmprom: {s} reconstructs byte-identically to {s} ({d} bytes)\n", .{ args[1], args[2], rom.size });
}
