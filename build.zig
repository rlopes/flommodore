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
    const asm_macro_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/assembler/macro.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parser", .module = asm_parser_mod },
            // Mnemonic NAMES only (decision y) — no encodings used here.
            .{ .name = "encode", .module = encode_mod },
        },
    });
    const asm_codegen_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/assembler/codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parser", .module = asm_parser_mod },
            .{ .name = "macro", .module = asm_macro_mod },
            // The ONLY encoder (audit P1): every instruction word in pass 2
            // is produced by an encode.zig wrapper.
            .{ .name = "encode", .module = encode_mod },
        },
    });
    const asm_objfile_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/assembler/objfile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "codegen", .module = asm_codegen_mod },
        },
    });
    const asm_listing_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/assembler/listing.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "codegen", .module = asm_codegen_mod },
        },
    });
    const flas_module = b.createModule(.{
        .root_source_file = b.path("src/tools/assembler/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parser", .module = asm_parser_mod },
            .{ .name = "macro", .module = asm_macro_mod },
            .{ .name = "codegen", .module = asm_codegen_mod },
            .{ .name = "objfile", .module = asm_objfile_mod },
            .{ .name = "listing", .module = asm_listing_mod },
        },
    });
    const flas_exe = b.addExecutable(.{
        .name = "flas",
        .root_module = flas_module,
    });
    b.installArtifact(flas_exe);
    const asm_step = b.step("asm", "Build the flas assembler (Phase 8 \u{a7}8.9)");
    asm_step.dependOn(&b.addInstallArtifact(flas_exe, .{}).step);

    // ------------------------------------------------------------------
    // fll linker (Block 11) — src/tools/linker/ per Phase 8 §8.9.
    // The loader round-trips against the assembler's writer in tests.
    // ------------------------------------------------------------------
    const lnk_loader_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/linker/loader.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            // Tests only: round-trip through the assembler's writer.
            .{ .name = "codegen", .module = asm_codegen_mod },
            .{ .name = "objfile", .module = asm_objfile_mod },
        },
    });
    const lnk_script_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/linker/script.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lnk_resolver_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/linker/resolver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "loader", .module = lnk_loader_mod },
            .{ .name = "script", .module = lnk_script_mod },
            // Tests only: assemble fixtures and cross-check header size.
            .{ .name = "codegen", .module = asm_codegen_mod },
            .{ .name = "objfile", .module = asm_objfile_mod },
            .{ .name = "flapp", .module = flapp_mod },
        },
    });
    const lnk_relocator_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/linker/relocator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "loader", .module = lnk_loader_mod },
            .{ .name = "resolver", .module = lnk_resolver_mod },
            // Field masks derive from the encoder itself (decision ax).
            .{ .name = "encode", .module = encode_mod },
            // Tests only: assemble fixtures.
            .{ .name = "codegen", .module = asm_codegen_mod },
            .{ .name = "objfile", .module = asm_objfile_mod },
            .{ .name = "script", .module = lnk_script_mod },
        },
    });
    const lnk_emitter_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/linker/emitter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "loader", .module = lnk_loader_mod },
            .{ .name = "resolver", .module = lnk_resolver_mod },
            // Tests only: assemble fixtures, relocate them, and
            // byte-cross-check the locally written header against
            // flapp.writeHeader (task 11.6 acceptance).
            .{ .name = "codegen", .module = asm_codegen_mod },
            .{ .name = "objfile", .module = asm_objfile_mod },
            .{ .name = "script", .module = lnk_script_mod },
            .{ .name = "relocator", .module = lnk_relocator_mod },
            .{ .name = "flapp", .module = flapp_mod },
            .{ .name = "encode", .module = encode_mod },
        },
    });
    const fll_module = b.createModule(.{
        .root_source_file = b.path("src/tools/linker/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "loader", .module = lnk_loader_mod },
            .{ .name = "script", .module = lnk_script_mod },
            .{ .name = "resolver", .module = lnk_resolver_mod },
            .{ .name = "relocator", .module = lnk_relocator_mod },
            .{ .name = "emitter", .module = lnk_emitter_mod },
        },
    });
    const fll_exe = b.addExecutable(.{
        .name = "fll",
        .root_module = fll_module,
    });
    b.installArtifact(fll_exe);
    const lnk_step = b.step("lnk", "Build the fll linker (Phase 8 \u{a7}8.9)");
    lnk_step.dependOn(&b.addInstallArtifact(fll_exe, .{}).step);

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
    // Block 10 e2e acceptance: assemble the .asm rewrite of test_cpu_alu
    // with the REAL flas CLI and byte-compare the reconstructed absolute
    // image against the genroms-generated .rom (tests/cmprom.zig). Runs
    // as part of `zig build test` and standalone via `zig build asmtest`.
    // ------------------------------------------------------------------
    const flas_alu_run = b.addRunArtifact(flas_exe);
    flas_alu_run.addFileArg(b.path("tests/asm/test_cpu_alu.asm"));
    flas_alu_run.addArg("-o");
    const alu_flobj = flas_alu_run.addOutputFileArg("test_cpu_alu.flobj");

    const cmprom_module = b.createModule(.{
        .root_source_file = b.path("tests/cmprom.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rom", .module = rom_mod },
        },
    });
    const cmprom_exe = b.addExecutable(.{
        .name = "cmprom",
        .root_module = cmprom_module,
    });
    const cmprom_run = b.addRunArtifact(cmprom_exe);
    cmprom_run.addFileArg(alu_flobj);
    cmprom_run.addArg(b.pathFromRoot("tests/roms/test_cpu_alu.rom"));
    cmprom_run.step.dependOn(&genroms_run.step); // the .rom must exist first
    cmprom_run.has_side_effects = true; // reads a source-tree artifact
    const asmtest_step = b.step("asmtest", "Block 10 e2e: flas output vs genroms ROM");
    asmtest_step.dependOn(&cmprom_run.step);

    // ------------------------------------------------------------------
    // Block 11 e2e acceptance (task 11.12): assemble the relocatable
    // examples/hello.asm with the REAL flas, link it with the REAL fll
    // against examples/hello.flld, and run the .flapp in the headless
    // harness with the font ROM (§8.10 combined invocation — text-mode
    // glyphs come from ROM $FE000, which a bare .flapp cannot provide).
    // The golden SHA-256 is the 640×360 frame showing "HELLO,
    // FLOMMODORE!" in white on deep blue at row 2, col 4. Runs as part
    // of `zig build test` and standalone via `zig build hellotest`.
    // ------------------------------------------------------------------
    const flas_hello_run = b.addRunArtifact(flas_exe);
    flas_hello_run.addFileArg(b.path("examples/hello.asm"));
    flas_hello_run.addArg("-o");
    const hello_flobj = flas_hello_run.addOutputFileArg("hello.flobj");

    const fll_hello_run = b.addRunArtifact(fll_exe);
    fll_hello_run.addFileArg(hello_flobj);
    fll_hello_run.addArg("-s");
    fll_hello_run.addFileArg(b.path("examples/hello.flld"));
    fll_hello_run.addArg("-o");
    const hello_flapp = fll_hello_run.addOutputFileArg("hello.flapp");

    const hello_run = b.addRunArtifact(harness_exe);
    hello_run.addArg("--rom");
    hello_run.addArg(b.pathFromRoot("tests/roms/font.rom"));
    hello_run.addArg("--flapp");
    hello_run.addFileArg(hello_flapp);
    hello_run.addArgs(&.{
        "--frames",
        "2",
        "--golden",
        "297c302d5f031dfd2d01b7385896f9bc999a846fa1b0307fc14610a786fefcef",
        "--quiet",
    });
    hello_run.step.dependOn(&genroms_run.step); // font.rom must exist first
    hello_run.has_side_effects = true; // reads a source-tree artifact
    const hellotest_step = b.step("hellotest", "Block 11 e2e: hello.asm → fll → harness golden frame");
    hellotest_step.dependOn(&hello_run.step);

    // ------------------------------------------------------------------
    // Block 12 (part 3/3): the BIOS ROM build — task 12.16 groundwork.
    // flas assembles src/bios/bios.asm in absolute mode (font.inc and
    // palette.inc resolve beside it), then `fll --raw --base $FC000
    // --size 16K` frames the 16KB image. The build graph owns the cached
    // artifact; `zig build bios` additionally refreshes the gitignored
    // rom/flommodore.rom so the emulator CLI has a stable path to the
    // firmware. tests/bootcheck.zig then audits the §6.8 Stage 1–6
    // postconditions on a real Machine (DECISION bk: a state audit
    // through side-effect-free reads, plus — now that the boot paints
    // the banner — the task-12.16 golden boot frame below).
    // Runs as part of `zig build test` and standalone via
    // `zig build boottest`.
    // ------------------------------------------------------------------
    const flas_bios_run = b.addRunArtifact(flas_exe);
    flas_bios_run.addFileArg(b.path("src/bios/bios.asm"));
    flas_bios_run.addArg("-o");
    const bios_flobj = flas_bios_run.addOutputFileArg("bios.flobj");

    const fll_bios_run = b.addRunArtifact(fll_exe);
    fll_bios_run.addArgs(&.{ "--raw", "--base", "$FC000", "--size", "16K" });
    fll_bios_run.addFileArg(bios_flobj);
    fll_bios_run.addArg("-o");
    const bios_rom = fll_bios_run.addOutputFileArg("flommodore.rom");

    // The published §8.3 hello (tests/asm/hello.asm — the Block 10
    // listing fixture, absolute at $04100) built through the same
    // toolchain, as a raw memory image for syscheck's Milestone-5
    // acceptance: typed RUN 4100, SYS_PUTSTR output, SYS_GETKEY, HLT.
    const flas_hello83_run = b.addRunArtifact(flas_exe);
    flas_hello83_run.addFileArg(b.path("tests/asm/hello.asm"));
    flas_hello83_run.addArg("-o");
    const hello83_flobj = flas_hello83_run.addOutputFileArg("hello83.flobj");

    const fll_hello83_run = b.addRunArtifact(fll_exe);
    fll_hello83_run.addArgs(&.{ "--overlay", "--base", "$04100", "--size", "256" });
    fll_hello83_run.addFileArg(hello83_flobj);
    fll_hello83_run.addArg("-o");
    const hello83_raw = fll_hello83_run.addOutputFileArg("hello83.raw");

    const bios_update = b.addUpdateSourceFiles();
    bios_update.addCopyFileToSource(bios_rom, "rom/flommodore.rom");
    const bios_step = b.step("bios", "Build the BIOS ROM into rom/flommodore.rom (task 12.16)");
    bios_step.dependOn(&bios_update.step);

    // ------------------------------------------------------------------
    // `zig build examples`: build the examples/ programs into runnable,
    // gitignored .flapp files beside their sources. bios_hello is the
    // BIOS-era demo — run it the cartridge way (decision bu):
    //   flommodore --rom rom/flommodore.rom --autoboot examples/bios_hello.flapp
    // ------------------------------------------------------------------
    const flas_bhello_run = b.addRunArtifact(flas_exe);
    flas_bhello_run.addFileArg(b.path("examples/bios_hello.asm"));
    flas_bhello_run.addArg("-o");
    const bhello_flobj = flas_bhello_run.addOutputFileArg("bios_hello.flobj");

    const fll_bhello_run = b.addRunArtifact(fll_exe);
    fll_bhello_run.addFileArg(bhello_flobj);
    fll_bhello_run.addArg("-s");
    fll_bhello_run.addFileArg(b.path("examples/bios_hello.flld"));
    fll_bhello_run.addArg("-o");
    const bhello_flapp = fll_bhello_run.addOutputFileArg("bios_hello.flapp");

    const examples_update = b.addUpdateSourceFiles();
    examples_update.addCopyFileToSource(hello_flapp, "examples/hello.flapp");
    examples_update.addCopyFileToSource(bhello_flapp, "examples/bios_hello.flapp");
    const examples_step = b.step("examples", "Build examples/*.flapp (run bios_hello with --rom + --autoboot)");
    examples_step.dependOn(&examples_update.step);
    examples_step.dependOn(&bios_update.step); // bios_hello needs the firmware too

    // The autoboot demo, pinned: place bios_hello.flapp in RAM, boot the
    // BIOS, and the §6.9 scan must run it — banner, the program's two
    // lines, READY. (hash from a font-decoded screen, like the others).
    const bhello_run = b.addRunArtifact(harness_exe);
    bhello_run.addArg("--rom");
    bhello_run.addFileArg(bios_rom);
    bhello_run.addArg("--autoboot");
    bhello_run.addArg("--flapp");
    bhello_run.addFileArg(bhello_flapp);
    bhello_run.addArgs(&.{
        "--frames",
        "2",
        "--golden",
        "a3375e7f5ad24c55cc3e52d6254c01fe7c7182352384ea0a56b89840eb15c17e",
        "--quiet",
    });

    const bootcheck_module = b.createModule(.{
        .root_source_file = b.path("tests/bootcheck.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rom", .module = rom_mod },
            .{ .name = "cpu", .module = cpu_mod },
            .{ .name = "machine", .module = machine_mod },
        },
    });
    const bootcheck_exe = b.addExecutable(.{
        .name = "bootcheck",
        .root_module = bootcheck_module,
    });
    const bootcheck_run = b.addRunArtifact(bootcheck_exe);
    bootcheck_run.addFileArg(bios_rom);
    const boottest_step = b.step("boottest", "Block 12 e2e: BIOS boots to READY — §6.8 stages 1–6 + the golden boot frame");
    boottest_step.dependOn(&bootcheck_run.step);

    // Syscalls, shell, and autoboot (tasks 12.5–12.16): tests/syscheck.zig
    // drives the permanent $FC100 jump-table ABI on the booted machine
    // with host-injected calls (DECISION bm), audits every syscall family
    // and the decision-be register conventions, runs the IRQ dispatcher
    // end to end, and finishes with autoboot + the published §8.3 hello
    // typed into the shell.
    const syscheck_module = b.createModule(.{
        .root_source_file = b.path("tests/syscheck.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rom", .module = rom_mod },
            .{ .name = "cpu", .module = cpu_mod },
            .{ .name = "machine", .module = machine_mod },
            .{ .name = "encode", .module = encode_mod },
        },
    });
    const syscheck_exe = b.addExecutable(.{
        .name = "syscheck",
        .root_module = syscheck_module,
    });
    const syscheck_run = b.addRunArtifact(syscheck_exe);
    syscheck_run.addFileArg(bios_rom);
    syscheck_run.addFileArg(hello83_raw);
    const systest_step = b.step("systest", "Block 12 e2e: the full syscall ABI + shell + autoboot");
    systest_step.dependOn(&syscheck_run.step);

    // The golden boot frame (task 12.16): two frames of the bare BIOS
    // must render the banner and READY. pixel-for-pixel. The hash was
    // computed once from the verified boot screen (decoded against the
    // ROM font) and pins the whole visible boot path.
    const bootgolden_run = b.addRunArtifact(harness_exe);
    bootgolden_run.addArg("--rom");
    bootgolden_run.addFileArg(bios_rom);
    bootgolden_run.addArgs(&.{
        "--frames",
        "2",
        "--golden",
        "68021ca11b9031ec3d2cfda8e7f590a0257418594497a009e8d83f033e12ded3",
        "--quiet",
    });
    boottest_step.dependOn(&bootgolden_run.step);

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
        asm_macro_mod,
        asm_codegen_mod,
        asm_objfile_mod,
        asm_listing_mod,
        lnk_loader_mod,
        lnk_script_mod,
        lnk_resolver_mod,
        lnk_relocator_mod,
        lnk_emitter_mod,
        genroms_module,
        harness_module,
    };
    for (test_modules) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    test_step.dependOn(&cmprom_run.step); // Block 10 e2e acceptance
    test_step.dependOn(&hello_run.step); // Block 11 e2e acceptance
    test_step.dependOn(&bootcheck_run.step); // Block 12 boot verification
    test_step.dependOn(&syscheck_run.step); // Block 12 syscalls/shell/autoboot
    test_step.dependOn(&bootgolden_run.step); // Block 12 golden boot frame
    test_step.dependOn(&bhello_run.step); // examples autoboot demo golden
}
