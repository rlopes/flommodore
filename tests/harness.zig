//! harness.zig — Headless ROM test runner.
//!
//! Loads a test ROM, runs the emulator for a fixed cycle count, and checks
//! the result byte at $00010 (spec §7.12):
//!
//!   $FF   → PASS
//!   $00   → still running (timeout)
//!   other → FAIL (value encodes which assertion failed)
//!
//! Usage:
//!   flommodore-test tests/roms/test_cpu_alu.rom
//!   flommodore-test tests/roms/*.rom    (runs all, reports summary)
//!
//! Implemented in Block 3 (after CPU and RAM exist).

const std = @import("std");

// TODO: Block 3 — wire up real emulator state (bus, ram, rom, cpu, io)
//                 and implement run_test() / main().

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("flommodore-test: harness stub (Block 1)\n", .{});
    try stdout.print("  Implement in Block 3 once CPU and RAM are ready.\n", .{});
}
