//! Flommodore — `tests/harness.zig` (Block 2, task 2.8).
//!
//! Headless test runner. Deterministic by construction:
//!   - no SDL — this binary never imports the `sdl3` module, so it builds
//!     and runs on machines with no display;
//!   - no wall clock and no entropy — execution is a pure function of the
//!     ROM image and `--max-cycles` (fixed seeds become relevant when the
//!     BIOS LFSR arrives in Block 12; nothing random exists yet);
//!   - `--max-cycles N` bounds the run so looping ROMs terminate.
//!
//! Usage: `harness --rom <path> [--max-cycles N] [--quiet]`
//!
//! Block 2 scope: builds the machine (RAM + ROM + bus), loads the ROM image,
//! and resolves the RESET vector through the bus — proving the whole memory
//! subsystem end-to-end on a generated image. `run()` executes CPU steps as
//! soon as cpu.zig lands (Block 3); until then it counts idle cycles so the
//! CLI contract is final now.

const std = @import("std");
const util = @import("util");
const ram_mod = @import("ram");
const rom_mod = @import("rom");
const bus_mod = @import("bus");

const reset_vector_addr: u32 = 0xFFFC0; // system vector 0 (amendment §2.1)

const Options = struct {
    rom_path: []const u8,
    max_cycles: u64 = util.cycles_per_frame, // one frame by default
    quiet: bool = false,
};

fn parseArgs(args: []const []const u8) !Options {
    var rom_path: ?[]const u8 = null;
    var opts: Options = .{ .rom_path = undefined };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--rom")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            rom_path = args[i];
        } else if (std.mem.eql(u8, arg, "--max-cycles")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.max_cycles = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else {
            return error.UnknownArgument;
        }
    }
    opts.rom_path = rom_path orelse return error.MissingRom;
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(args) catch {
        std.log.err("usage: harness --rom <path> [--max-cycles N] [--quiet]", .{});
        return error.BadUsage;
    };
    if (opts.quiet) util.setLevel(.silent);

    // Build the machine.
    const ram = try gpa.create(ram_mod.Ram);
    defer gpa.destroy(ram);
    const rom = try gpa.create(rom_mod.Rom);
    defer gpa.destroy(rom);
    ram.init();
    rom.init();
    var bus = bus_mod.Bus.init(ram, rom);

    try rom.loadFromFile(io, std.Io.Dir.cwd(), opts.rom_path);
    util.logInfo("loaded ROM: {s}", .{opts.rom_path});

    // Resolve the RESET vector through the bus — 32-bit LE, masked to
    // 20 bits when loaded (amendment §1.5).
    const lo: u32 = bus.read16(reset_vector_addr);
    const hi: u32 = bus.read16(reset_vector_addr + 2);
    const reset = util.maskAddr(lo | (hi << 16));
    util.logInfo("RESET vector → ${X:0>5}", .{reset});
    if (reset == 0) {
        // An all-zero vector means an unpopulated image; running it would
        // trap to BRK immediately (D35). Treat as a bad image in Block 2.
        util.logErr("RESET vector is $00000 — not a runnable image", .{});
        return error.EmptyResetVector;
    }

    // Bounded run. CPU stepping replaces this loop body in Block 3; the
    // cycle accounting (1 cycle per instruction, D17) is already correct.
    var cycles: u64 = 0;
    while (cycles < opts.max_cycles) : (cycles += 1) {
        // Block 3: cpu.step(&bus)
    }
    util.logInfo("ran {d} cycles headlessly (CPU lands in Block 3)", .{cycles});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "harness: argument parsing" {
    const o1 = try parseArgs(&.{ "harness", "--rom", "x.rom" });
    try testing.expectEqualStrings("x.rom", o1.rom_path);
    try testing.expectEqual(@as(u64, util.cycles_per_frame), o1.max_cycles);
    try testing.expect(!o1.quiet);

    const o2 = try parseArgs(&.{ "harness", "--rom", "x.rom", "--max-cycles", "1000", "--quiet" });
    try testing.expectEqual(@as(u64, 1000), o2.max_cycles);
    try testing.expect(o2.quiet);

    try testing.expectError(error.MissingRom, parseArgs(&.{"harness"}));
    try testing.expectError(error.MissingValue, parseArgs(&.{ "harness", "--rom" }));
    try testing.expectError(error.UnknownArgument, parseArgs(&.{ "harness", "--bogus" }));
}
