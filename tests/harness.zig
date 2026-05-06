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
//!
//! Zig 0.16 notes:
//!   • std.io.getStdOut().writer() is gone; use std.debug.print for stderr,
//!     or the new std.Io interface for stdout.

const std = @import("std");

// TODO: Block 3 — wire up real emulator state (bus, ram, rom, cpu, io)
//                 and implement run_test() / main().

pub fn main() !void {
    std.debug.print("flommodore-test: harness stub (Block 1)\n", .{});
    std.debug.print("  Implement in Block 3 once CPU and RAM are ready.\n", .{});
}
