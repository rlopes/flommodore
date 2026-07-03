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
//! Block 3: steps the Gab-16 CPU for real. Extras:
//!   - `--irq-at N` (repeatable, ascending): assert the CPU IRQ line once
//!     cycle N is reached and keep it asserted until delivered — exact
//!     delivery timing is then independent of small code-length changes,
//!     keeping test ROMs deterministic but not brittle;
//!   - `--expect-pass`: enforce the test-ROM protocol — the CPU must HLT
//!     with $600D at $00080, else exit nonzero and report the failing
//!     check number from $00084.

const std = @import("std");
const util = @import("util");
const ram_mod = @import("ram");
const rom_mod = @import("rom");
const bus_mod = @import("bus");
const cpu_mod = @import("cpu");
const io_mod = @import("io");

const Options = struct {
    rom_path: []const u8,
    max_cycles: u64 = util.cycles_per_frame, // one frame by default
    quiet: bool = false,
    expect_pass: bool = false,
    irq_at: [max_irqs]u64 = undefined,
    irq_count: usize = 0,

    const max_irqs = 16;
};

/// Test-ROM result protocol addresses (see tests/genroms.zig).
const result_addr: u32 = 0x00080;
const failnum_addr: u32 = 0x00084;
const result_pass: u16 = 0x600D;

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
        } else if (std.mem.eql(u8, arg, "--expect-pass")) {
            opts.expect_pass = true;
        } else if (std.mem.eql(u8, arg, "--irq-at")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (opts.irq_count >= Options.max_irqs) return error.TooManyIrqs;
            const cycle = try std.fmt.parseInt(u64, args[i], 10);
            if (opts.irq_count > 0 and cycle <= opts.irq_at[opts.irq_count - 1])
                return error.IrqsNotAscending;
            opts.irq_at[opts.irq_count] = cycle;
            opts.irq_count += 1;
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
        std.log.err("usage: harness --rom <path> [--max-cycles N] [--irq-at N]... [--expect-pass] [--quiet]", .{});
        return error.BadUsage;
    };
    if (opts.quiet) util.setLevel(.silent);

    // Build the machine.
    const ram = try gpa.create(ram_mod.Ram);
    defer gpa.destroy(ram);
    const rom = try gpa.create(rom_mod.Rom);
    defer gpa.destroy(rom);
    const io_dev = try gpa.create(io_mod.Io);
    defer gpa.destroy(io_dev);
    ram.init();
    rom.init();
    io_dev.* = io_mod.Io.init();
    var bus = bus_mod.Bus.init(ram, rom, io_dev);

    try rom.loadFromFile(io, std.Io.Dir.cwd(), opts.rom_path);
    util.logInfo("loaded ROM: {s}", .{opts.rom_path});

    var cpu: cpu_mod.Gab16 = undefined;
    cpu.reset(&bus);
    util.logInfo("RESET → ${X:0>5}", .{cpu.pc});
    if (cpu.pc == 0) {
        // An all-zero vector means an unpopulated image; it would trap to
        // BRK through a zero IVT immediately (D35). Treat as a bad image.
        util.logErr("RESET vector is $00000 — not a runnable image", .{});
        return error.EmptyResetVector;
    }

    // Bounded, deterministic run: one instruction (or idle/delivery step)
    // per cycle (D17/D41). Ordering per cycle: sample the IRQ line, step
    // the CPU, tick the devices — so a device event in cycle k is
    // deliverable from cycle k+1 (io.zig header).
    var cycles: u64 = 0;
    var irq_idx: usize = 0;
    var injected = false;
    while (cycles < opts.max_cycles and !cpu.halted and !io_dev.power_off) : (cycles += 1) {
        if (irq_idx < opts.irq_count and cycles >= opts.irq_at[irq_idx]) {
            injected = true; // --irq-at: asserted until delivered
        }
        cpu.irq_line = io_dev.irqLine() or injected;
        const event = cpu.step(&bus);
        io_dev.tick();
        if (event == .irq_entered and injected) {
            injected = false;
            irq_idx += 1;
        }
    }
    util.logInfo("ran {d} cycles; halted={}, power_off={}, PC=${X:0>5}", .{ cycles, cpu.halted, io_dev.power_off, cpu.pc });
    if (irq_idx < opts.irq_count) {
        util.logWarn("{d} of {d} --irq-at pulses were never delivered", .{ opts.irq_count - irq_idx, opts.irq_count });
    }

    if (opts.expect_pass) {
        const result = bus.read16(result_addr);
        // A test ROM finishes by HLT or by SYSPWR soft power-off (§5.1).
        if (!cpu.halted and !io_dev.power_off) {
            util.logErr("expected HLT within {d} cycles", .{opts.max_cycles});
            return error.TestRomTimedOut;
        }
        if (result != result_pass) {
            util.logErr("test ROM failed: result=${X:0>4}, check #{d}", .{ result, bus.read16(failnum_addr) });
            return error.TestRomFailed;
        }
        util.logInfo("test ROM passed", .{});
    }
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

    const o3 = try parseArgs(&.{ "harness", "--rom", "x.rom", "--irq-at", "30", "--irq-at", "60", "--expect-pass" });
    try testing.expectEqual(@as(usize, 2), o3.irq_count);
    try testing.expectEqual(@as(u64, 30), o3.irq_at[0]);
    try testing.expectEqual(@as(u64, 60), o3.irq_at[1]);
    try testing.expect(o3.expect_pass);
    try testing.expectError(error.IrqsNotAscending, parseArgs(&.{ "harness", "--rom", "x", "--irq-at", "60", "--irq-at", "30" }));

    try testing.expectError(error.MissingRom, parseArgs(&.{"harness"}));
    try testing.expectError(error.MissingValue, parseArgs(&.{ "harness", "--rom" }));
    try testing.expectError(error.UnknownArgument, parseArgs(&.{ "harness", "--bogus" }));
}
