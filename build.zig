//! build.zig — Flommodore emulator build script.
//!
//! Block 2 additions:
//!   - ram.zig, rom.zig, bus.zig, io.zig are compiled into the emulator.
//!   - `zig build test` runs all unit tests embedded in each module plus
//!     the combined routing test in tests/test_memory.zig.
//!
//! Usage:
//!   zig build               — build the emulator binary
//!   zig build run           — run the emulator
//!   zig build test          — run all tests headlessly
//!   zig build test --summary all  — verbose test output

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // SDL3 dependency (added in Block 1.2)
    // -----------------------------------------------------------------------
    const sdl3_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    const sdl3_lib = sdl3_dep.artifact("SDL3");

    // -----------------------------------------------------------------------
    // Main emulator executable
    // -----------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "flommodore",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.linkLibrary(sdl3_lib);
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the emulator");
    run_step.dependOn(&run_exe.step);

    // -----------------------------------------------------------------------
    // Unit tests — each source module carries its own `test` blocks.
    // -----------------------------------------------------------------------
    const test_exe = b.addTest(.{
        .name = "unit_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    test_exe.root_module.linkLibrary(sdl3_lib);
    b.installArtifact(test_exe);

    const run_test = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_test.step);
}
