//! Flommodore — build script (Block 1).
//!
//! Zig 0.16 build graph:
//!   zig build            → the `flommodore` emulator binary (SDL3 statically linked)
//!   zig build run        → build + launch the emulator window
//!   zig build test       → all unit-test artifacts (one `test` step, many run artifacts)
//!   zig build genroms    → test-ROM generator (placeholder until Block 2)
//!
//! API shapes below (`addExecutable` taking `.root_module`, `b.createModule`,
//! `b.addTranslateC` + `createModule()` for C headers, `addTest` taking
//! `.root_module`) were verified against the installed Zig 0.16.0 std.Build
//! source and the official 0.16.0 release notes ("@cImport Moving to Build
//! System" section), 2026-07-02.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ------------------------------------------------------------------
    // SDL3 — castholm/SDL, a port of SDL to the Zig build system.
    // Chosen over (a) the official libsdl-org/SDL tarball, which has no
    // build.zig and therefore cannot produce a Zig dependency artifact,
    // and (b) system SDL3 via linkSystemLibrary, which would break the
    // "clean checkout builds with no manual steps" requirement (task 1.2)
    // and cross-compilation (task 1.5). Pinned by hash in build.zig.zon.
    // ------------------------------------------------------------------
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    const sdl_lib = sdl_dep.artifact("SDL3");

    // C headers are translated at build time (Zig 0.16 removed @cImport from
    // the language). src/sdl3.h is a thin wrapper that #includes <SDL3/SDL.h>;
    // the translated output is imported by Zig code as the module "sdl3".
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl3.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(sdl_dep.path("include"));
    const sdl3_module = translate_c.createModule();

    // ------------------------------------------------------------------
    // Emulator executable.
    // ------------------------------------------------------------------
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sdl3", .module = sdl3_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "flommodore",
        .root_module = exe_module,
    });
    exe_module.linkLibrary(sdl_lib); // 0.16: linking is a Module property, not a Compile-step method
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the Flommodore emulator");
    run_step.dependOn(&run_cmd.step);

    // ------------------------------------------------------------------
    // Tests. The `test` step is created exactly ONCE; each per-module test
    // binary gets its own run artifact which the single step depends on.
    // (Registering the same step name twice is a build error — the pre-v1.1
    // scaffold's loop bug, audit P6.)
    // ------------------------------------------------------------------
    const test_step = b.step("test", "Run all unit tests");

    // Test roots grow over the blocks; Block 1 ships util (real tests) and
    // encode (stub — compiles and runs zero tests, proving the multi-artifact
    // step shape works).
    const test_roots = [_][]const u8{
        "src/util.zig",
        "src/encode.zig",
    };
    for (test_roots) |root| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ------------------------------------------------------------------
    // genroms — placeholder step so the build-graph shape is final now.
    // Block 2 replaces the stub body with real test-ROM builders emitting
    // into tests/roms/.
    // ------------------------------------------------------------------
    const genroms_exe = b.addExecutable(.{
        .name = "genroms",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/genroms.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const genroms_run = b.addRunArtifact(genroms_exe);
    const genroms_step = b.step("genroms", "Generate test ROMs (not implemented until Block 2)");
    genroms_step.dependOn(&genroms_run.step);
}
