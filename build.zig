const std = @import("std");

pub fn build(b: *std.Build) void {
    // ── Target & optimisation ────────────────────────────────────────────────
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── SDL3 C header translation (0.16: @cImport removed from the language) ─
    //
    // In Zig 0.16, @cImport is no longer a language builtin.  C headers are
    // translated at build time via addTranslateC, which produces a Zig module
    // that source files import by name ("sdl3").
    //
    // The header file src/sdl3.h is a thin wrapper that just does:
    //   #include <SDL3/SDL.h>
    //
    // SDL3 itself is linked via linkSystemLibrary (system install) until the
    // fetched dep hash is pinned.  To switch to the vendored source build,
    // uncomment the sdl3_dep block below and replace linkSystemLibrary.
    const translate_sdl3 = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl3.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // System SDL3 until dep hash is confirmed — run `zig fetch <url>` first.
    translate_sdl3.linkSystemLibrary("SDL3", .{});

    // Vendored SDL3 (uncomment once hash is known):
    // const sdl3_dep = b.dependency("sdl3", .{ .target = target, .optimize = optimize });
    // translate_sdl3.linkLibrary(sdl3_dep.artifact("SDL3"));

    const sdl3_module = translate_sdl3.createModule();

    // ── Emulator executable ───────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "flommodore",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sdl3", .module = sdl3_module },
            },
        }),
    });
    // SDL3 runtime linkage on the executable
    exe.root_module.linkSystemLibrary("SDL3", .{});
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    // ── Run step: `zig build run` ────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the Flommodore emulator");
    run_step.dependOn(&run_cmd.step);

    // ── Unit tests: `zig build test` ─────────────────────────────────────────
    //
    // Each source module can contain `test` blocks.
    // We compile a test binary per module so that `zig build test` runs all.
    const test_step = b.step("test", "Run all unit tests");

    const modules = [_][]const u8{
        "src/util.zig",
        "src/ram.zig",
        "src/rom.zig",
        "src/bus.zig",
        "src/cpu.zig",
        "src/vic256.zig",
        "src/aur1.zig",
        "src/io.zig",
        "src/debugger.zig",
    };

    for (modules) |mod_path| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(mod_path),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    // ── Headless test harness: `zig build test-roms` ─────────────────────────
    //
    // Runs per-component test ROMs headlessly.  Wired in here so the build
    // target exists from day one; the harness itself is implemented in Block 3.
    const harness = b.addExecutable(.{
        .name = "flommodore-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/harness.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    harness.root_module.linkSystemLibrary("SDL3", .{});
    harness.root_module.link_libc = true;

    const run_harness = b.addRunArtifact(harness);
    if (b.args) |args| run_harness.addArgs(args);

    const test_roms_step = b.step("test-roms", "Run headless ROM test suite");
    test_roms_step.dependOn(&run_harness.step);
}
