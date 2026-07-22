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
//! Usage: `harness [--rom <path>] [--flapp <path>] [--max-cycles N] [--quiet]`
//! (at least one of --rom/--flapp; both together is the §8.10 combined form)
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
const flapp_mod = @import("flapp");
const machine_mod = @import("machine");

const Options = struct {
    rom_path: ?[]const u8 = null,
    flapp_path: ?[]const u8 = null,
    max_cycles: u64 = util.cycles_per_frame, // one frame by default
    quiet: bool = false,
    /// Decision bu (mirrors the emulator): place the .flapp in RAM but let
    /// the ROM boot find it — the §6.9 autoboot path, not the PC override.
    autoboot: bool = false,
    expect_pass: bool = false,
    irq_at: [max_irqs]u64 = undefined,
    irq_count: usize = 0,
    /// Host-input injection (Block 8, cycle mode): `--key-at CYCLE:HHHH`
    /// enqueues a §5.3 scancode event word; `--joy-at CYCLE:PORT:HH` sets a
    /// §5.4 joystick state byte. Cycles ascending per list, like --irq-at.
    key_at: [max_events]KeyEvent = undefined,
    key_count: usize = 0,
    joy_at: [max_events]JoyEvent = undefined,
    joy_count: usize = 0,
    /// Frame mode (Block 6): run N full scanline-quantum frames through the
    /// shared machine loop instead of raw cycles.
    frames: u64 = 0,
    /// SHA-256 (hex) the last frame's visible RGB24 buffer must match.
    golden: ?[]const u8 = null,
    /// Write the last frame as a PPM (golden regeneration / eyeballing).
    dump_ppm: ?[]const u8 = null,
    /// SHA-256 (hex) over ALL audio samples produced during --frames.
    audio_golden: ?[]const u8 = null,
    /// Write the accumulated audio as a 44.1 kHz stereo S16 WAV.
    dump_wav: ?[]const u8 = null,

    const max_irqs = 16;
    const max_events = 16;

    const KeyEvent = struct { cycle: u64, code: u16 };
    const JoyEvent = struct { cycle: u64, port: u1, state: u8 };
};

/// Parse "CYCLE:HHHH" (key) — cycle decimal, event word hex.
fn parseKeyAt(text: []const u8) !Options.KeyEvent {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.BadFormat;
    return .{
        .cycle = try std.fmt.parseInt(u64, text[0..colon], 10),
        .code = try std.fmt.parseInt(u16, text[colon + 1 ..], 16),
    };
}

/// Parse "CYCLE:PORT:HH" (joystick) — port 1-based like the registers.
fn parseJoyAt(text: []const u8) !Options.JoyEvent {
    var it = std.mem.splitScalar(u8, text, ':');
    const cycle_s = it.next() orelse return error.BadFormat;
    const port_s = it.next() orelse return error.BadFormat;
    const state_s = it.next() orelse return error.BadFormat;
    if (it.next() != null) return error.BadFormat;
    const port = try std.fmt.parseInt(u8, port_s, 10);
    if (port < 1 or port > 2) return error.BadPort;
    return .{
        .cycle = try std.fmt.parseInt(u64, cycle_s, 10),
        .port = @intCast(port - 1),
        .state = try std.fmt.parseInt(u8, state_s, 16),
    };
}

/// Test-ROM result protocol addresses (see tests/genroms.zig).
const result_addr: u32 = 0x00080;
const failnum_addr: u32 = 0x00084;
const result_pass: u16 = 0x600D;

