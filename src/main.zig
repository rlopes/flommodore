//! Flommodore — `main.zig` (Block 5).
//!
//! The emulator: machine composition, the **scanline-quantum main loop**
//! (plan 5.1), SDL3 window and events (5.3), 60 Hz frame pacing (5.4), and
//! `.flapp` loading (5.5).
//!
//! CLI (Phase 8 §8.10 subset — `--debug`/`--sym` arrive with Block 9/11):
//!   flommodore [--rom file.rom] [program.flapp] [--max-frames N]
//!
//! Loop structure (per frame, exactly 240,000 cycles — D17/D41):
//!   for each of TOTAL_LINES scanlines:
//!     run CYCLES_PER_LINE cycles: sample IRQ line → CPU step → device tick
//!     ── scanline hook: the VIC-256 renders this line and may raise the
//!        raster IRQ here (Block 6)
//!   frame end: VBLANK/present (Block 6), audio push (Block 7),
//!              SDL event poll, pacing sleep
//! Pacing never sleeps inside a scanline quantum (5.4): the frame runs
//! flat-out, then sleeps coarse + spins the remainder at the boundary.

const std = @import("std");
const sdl = @import("sdl3");

const util = @import("util");
const rom_mod = @import("rom");
const cpu_mod = @import("cpu");
const flapp = @import("flapp");
const machine_mod = @import("machine");
const Machine = machine_mod.Machine;

const aur1 = @import("aur1.zig"); // Block 7
const debugger = @import("debugger.zig"); // Block 9

// Force semantic analysis of not-yet-implemented stubs (Zig analyses
// lazily; an unreferenced file is never checked).
comptime {
    _ = &aur1.init;
    _ = &debugger.init;
}

/// Window size: 3× the fallback mode; SDL logical presentation letterboxes
/// whatever resolution the VIC is actually running (Block 6).
const initial_window_width = 960;
const initial_window_height = 540;

const frame_ns: u64 = 1_000_000_000 / util.frame_rate_hz; // 16,666,666 ns
/// Sleep coarse until this close to the deadline, then spin (task 5.4).
const spin_margin_ns: u64 = 1_500_000;

// ---------------------------------------------------------------------------
// CLI.
// ---------------------------------------------------------------------------

const Options = struct {
    rom_path: ?[]const u8 = null,
    flapp_path: ?[]const u8 = null,
    /// Exit after N frames and report measured pacing (task 5.4 acceptance;
    /// 0 = run until quit).
    max_frames: u64 = 0,
};

