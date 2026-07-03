//! Flommodore — `tests/genroms.zig` (Block 2).
//! Test-ROM builders: emit `tests/roms/*.rom` via `src/encode.zig` so CPU
//! tests have real 16KB images with 4-byte vectors at $FFFC0 (plan task 2.7).
//! Block 1 registers the `zig build genroms` step with this placeholder body
//! so the build-graph shape is final now.

const std = @import("std");

pub fn main() void {
    std.debug.print("genroms: not implemented until Block 2\n", .{});
}