fn parseArgs(args: []const []const u8) !Options {
    var opts: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--rom")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.rom_path = args[i];
        } else if (std.mem.eql(u8, arg, "--flapp")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.flapp_path = args[i];
        } else if (std.mem.eql(u8, arg, "--max-cycles")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.max_cycles = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "--autoboot")) {
            opts.autoboot = true;
        } else if (std.mem.eql(u8, arg, "--expect-pass")) {
            opts.expect_pass = true;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.frames = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--golden")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.golden = args[i];
        } else if (std.mem.eql(u8, arg, "--dump-ppm")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.dump_ppm = args[i];
        } else if (std.mem.eql(u8, arg, "--audio-golden")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.audio_golden = args[i];
        } else if (std.mem.eql(u8, arg, "--dump-wav")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.dump_wav = args[i];
        } else if (std.mem.eql(u8, arg, "--key-at")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (opts.key_count >= Options.max_events) return error.TooManyEvents;
            const ev = try parseKeyAt(args[i]);
            if (opts.key_count > 0 and ev.cycle < opts.key_at[opts.key_count - 1].cycle)
                return error.EventsNotAscending;
            opts.key_at[opts.key_count] = ev;
            opts.key_count += 1;
        } else if (std.mem.eql(u8, arg, "--joy-at")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (opts.joy_count >= Options.max_events) return error.TooManyEvents;
            const ev = try parseJoyAt(args[i]);
            if (opts.joy_count > 0 and ev.cycle < opts.joy_at[opts.joy_count - 1].cycle)
                return error.EventsNotAscending;
            opts.joy_at[opts.joy_count] = ev;
            opts.joy_count += 1;
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
    if (opts.rom_path == null and opts.flapp_path == null) return error.MissingRom;
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(args) catch {
        std.log.err("usage: harness [--rom <path>] [--flapp <path>] (at least one) [--autoboot] [--max-cycles N | --frames N] [--golden HEX] [--dump-ppm f.ppm] [--irq-at N]... [--key-at C:HHHH]... [--joy-at C:P:HH]... [--expect-pass] [--quiet]", .{});
        return error.BadUsage;
    };
    if (opts.quiet) util.setLevel(.silent);

    // Build the machine — the shared composition (identical raster timing
    // to the emulator; Block 6 golden tests depend on this).
    const m = try machine_mod.Machine.create(gpa);
    defer m.destroy(gpa);
    const ram = m.ram;
    const rom = m.rom;
    const io_dev = m.io;
    const bus = &m.bus;
    _ = ram;

    const cpu = &m.cpu;
    // Load order mirrors the emulator CLI (§8.10): the ROM (if any) is in
    // place before reset; a .flapp then overrides PC. The combined form —
    // --rom font.rom --flapp hello.flapp — is how pre-BIOS programs get a
    // text-mode font (task 11.12): glyphs come from the ROM at $FE000.
    if (opts.rom_path) |path| {
        try rom.loadFromFile(io, std.Io.Dir.cwd(), path);
        util.logInfo("loaded ROM: {s}", .{path});
    }
    cpu.reset(bus);
    if (opts.flapp_path) |path| {
        // Standalone .flapp (task 5.5): same pre-BIOS environment the
        // emulator CLI provides (D12 boot values) — one loader, one truth.
        // With --autoboot (decision bu) the image is placed in RAM only
        // and the ROM boots normally: the §6.9 scan finds it at $04100.
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        const entry = try flapp_mod.load(bus, bytes);
        if (opts.autoboot) {
            if (opts.rom_path == null) {
                util.logErr("--autoboot needs a --rom to boot", .{});
                return error.AutobootWithoutRom;
            }
            util.logInfo("placed .flapp for autoboot: {s} (RESET → ${X:0>5})", .{ path, cpu.pc });
        } else {
            cpu.setReg(cpu_mod.Gab16.sp, 0x01100);
            cpu.ssp = 0x020F0;
            cpu.usp = 0x01100;
            cpu.ivt = 0xFFFC0;
            cpu.pc = entry;
            util.logInfo("loaded .flapp: {s} → entry ${X:0>5}", .{ path, entry });
        }
    } else {
        util.logInfo("RESET → ${X:0>5}", .{cpu.pc});
        if (cpu.pc == 0) {
            // An all-zero vector means an unpopulated image; it would trap
            // to BRK through a zero IVT immediately (D35).
            util.logErr("RESET vector is $00000 — not a runnable image", .{});
            return error.EmptyResetVector;
        }
    }

    var cycles: u64 = 0;
    if (opts.frames > 0) {
        // Frame mode (Block 6): whole scanline-quantum frames via the
        // shared loop. Deterministic: no wall clock, no SDL.
        var frame: u64 = 0;
        var audio_hash = std.crypto.hash.sha2.Sha256.init(.{});
        var wav_samples: std.ArrayList(i16) = .empty;
        while (frame < opts.frames and !io_dev.power_off) : (frame += 1) {
            m.runFrame();
            // Audio: hash every frame's samples (task 7.22) and optionally
            // accumulate for the WAV dump; then drain.
            const produced = m.aur.samples[0..m.aur.sample_count];
            audio_hash.update(std.mem.sliceAsBytes(produced));
            if (opts.dump_wav != null) {
                try wav_samples.appendSlice(arena, produced);
            }
            m.aur.clearSamples();
        }
        cycles = @as(u64, frame) * util.cycles_per_frame;
        util.logInfo("ran {d} frames ({d} cycles); {d}×{d} output", .{
            frame, cycles, m.vic.visibleWidth(), m.vic.visibleHeight(),
        });
        const hash = m.vic.frameHash();
        var hex: [64]u8 = undefined;
        for (hash, 0..) |byte, bi| {
            _ = std.fmt.bufPrint(hex[bi * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
        }
        util.logInfo("frame hash: {s}", .{&hex});
        if (opts.dump_ppm) |path| {
            try dumpPpm(io, m, path);
        }
        if (opts.golden) |want| {
            if (!std.ascii.eqlIgnoreCase(want, &hex)) {
                util.logErr("golden mismatch: want {s}", .{want});
                return error.GoldenMismatch;
            }
            util.logInfo("golden matched", .{});
        }
        var audio_digest: [32]u8 = undefined;
        audio_hash.final(&audio_digest);
        var audio_hex: [64]u8 = undefined;
        for (audio_digest, 0..) |byte, bi| {
            _ = std.fmt.bufPrint(audio_hex[bi * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
        }
        util.logInfo("audio hash: {s}", .{&audio_hex});
        if (opts.dump_wav) |path| {
            try dumpWav(io, path, wav_samples.items);
        }
        if (opts.audio_golden) |want| {
            if (!std.ascii.eqlIgnoreCase(want, &audio_hex)) {
                util.logErr("audio golden mismatch: want {s}", .{want});
                return error.AudioGoldenMismatch;
            }
            util.logInfo("audio golden matched", .{});
        }
    } else {
        // Cycle mode (Blocks 2–5): one instruction (or idle/delivery step)
        // per cycle (D17/D41). Ordering per cycle: sample the IRQ line,
        // step the CPU, tick the devices.
        var irq_idx: usize = 0;
        var injected = false;
        var key_idx: usize = 0;
        var joy_idx: usize = 0;
        while (cycles < opts.max_cycles and !cpu.halted and !io_dev.power_off) : (cycles += 1) {
            // Host-input injection (Block 8) before the IRQ line is
            // sampled, so an event at cycle N is deliverable at cycle N —
            // same convention as --irq-at. `while`, not `if`: same-cycle
            // bursts are allowed (a real host can flood the queue).
            while (key_idx < opts.key_count and cycles >= opts.key_at[key_idx].cycle) : (key_idx += 1) {
                io_dev.keyEvent(opts.key_at[key_idx].code);
            }
            while (joy_idx < opts.joy_count and cycles >= opts.joy_at[joy_idx].cycle) : (joy_idx += 1) {
                io_dev.setJoystick(opts.joy_at[joy_idx].port, opts.joy_at[joy_idx].state);
            }
            if (irq_idx < opts.irq_count and cycles >= opts.irq_at[irq_idx]) {
                injected = true; // --irq-at: asserted until delivered
            }
            cpu.irq_line = io_dev.irqLine() or injected;
            const event = cpu.step(bus);
            io_dev.tick();
            if (m.aur.tick(m.ram)) io_dev.raise(io_mod.irq_audio); // parity with machine.cycle
            if (event == .irq_entered and injected) {
                injected = false;
                irq_idx += 1;
            }
        }
        if (irq_idx < opts.irq_count) {
            util.logWarn("{d} of {d} --irq-at pulses were never delivered", .{ opts.irq_count - irq_idx, opts.irq_count });
        }
    }
    util.logInfo("ran {d} cycles; halted={}, power_off={}, PC=${X:0>5}", .{ cycles, cpu.halted, io_dev.power_off, cpu.pc });
    if (opts.expect_pass) {
        const result = bus.read16(result_addr);
        // A test ROM finishes by HLT or by SYSPWR soft power-off (§5.1).
        // In frame mode a halted CPU is normal — the VIC keeps rendering.
        if (!cpu.halted and !io_dev.power_off and opts.frames == 0) {
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

/// Minimal RIFF/WAVE writer: stereo S16 at 44.1 kHz.
fn dumpWav(io: std.Io, path: []const u8, samples: []const i16) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    const data_bytes: u32 = @intCast(samples.len * 2);
    var header: [44]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], 36 + data_bytes, .little);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little); //   PCM chunk size
    std.mem.writeInt(u16, header[20..22], 1, .little); //    PCM
    std.mem.writeInt(u16, header[22..24], 2, .little); //    stereo
    std.mem.writeInt(u32, header[24..28], 44_100, .little);
    std.mem.writeInt(u32, header[28..32], 44_100 * 4, .little); // byte rate
    std.mem.writeInt(u16, header[32..34], 4, .little); //    block align
    std.mem.writeInt(u16, header[34..36], 16, .little); //   bits/sample
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], data_bytes, .little);
    try file.writeStreamingAll(io, &header);
    try file.writeStreamingAll(io, std.mem.sliceAsBytes(samples));
    util.logInfo("wrote {s} ({d} samples)", .{ path, samples.len / 2 });
}

fn dumpPpm(io: std.Io, m: *machine_mod.Machine, path: []const u8) !void {
    const w = m.vic.visibleWidth();
    const hgt = m.vic.visibleHeight();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ w, hgt });
    try file.writeStreamingAll(io, header);
    try file.writeStreamingAll(io, m.vic.rgb[0 .. w * hgt * 3]);
    util.logInfo("wrote {s}", .{path});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "harness: argument parsing" {
    const o1 = try parseArgs(&.{ "harness", "--rom", "x.rom" });
    try testing.expectEqualStrings("x.rom", o1.rom_path.?);
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

    const o4 = try parseArgs(&.{ "harness", "--flapp", "p.flapp" });
    try testing.expectEqualStrings("p.flapp", o4.flapp_path.?);
    // §8.10 combined mode: ROM (font/BIOS) + .flapp together is legal.
    const o5 = try parseArgs(&.{ "harness", "--rom", "x", "--flapp", "y" });
    try testing.expectEqualStrings("x", o5.rom_path.?);
    try testing.expectEqualStrings("y", o5.flapp_path.?);

    try testing.expectError(error.MissingRom, parseArgs(&.{"harness"}));
    try testing.expectError(error.MissingValue, parseArgs(&.{ "harness", "--rom" }));
    try testing.expectError(error.UnknownArgument, parseArgs(&.{ "harness", "--bogus" }));
}

