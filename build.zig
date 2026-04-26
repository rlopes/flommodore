const std = @import("std");

pub fn build(b: *std.Build) void {
    // ── Target & optimisation ────────────────────────────────────────────────
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── SDL3 dependency ──────────────────────────────────────────────────────
    //
    // SDL3 is pulled in as a Zig package that compiles SDL from source.
    // This gives us fully reproducible, zero-setup cross-platform builds.
    // No system SDL3 installation required.
    //
    // NOTE for task 1.2: replace the stub dep below with the real SDL3
    // package once the .zon hash is confirmed with `zig fetch`.
    // For now we link against the system SDL3 so `zig build` succeeds
    // on machines that already have it installed.
    //
    // When the real dep is ready, swap these two blocks:
    //   const sdl3_dep = b.dependency("sdl3", .{ .target = target, .optimize = optimize });
    //   exe.linkLibrary(sdl3_dep.artifact("SDL3"));

    // ── Emulator executable ───────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "flommodore",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // SDL3 — system install until dep hash is pinned (task 1.2)
    exe.linkSystemLibrary("SDL3");
    exe.linkLibC();

    b.installArtifact(exe);

    // ── Run step: `zig build run` ────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the Flommodore emulator");
    run_step.dependOn(&run_cmd.step);

    // ── Unit tests: `zig build test` ─────────────────────────────────────────
    //
    // Each source module can contain `test` blocks.  We compile them all into
    // a single test binary so that `zig build test` exercises everything.
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
            .root_source_file = b.path(mod_path),
            .target = target,
            .optimize = optimize,
        });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        const test_step = b.step("test", "Run all unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }

    // ── Headless test harness: `zig build test-roms` ─────────────────────────
    //
    // Runs the per-component test ROMs headlessly and reports pass/fail.
    // Built in Block 3 onwards; the step is wired up here so the build target
    // exists from day one.
    const harness = b.addExecutable(.{
        .name = "flommodore-test",
        .root_source_file = b.path("tests/harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    harness.linkSystemLibrary("SDL3");
    harness.linkLibC();

    const run_harness = b.addRunArtifact(harness);
    if (b.args) |args| run_harness.addArgs(args);

    const test_roms_step = b.step("test-roms", "Run headless ROM test suite");
    test_roms_step.dependOn(&run_harness.step);
}
