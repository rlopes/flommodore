//! build.zig — Flommodore emulator build script.
//!
//! Block 2 additions:
//!   - ram.zig, rom.zig, bus.zig, io.zig are compiled into the emulator.
//!   - `zig build test` runs all unit tests embedded in each module plus
//!     the combined routing test in tests/test_memory.zig.
//!
//! Usage:
//!   zig build               — build the emulator binary
//!   zig build test          — run all tests headlessly
//!   zig build test --summary all  — verbose test output

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // SDL3 dependency (added in Block 1.2)
    // -----------------------------------------------------------------------
    const sdl3_dep = b.dependency("sdl3", .{
        .target   = target,
        .optimize = optimize,
    });
    const sdl3_lib = sdl3_dep.artifact("SDL3");

    // -----------------------------------------------------------------------
    // Main emulator executable
    // -----------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name           = "flommodore",
        .root_source_file = b.path("src/main.zig"),
        .target         = target,
        .optimize       = optimize,
    });
    exe.linkLibrary(sdl3_lib);
    b.installArtifact(exe);

    // -----------------------------------------------------------------------
    // Unit tests — each source module carries its own `test` blocks.
    //
    // We compile a single test binary that imports all modules so Zig runs
    // all embedded tests plus the standalone routing test.
    // -----------------------------------------------------------------------

    // Per-module test steps (run in-source tests for each module independently)
    const modules = [_][]const u8{
        "src/ram.zig",
        "src/rom.zig",
        "src/io.zig",
        "src/bus.zig",
        "src/util.zig",
    };

    for (modules) |mod_path| {
        const mod_tests = b.addTest(.{
            .root_source_file = b.path(mod_path),
            .target           = target,
            .optimize         = optimize,
        });
        const run_mod_tests = b.addRunArtifact(mod_tests);
        b.step("test", "Run unit tests").dependOn(&run_mod_tests.step);
    }

    // Block 2.5: combined memory routing test
    const mem_tests = b.addTest(.{
        .root_source_file = b.path("tests/test_memory.zig"),
        .target           = target,
        .optimize         = optimize,
    });
    // The routing test imports bus/ram/rom/io — make them available as modules.
    const ram_mod = b.addModule("ram", .{ .root_source_file = b.path("src/ram.zig") });
    const rom_mod = b.addModule("rom", .{ .root_source_file = b.path("src/rom.zig") });
    const io_mod  = b.addModule("io",  .{ .root_source_file = b.path("src/io.zig")  });
    const bus_mod = b.addModule("bus", .{
        .root_source_file = b.path("src/bus.zig"),
        .imports = &.{
            .{ .name = "ram", .module = ram_mod },
            .{ .name = "rom", .module = rom_mod },
            .{ .name = "io",  .module = io_mod  },
        },
    });
    mem_tests.root_module.addImport("bus", bus_mod);
    mem_tests.root_module.addImport("ram", ram_mod);
    mem_tests.root_module.addImport("rom", rom_mod);
    mem_tests.root_module.addImport("io",  io_mod);

    const run_mem_tests = b.addRunArtifact(mem_tests);
    b.step("test", "Run unit tests").dependOn(&run_mem_tests.step);
}