test "harness: --key-at / --joy-at parsing (Block 8)" {
    const o = try parseArgs(&.{
        "harness",   "--rom",         "x.rom",
        "--key-at",  "1000:000B",     "--key-at",
        "1000:800B", "--key-at",      "2500:0004",
        "--joy-at",  "8000:1:09",     "--joy-at",
        "9000:2:40", "--expect-pass",
    });
    try testing.expectEqual(@as(usize, 3), o.key_count);
    try testing.expectEqual(Options.KeyEvent{ .cycle = 1000, .code = 0x000B }, o.key_at[0]);
    try testing.expectEqual(Options.KeyEvent{ .cycle = 1000, .code = 0x800B }, o.key_at[1]); // same cycle OK
    try testing.expectEqual(Options.KeyEvent{ .cycle = 2500, .code = 0x0004 }, o.key_at[2]);
    try testing.expectEqual(@as(usize, 2), o.joy_count);
    try testing.expectEqual(Options.JoyEvent{ .cycle = 8000, .port = 0, .state = 0x09 }, o.joy_at[0]);
    try testing.expectEqual(Options.JoyEvent{ .cycle = 9000, .port = 1, .state = 0x40 }, o.joy_at[1]);

    // Malformed inputs are rejected, not misparsed.
    try testing.expectError(error.EventsNotAscending, parseArgs(&.{ "harness", "--rom", "x", "--key-at", "200:0001", "--key-at", "100:0002" }));
    try testing.expectError(error.BadFormat, parseArgs(&.{ "harness", "--rom", "x", "--key-at", "1000" }));
    try testing.expectError(error.BadPort, parseArgs(&.{ "harness", "--rom", "x", "--joy-at", "100:3:01" }));
    try testing.expectError(error.BadFormat, parseArgs(&.{ "harness", "--rom", "x", "--joy-at", "100:1:01:9" }));
    try testing.expectError(error.MissingValue, parseArgs(&.{ "harness", "--rom", "x", "--key-at" }));
}