fn parseArgs(args: []const []const u8) !Options {
    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--rom")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.rom_path = args[i];
        } else if (std.mem.eql(u8, arg, "--max-frames")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.max_frames = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownArgument;
        } else {
            if (opts.flapp_path != null) return error.TooManyPositionals;
            opts.flapp_path = args[i];
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(args) catch {
        util.logErr("usage: flommodore [--rom file.rom] [program.flapp] [--max-frames N]", .{});
        return error.BadUsage;
    };

    const machine = try Machine.create(gpa);
    defer machine.destroy(gpa);

    // --rom: the BIOS/test image the CPU resets into.
    if (opts.rom_path) |path| {
        try machine.rom.loadFromFile(io, std.Io.Dir.cwd(), path);
        util.logInfo("ROM loaded: {s}", .{path});
    }
    machine.cpu.reset(&machine.bus);

    // Positional .flapp: load and run standalone (task 5.5). Until the BIOS
    // exists (Block 12) the emulator provides the boot environment the BIOS
    // would have established (D12): SP $01100, SSP $020F0, IVT $FFFC0.
    if (opts.flapp_path) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        const entry = flapp.load(&machine.bus, bytes) catch |err| {
            util.logErr(".flapp load failed: {t}", .{err});
            return err;
        };
        machine.cpu.setReg(cpu_mod.Gab16.sp, 0x01100);
        machine.cpu.ssp = 0x020F0;
        machine.cpu.usp = 0x01100;
        machine.cpu.ivt = 0xFFFC0;
        machine.cpu.pc = entry;
        util.logInfo(".flapp loaded: {s} → entry ${X:0>5}", .{ path, entry });
    } else if (opts.rom_path == null) {
        util.logWarn("no ROM or .flapp given — the machine will trap through an empty vector table", .{});
    }

    // SDL window (Block 1 scaffold, now framing the machine loop).
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
        util.logErr("SDL_Init failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow(
        "Flommodore",
        initial_window_width,
        initial_window_height,
        sdl.SDL_WINDOW_RESIZABLE,
    ) orelse {
        util.logErr("SDL_CreateWindow failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlCreateWindowFailed;
    };
    defer sdl.SDL_DestroyWindow(window);
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse {
        util.logErr("SDL_CreateRenderer failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlCreateRendererFailed;
    };
    defer sdl.SDL_DestroyRenderer(renderer);
    var texture: ?*sdl.SDL_Texture = null;
    var tex_w: u32 = 0;
    var tex_h: u32 = 0;
    defer if (texture) |t| sdl.SDL_DestroyTexture(t);

    util.logInfo("Flommodore running — 14.4 MHz, 240,000 cycles/frame, 60 Hz", .{});

    // ------------------------------------------------------------------
    // Main loop.
    // ------------------------------------------------------------------
    const start_ns = sdl.SDL_GetTicksNS();
    var frames: u64 = 0;
    var running = true;
    while (running) {
        machine.runFrame();
        frames += 1;

        // Present (Block 6): copy the VIC's RGB24 buffer into a streaming
        // texture sized to this frame's resolution; letterbox to the window.
        const vw = machine.vic.visibleWidth();
        const vh = machine.vic.visibleHeight();
        if (texture == null or vw != tex_w or vh != tex_h) {
            if (texture) |t| sdl.SDL_DestroyTexture(t);
            texture = sdl.SDL_CreateTexture(
                renderer,
                sdl.SDL_PIXELFORMAT_RGB24,
                sdl.SDL_TEXTUREACCESS_STREAMING,
                @intCast(vw),
                @intCast(vh),
            );
            tex_w = vw;
            tex_h = vh;
            _ = sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_NEAREST);
            _ = sdl.SDL_SetRenderLogicalPresentation(
                renderer,
                @intCast(vw),
                @intCast(vh),
                sdl.SDL_LOGICAL_PRESENTATION_LETTERBOX,
            );
        }
        if (texture) |t| {
            _ = sdl.SDL_UpdateTexture(t, null, &machine.vic.rgb, @intCast(vw * 3));
            _ = sdl.SDL_RenderClear(renderer);
            _ = sdl.SDL_RenderTexture(renderer, t, null, null);
            _ = sdl.SDL_RenderPresent(renderer);
        }

        // Frame-end actions (task 5.3): events first, so quit is prompt.
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => running = false,
                sdl.SDL_EVENT_KEY_DOWN => {
                    if (event.key.key == sdl.SDLK_ESCAPE) running = false;
                },
                else => {},
            }
        }
        if (machine.io.power_off) {
            util.logInfo("SYSPWR soft power-off", .{});
            running = false;
        }
        if (opts.max_frames != 0 and frames >= opts.max_frames) running = false;

        // Pacing (task 5.4): sleep coarse, spin the remainder — only ever
        // here, at the frame boundary. Integer deadline arithmetic keeps
        // 60 Hz exact over any horizon (no drift accumulation).
        const deadline = start_ns + frames * frame_ns;
        var now = sdl.SDL_GetTicksNS();
        if (now < deadline) {
            if (deadline - now > spin_margin_ns) {
                sdl.SDL_DelayNS(deadline - now - spin_margin_ns);
            }
            while (true) {
                now = sdl.SDL_GetTicksNS();
                if (now >= deadline) break;
            }
        }
        // Behind schedule: no sleep — the next frame starts immediately and
        // the fixed deadline series absorbs transient lag. (A persistently
        // slow host simply runs below 60 Hz; emulation stays deterministic
        // because pacing never touches machine state.)
    }

    const elapsed_ns = sdl.SDL_GetTicksNS() - start_ns;
    if (frames > 0 and elapsed_ns > 0) {
        const fps = @as(f64, @floatFromInt(frames)) * 1e9 / @as(f64, @floatFromInt(elapsed_ns));
        util.logInfo("{d} frames in {d} ms — {d:.3} fps; CPU cycles {d}", .{
            frames,
            elapsed_ns / 1_000_000,
            fps,
            machine.cpu.cyc,
        });
    }
}
