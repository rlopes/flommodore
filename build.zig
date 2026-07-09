//! Flommodore — build script (Blocks 1–2).
//!
//! Zig 0.16 build graph:
//!   zig build            → the `flommodore` emulator binary (SDL3 statically linked)
//!   zig build run        → build + launch the emulator window
//!   zig build test       → all unit-test artifacts (one `test` step, many run artifacts)
//!   zig build genroms    → emit generated test ROMs into tests/roms/
//!   zig build harness -- --rom <path>  → headless runner (no SDL)
//!
//! Core machine components (util, ram, rom, bus, encode) are named modules
//! so `tests/` code and — later — the toolchain binaries can import them
//! without file-path imports across directory roots. Each type then has
//! exactly one canonical instance in the build graph.
//!
//! API shapes were verified against the installed Zig 0.16.0 std.Build
//! source and the official 0.16.0 release notes, 2026-07-02.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ------------------------------------------------------------------
    // Core machine modules (Block 2). Dependency edges are explicit:
    //   util ← {ram? no, rom? no, bus, encode}
    //   bus  ← util, ram, rom
    // ------------------------------------------------------------------
    const util_mod = b.createModule(.{
        .root_source_file = b.path("src/util.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ram_mod = b.createModule(.{
        .root_source_file = b.path("src/ram.zig"),
        .target = target,
        .optimize = optimize,
    });
    const rom_mod = b.createModule(.{
        .root_source_file = b.path("src/rom.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vic_mod = b.createModule(.{
        .root_source_file = b.path("src/vic256.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
            .{ .name = "ram", .module = ram_mod },
            .{ .name = "rom", .module = rom_mod },
        },
    });
    const aur_mod = b.createModule(.{
        .root_source_file = b.path("src/aur1.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
            .{ .name = "ram", .module = ram_mod },
        },
    });
    const io_mod = b.createModule(.{
        .root_source_file = b.path("src/io.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
            .{ .name = "vic256", .module = vic_mod },
            .{ .name = "aur1", .module = aur_mod },
        },
    });
    const input_mod = b.createModule(.{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "io", .module = io_mod },
        },
    });
    const bus_mod = b.createModule(.{
        .root_source_file = b.path("src/bus.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
            .{ .name = "ram", .module = ram_mod },
            .{ .name = "rom", .module = rom_mod },
            .{ .name = "io", .module = io_mod },
        },
    });
    const flapp_mod = b.createModule(.{
        .root_source_file = b.path("src/flapp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
            .{ .name = "bus", .module = bus_mod },
            // ram/rom/io are used by flapp.zig's test fixture only.
            .{ .name = "ram", .module = ram_mod },
            .{ .name = "rom", .module = rom_mod },
            .{ .name = "io", .module = io_mod },
        },
    });
    const encode_mod = b.createModule(.{
        .root_source_file = b.path("src/encode.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
        },
    });
    const machine_mod = b.createModule(.{
        .root_source_file = b.path("src/machine.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
            .{ .name = "ram", .module = ram_mod },
            .{ .name = "rom", .module = rom_mod },
            .{ .name = "io", .module = io_mod },
            .{ .name = "bus", .module = bus_mod },
            .{ .name = "vic256", .module = vic_mod },
            .{ .name = "aur1", .module = aur_mod },
        },
    });
    const cpu_mod = b.createModule(.{
        .root_source_file = b.path("src/cpu.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
            .{ .name = "bus", .module = bus_mod },
            .{ .name = "encode", .module = encode_mod },
            // ram/rom/io are used by cpu.zig's test fixtures only.
            .{ .name = "ram", .module = ram_mod },
            .{ .name = "rom", .module = rom_mod },
            .{ .name = "io", .module = io_mod },
        },
    });
    machine_mod.addImport("cpu", cpu_mod);
    machine_mod.addImport("encode", encode_mod); // machine.zig tests only
    const disasm_mod = b.createModule(.{
        .root_source_file = b.path("src/disasm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
            .{ .name = "encode", .module = encode_mod },
            .{ .name = "cpu", .module = cpu_mod },
        },
    });
    const debugger_mod = b.createModule(.{
        .root_source_file = b.path("src/debugger.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
            .{ .name = "encode", .module = encode_mod },
            .{ .name = "cpu", .module = cpu_mod },
            .{ .name = "bus", .module = bus_mod },
            .{ .name = "io", .module = io_mod },
            .{ .name = "machine", .module = machine_mod },
            .{ .name = "disasm", .module = disasm_mod },
            // ram/rom for direct (side-effect-free) memory-view reads.
            .{ .name = "ram", .module = ram_mod },
            .{ .name = "rom", .module = rom_mod },
        },
    });

    // ------------------------------------------------------------------
    // flas assembler (Block 10) — src/tools/assembler/ per Phase 8 §8.9.
    // encode.zig is the ONLY encoder (audit P1): codegen imports it, no
    // module here carries a second encoding table.
    // ------------------------------------------------------------------
    const asm_lexer_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/assembler/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const asm_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/assembler/parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lexer", .module = asm_lexer_mod },
        },
    });

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
            .{ .name = "util", .module = util_mod },
            .{ .name = "ram", .module = ram_mod },
            .{ .name = "rom", .module = rom_mod },
            .{ .name = "bus", .module = bus_mod },
            .{ .name = "encode", .module = encode_mod },
            .{ .name = "cpu", .module = cpu_mod },
            .{ .name = "io", .module = io_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "flapp", .module = flapp_mod },
            .{ .name = "machine", .module = machine_mod },
            .{ .name = "vic256", .module = vic_mod },
            .{ .name = "disasm", .module = disasm_mod },
            .{ .name = "debugger", .module = debugger_mod },
        },
    });
    exe_module.linkLibrary(sdl_lib); // 0.16: linking is a Module property

    const exe = b.addExecutable(.{
        .name = "flommodore",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the Flommodore emulator");
    run_step.dependOn(&run_cmd.step);

    // ------------------------------------------------------------------
    // Headless harness (task 2.8) — never links or imports SDL.
    // ------------------------------------------------------------------
    const harness_module = b.createModule(.{
        .root_source_file = b.path("tests/harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "util", .module = util_mod },
            .{ .name = "ram", .module = ram_mod },
            .{ .name = "rom", .module = rom_mod },
            .{ .name = "bus", .module = bus_mod },
            .{ .name = "cpu", .module = cpu_mod },
            .{ .name = "io", .module = io_mod },
            .{ .name = "flapp", .module = flapp_mod },
            .{ .name = "machine", .module = machine_mod },
            .{ .name = "vic256", .module = vic_mod },
        },
    });
    const harness_exe = b.addExecutable(.{
        .name = "harness",
        .root_module = harness_module,
    });
    b.installArtifact(harness_exe);
    const harness_run = b.addRunArtifact(harness_exe);
    if (b.args) |args| harness_run.addArgs(args);
    const harness_step = b.step("harness", "Run the headless test harness (-- --rom <path>)");
    harness_step.dependOn(&harness_run.step);

    // ------------------------------------------------------------------
    // genroms (task 2.7): emit generated test ROMs into tests/roms/.
    // Runs on the host (it only writes files) and receives the output
    // directory as argv[1] so cwd never matters.
    // ------------------------------------------------------------------
    const host_util = b.createModule(.{
        .root_source_file = b.path("src/util.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const host_rom = b.createModule(.{
        .root_source_file = b.path("src/rom.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const host_encode = b.createModule(.{
        .root_source_file = b.path("src/encode.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "util", .module = host_util }},
    });
    const host_ram = b.createModule(.{
        .root_source_file = b.path("src/ram.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const host_vic = b.createModule(.{
        .root_source_file = b.path("src/vic256.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "util", .module = host_util },
            .{ .name = "ram", .module = host_ram },
            .{ .name = "rom", .module = host_rom },
        },
    });
    const host_aur = b.createModule(.{
        .root_source_file = b.path("src/aur1.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "util", .module = host_util },
            .{ .name = "ram", .module = host_ram },
        },
    });
    const host_io = b.createModule(.{
        .root_source_file = b.path("src/io.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "util", .module = host_util },
            .{ .name = "vic256", .module = host_vic },
            .{ .name = "aur1", .module = host_aur },
        },
    });
    const host_bus = b.createModule(.{
        .root_source_file = b.path("src/bus.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "util", .module = host_util },
            .{ .name = "ram", .module = host_ram },
            .{ .name = "rom", .module = host_rom },
            .{ .name = "io", .module = host_io },
        },
    });
    const host_flapp = b.createModule(.{
        .root_source_file = b.path("src/flapp.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "util", .module = host_util },
            .{ .name = "bus", .module = host_bus },
            .{ .name = "ram", .module = host_ram },
            .{ .name = "rom", .module = host_rom },
            .{ .name = "io", .module = host_io },
        },
    });
    const genroms_module = b.createModule(.{
        .root_source_file = b.path("tests/genroms.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "util", .module = host_util },
            .{ .name = "rom", .module = host_rom },
            .{ .name = "encode", .module = host_encode },
            .{ .name = "flapp", .module = host_flapp },
        },
    });
    const genroms_exe = b.addExecutable(.{
        .name = "genroms",
        .root_module = genroms_module,
    });
    const genroms_run = b.addRunArtifact(genroms_exe);
    genroms_run.addArg(b.pathFromRoot("tests/roms"));
    // Always regenerate: output freshness is the builders' concern, and the
    // images are tiny.
    genroms_run.has_side_effects = true;
    const genroms_step = b.step("genroms", "Generate test ROMs into tests/roms/");
    genroms_step.dependOn(&genroms_run.step);

    // ------------------------------------------------------------------
    // Tests. The `test` step is created exactly ONCE; each per-module test
    // binary gets its own run artifact which the single step depends on.
    // ------------------------------------------------------------------
    const test_step = b.step("test", "Run all unit tests");
    const test_modules = [_]*std.Build.Module{
        util_mod,
        ram_mod,
        rom_mod,
        aur_mod,
        io_mod,
        input_mod,
        bus_mod,
        flapp_mod,
        vic_mod,
        machine_mod,
        encode_mod,
        cpu_mod,
        disasm_mod,
        debugger_mod,
        asm_lexer_mod,
        asm_parser_mod,
        genroms_module,
        harness_module,
    };
    for (test_modules) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
