//! Flommodore — `main.zig` (Blocks 5, 8, 9).
//!
//! The emulator: machine composition, the **scanline-quantum main loop**
//! (plan 5.1), SDL3 window and events (5.3), 60 Hz frame pacing (5.4),
//! `.flapp` loading (5.5), host input forwarding (Block 8 — the SDL
//! boundary; the mapping itself lives in input.zig), and the debugger
//! shell (Block 9 — the monitor itself lives in debugger.zig).
//!
//! CLI (Phase 8 §8.10 subset; `--listing` tooling arrives with Block 10/11):
//!   flommodore [--rom file.rom] [program.flapp] [--max-frames N]
//!              [--debug] [--sym file.flsym]
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
//!
//! Block 9 wraps the same loop: while the debugger is armed, frames run
//! through Debugger.runSlice → Machine.stepFrameCycle (identical timing);
//! paused iterations poll the console and event queue at ~100 Hz and keep
//! presenting the (possibly partial) frame.

const std = @import("std");
const sdl = @import("sdl3");

const util = @import("util");
const rom_mod = @import("rom");
const cpu_mod = @import("cpu");
const flapp = @import("flapp");
const input_mod = @import("input");
const machine_mod = @import("machine");
const Machine = machine_mod.Machine;
const debugger_mod = @import("debugger"); // Block 9

/// Window size: 3× the fallback mode; SDL logical presentation letterboxes
/// whatever resolution the VIC is actually running (Block 6).
const initial_window_width = 960;
const initial_window_height = 540;

const frame_ns: u64 = 1_000_000_000 / util.frame_rate_hz; // 16,666,666 ns
/// Audio queue management (task 7.21): one frame of stereo S16 at 44.1 kHz
/// is 735 × 4 = 2940 bytes. Prime 2 frames of silence for a latency
/// cushion; drop a frame's audio if the queue exceeds 8 frames (~133 ms) —
/// production and consumption match on average because the pacer holds
/// 60 Hz, so the queue only drifts on host clock mismatch.
const audio_frame_bytes: usize = 735 * 2 * 2;
const audio_high_water: c_int = @intCast(8 * audio_frame_bytes);
/// Sleep coarse until this close to the deadline, then spin (task 5.4).
const spin_margin_ns: u64 = 1_500_000;

// ---------------------------------------------------------------------------
// SDL → machine translation (Block 8). Everything below the event loop is
// SDL-free (input.zig), so these two helpers are the entire boundary.
// ---------------------------------------------------------------------------

/// SDL_Keymod snapshot → input.zig terms. SDL_KMOD_CAPS/NUM reflect the
/// host lock *state* — exactly the G19 "mirror the host LEDs" requirement.
fn modsFromSdl(mods: sdl.SDL_Keymod) input_mod.Mods {
    return .{
        .shift = (mods & sdl.SDL_KMOD_SHIFT) != 0,
        .ctrl = (mods & sdl.SDL_KMOD_CTRL) != 0,
        .alt = (mods & sdl.SDL_KMOD_ALT) != 0,
        .gui = (mods & sdl.SDL_KMOD_GUI) != 0,
        .caps = (mods & sdl.SDL_KMOD_CAPS) != 0,
        .num = (mods & sdl.SDL_KMOD_NUM) != 0,
    };
}

/// SDL_GamepadButton → the §5.4 inputs (task 8.6): dpad → directions,
/// south face button (Xbox A) → fire 1, east (Xbox B) → fire 2. Everything
/// else has no 9-pin equivalent and is dropped.
fn padButtonFromSdl(button: u8) ?input_mod.PadButton {
    return switch (@as(c_int, button)) {
        sdl.SDL_GAMEPAD_BUTTON_DPAD_UP => .dpad_up,
        sdl.SDL_GAMEPAD_BUTTON_DPAD_DOWN => .dpad_down,
        sdl.SDL_GAMEPAD_BUTTON_DPAD_LEFT => .dpad_left,
        sdl.SDL_GAMEPAD_BUTTON_DPAD_RIGHT => .dpad_right,
        sdl.SDL_GAMEPAD_BUTTON_SOUTH => .fire1,
        sdl.SDL_GAMEPAD_BUTTON_EAST => .fire2,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Debugger console (Block 9). Stdin blocks, SDL must not: a detached reader
// thread queues complete lines; the paused main loop polls the queue while
// keeping the window responsive. EOF closes the console — the main loop
// treats "paused + closed + empty" as quit, so piped command scripts
// terminate instead of hanging.
// ---------------------------------------------------------------------------

const Console = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    lines: std.ArrayList([]u8) = .empty,
    closed: bool = false,

    fn readerMain(con: *Console) void {
        var buf: [512]u8 = undefined;
        var rdr = std.Io.File.stdin().readerStreaming(con.io, &buf);
        while (true) {
            const line = rdr.interface.takeDelimiterExclusive('\n') catch break;
            const copy = con.gpa.dupe(u8, line) catch break;
            con.mutex.lockUncancelable(con.io);
            con.lines.append(con.gpa, copy) catch {
                con.mutex.unlock(con.io);
                con.gpa.free(copy);
                break;
            };
            con.mutex.unlock(con.io);
        }
        con.mutex.lockUncancelable(con.io);
        con.closed = true;
        con.mutex.unlock(con.io);
    }

    /// Pop one queued line; the caller owns (and frees) it.
    fn pop(con: *Console) ?[]u8 {
        con.mutex.lockUncancelable(con.io);
        defer con.mutex.unlock(con.io);
        if (con.lines.items.len == 0) return null;
        return con.lines.orderedRemove(0);
    }

    /// True once stdin hit EOF and every queued line was consumed.
    fn isClosed(con: *Console) bool {
        con.mutex.lockUncancelable(con.io);
        defer con.mutex.unlock(con.io);
        return con.closed and con.lines.items.len == 0;
    }
};

/// "<flapp path minus extension>.flsym" — the master spec §8.7 auto-load
/// companion. Arena-allocated; null only on OOM.
fn symPathFor(arena: std.mem.Allocator, flapp_path: []const u8) ?[]const u8 {
    const stem_len = std.mem.lastIndexOfScalar(u8, flapp_path, '.') orelse flapp_path.len;
    return std.fmt.allocPrint(arena, "{s}.flsym", .{flapp_path[0..stem_len]}) catch null;
}

fn loadSymbolFile(
    io: std.Io,
    arena: std.mem.Allocator,
    dbg: *debugger_mod.Debugger,
    path: []const u8,
    explicit: bool,
) void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| {
        // A missing auto-load companion is normal; a missing --sym file is
        // worth a warning.
        if (explicit) util.logWarn("--sym {s}: {t}", .{ path, err });
        return;
    };
    const n = dbg.loadSymbols(text) catch 0;
    util.logInfo("symbols: {s} — {d} loaded", .{ path, n });
}

// ---------------------------------------------------------------------------
// CLI.
// ---------------------------------------------------------------------------

const Options = struct {
    rom_path: ?[]const u8 = null,
    flapp_path: ?[]const u8 = null,
    /// Exit after N frames and report measured pacing (task 5.4 acceptance;
    /// 0 = run until quit).
    max_frames: u64 = 0,
    /// Block 9: start paused in the console debugger.
    debug: bool = false,
    /// Block 9: load a .flsym symbol file (master spec §8.7). Overrides the
    /// auto-load companion beside the .flapp.
    sym_path: ?[]const u8 = null,
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
        } else if (std.mem.eql(u8, arg, "--debug")) {
            opts.debug = true;
        } else if (std.mem.eql(u8, arg, "--sym")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.sym_path = args[i];
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
        util.logErr("usage: flommodore [--rom file.rom] [program.flapp] [--max-frames N] [--debug] [--sym file.flsym]", .{});
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

    // Debugger (Block 9): console-first monitor. Costs nothing until armed
    // (--debug or F12) — the unarmed loop below calls runFrame() directly.
    var dbg = debugger_mod.Debugger.init(gpa, machine);
    defer dbg.deinit();
    dbg.attach();
    if (opts.debug) dbg.requestPause(); // stop before the first instruction

    // Symbols (.flsym, master spec §8.7): --sym, or else the auto-load
    // companion sitting beside the .flapp.
    if (opts.sym_path) |path| {
        loadSymbolFile(io, arena, &dbg, path, true);
    } else if (opts.flapp_path) |path| {
        if (symPathFor(arena, path)) |sym_path| {
            loadSymbolFile(io, arena, &dbg, sym_path, false);
        }
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

    // Audio stream (tasks 7.2/7.21). Failure is non-fatal: the machine
    // runs silent (headless CI, missing audio hardware).
    const audio_spec = sdl.SDL_AudioSpec{
        .format = sdl.SDL_AUDIO_S16,
        .channels = 2,
        .freq = 44_100,
    };
    var audio: ?*sdl.SDL_AudioStream = null;
    if (sdl.SDL_Init(sdl.SDL_INIT_AUDIO)) {
        audio = sdl.SDL_OpenAudioDeviceStream(sdl.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &audio_spec, null, null);
        if (audio) |stream| {
            const silence = [_]i16{0} ** (2 * audio_frame_bytes / 2);
            _ = sdl.SDL_PutAudioStreamData(stream, &silence, @intCast(silence.len * 2));
            _ = sdl.SDL_ResumeAudioStreamDevice(stream);
            util.logInfo("audio: stereo S16 44.1 kHz", .{});
        } else {
            util.logWarn("audio unavailable: {s}", .{sdl.SDL_GetError()});
        }
    } else {
        util.logWarn("SDL audio init failed: {s} — running silent", .{sdl.SDL_GetError()});
    }
    defer if (audio) |stream| sdl.SDL_DestroyAudioStream(stream);

    var queue_min: c_int = std.math.maxInt(c_int);
    var queue_max: c_int = 0;
    var audio_drops: u64 = 0;

    // Host input (Block 8). The gamepad subsystem is optional the same way
    // audio is: a headless/driverless host still runs, keyboard-only.
    if (!sdl.SDL_InitSubSystem(sdl.SDL_INIT_GAMEPAD)) {
        util.logWarn("SDL gamepad init failed: {s} — keyboard input only", .{sdl.SDL_GetError()});
    }
    var input = input_mod.Input.init(machine.io);
    input.syncModifiers(modsFromSdl(sdl.SDL_GetModState())); // seed lock state
    // SDL handles for the pads assigned to the two ports (input.zig owns
    // the port assignment; SDL only delivers events for opened gamepads).
    var pad_handles: [2]?*sdl.SDL_Gamepad = .{ null, null };
    defer for (pad_handles) |h| {
        if (h) |g| sdl.SDL_CloseGamepad(g);
    };

    // Debugger console plumbing: a stdout writer for monitor output; the
    // stdin reader thread spawns lazily on the first pause.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const dout = &stdout_writer.interface;
    var console_store: Console = undefined;
    var console: ?*Console = null;

    util.logInfo("Flommodore running — 14.4 MHz, 240,000 cycles/frame, 60 Hz", .{});

    // ------------------------------------------------------------------
    // Main loop.
    // ------------------------------------------------------------------
    var start_ns = sdl.SDL_GetTicksNS();
    var frames: u64 = 0;
    var running = true;
    var need_prompt = true;
    var rebase_needed = false;
    while (running) {
        var frame_completed = false;
        var just_stopped = false;

        if (!dbg.armed) {
            // Fast path — identical to the pre-debugger loop.
            machine.runFrame();
            frame_completed = true;
        } else if (dbg.paused) {
            rebase_needed = true; // the pacing deadline series is stale now
            if (console == null) {
                console_store = .{ .gpa = gpa, .io = io };
                console = &console_store;
                if (std.Thread.spawn(.{}, Console.readerMain, .{&console_store})) |thread| {
                    thread.detach();
                } else |err| {
                    util.logWarn("console reader thread failed: {t} — only F12/ESC work", .{err});
                }
                dout.print("Flommodore debugger — h for help; F12 toggles pause; q quits\n", .{}) catch {};
                need_prompt = true;
            }
            if (need_prompt) {
                dout.print("dbg> ", .{}) catch {};
                dout.flush() catch {};
                need_prompt = false;
            }
            if (console) |con| {
                while (con.pop()) |line| {
                    dbg.execute(line, dout);
                    gpa.free(line);
                    need_prompt = true;
                    if (!dbg.paused or dbg.quit) break;
                }
                dout.flush() catch {};
                if (dbg.paused and !dbg.quit and con.isClosed()) {
                    util.logInfo("stdin closed while paused — quitting", .{});
                    dbg.quit = true;
                }
            }
            if (dbg.paused and !dbg.quit) sdl.SDL_DelayNS(10 * 1_000_000);
        } else {
            if (rebase_needed) {
                // Resume: rebase the pacing series so the loop doesn't
                // sprint to catch up on time spent paused. (Prior frames
                // are accounted as if they ran at exactly 60 Hz.)
                start_ns = sdl.SDL_GetTicksNS() -| frames * frame_ns;
                rebase_needed = false;
            }
            const r = dbg.runSlice();
            frame_completed = r.frame_done;
            just_stopped = r.stopped;
            if (r.stopped) {
                dbg.reportStop(dout);
                dout.flush() catch {};
                need_prompt = true;
            }
        }
        if (frame_completed) frames += 1;

        // Present (Block 6): copy the VIC's RGB24 buffer into a streaming
        // texture sized to this frame's resolution; letterbox to the window.
        // Also runs on a mid-frame stop (the partially rendered frame is
        // exactly what a raster debugger wants to see) and on paused ticks
        // (window liveness while the console waits).
        if (frame_completed or just_stopped or dbg.paused) {
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
        }

        // Audio push (task 7.21): this frame's samples, unless the queue
        // is already deep (drop instead of growing latency without bound).
        // Real frame boundaries only — a paused machine produces no new
        // samples, and a mid-frame stop must not clear a partial batch.
        if (frame_completed) {
            if (audio) |stream| {
                const queued = sdl.SDL_GetAudioStreamQueued(stream);
                queue_min = @min(queue_min, queued);
                queue_max = @max(queue_max, queued);
                if (queued <= audio_high_water) {
                    _ = sdl.SDL_PutAudioStreamData(
                        stream,
                        &machine.aur.samples,
                        @intCast(machine.aur.sample_count * 2),
                    );
                } else {
                    audio_drops += 1;
                }
            }
            machine.aur.clearSamples();
        }

        // Events (task 5.3): polled every iteration so quit/F12 stay prompt
        // even while paused. Enqueuing at the frame boundary bounds input
        // latency at one frame (~16.7 ms) — indistinguishable from hardware
        // keyboard latency.
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => running = false,
                sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_EVENT_KEY_UP => {
                    // F12 toggles the debugger (Phase 7 §7.11; input.zig
                    // decision j reserves it from the guest).
                    if (event.key.scancode == sdl.SDL_SCANCODE_F12) {
                        if (event.key.down and !event.key.repeat) {
                            if (dbg.paused) dbg.resumeRun() else dbg.requestPause();
                        }
                        continue;
                    }
                    // Escape is host-reserved: quit (task 5.3, input.zig
                    // decision j — never forwarded to the guest).
                    if (event.key.scancode == sdl.SDL_SCANCODE_ESCAPE) {
                        if (event.key.down) running = false;
                        continue;
                    }
                    // A paused machine is frozen: swallow guest input.
                    if (!dbg.paused) {
                        // KMOD/lock state first, so a program woken by the
                        // key IRQ reads modifiers consistent with its
                        // scancode.
                        input.syncModifiers(modsFromSdl(event.key.mod));
                        input.keyEvent(event.key.scancode, event.key.down, event.key.repeat);
                    }
                },
                sdl.SDL_EVENT_GAMEPAD_ADDED => {
                    const id = event.gdevice.which;
                    if (input.padAdded(id)) |port| {
                        pad_handles[port] = sdl.SDL_OpenGamepad(id);
                        if (pad_handles[port] == null) {
                            util.logWarn("gamepad open failed: {s}", .{sdl.SDL_GetError()});
                            _ = input.padRemoved(id);
                        } else {
                            util.logInfo("gamepad {d} → joystick port {d}", .{ id, @as(u8, port) + 1 });
                        }
                    }
                },
                sdl.SDL_EVENT_GAMEPAD_REMOVED => {
                    const id = event.gdevice.which;
                    if (input.padRemoved(id)) |port| {
                        if (pad_handles[port]) |g| sdl.SDL_CloseGamepad(g);
                        pad_handles[port] = null;
                        util.logInfo("gamepad {d} left port {d}", .{ id, @as(u8, port) + 1 });
                    }
                },
                sdl.SDL_EVENT_GAMEPAD_BUTTON_DOWN, sdl.SDL_EVENT_GAMEPAD_BUTTON_UP => {
                    if (!dbg.paused) {
                        if (padButtonFromSdl(event.gbutton.button)) |button| {
                            input.padButton(event.gbutton.which, button, event.gbutton.down);
                        }
                    }
                },
                sdl.SDL_EVENT_GAMEPAD_AXIS_MOTION => {
                    if (!dbg.paused) {
                        switch (@as(c_int, event.gaxis.axis)) {
                            sdl.SDL_GAMEPAD_AXIS_LEFTX => input.padAxisX(event.gaxis.which, event.gaxis.value),
                            sdl.SDL_GAMEPAD_AXIS_LEFTY => input.padAxisY(event.gaxis.which, event.gaxis.value),
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        if (machine.io.power_off) {
            util.logInfo("SYSPWR soft power-off", .{});
            running = false;
        }
        if (dbg.quit) running = false;
        if (opts.max_frames != 0 and frames >= opts.max_frames) running = false;

        // Pacing (task 5.4): sleep coarse, spin the remainder — only ever
        // here, at a completed frame boundary. Integer deadline arithmetic
        // keeps 60 Hz exact over any horizon (no drift accumulation).
        if (frame_completed) {
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
            // Behind schedule: no sleep — the next frame starts immediately
            // and the fixed deadline series absorbs transient lag. (A
            // persistently slow host simply runs below 60 Hz; emulation
            // stays deterministic because pacing never touches machine
            // state.)
        }
    }

    // start_ns is rebased after debugger pauses (paused wall time excluded,
    // prior frames accounted at exactly 60 Hz), so fps stays meaningful.
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
    if (audio != null and queue_max > 0) {
        // Task 7.21 acceptance evidence: the queue must stay inside a
        // bounded window over long runs — no underrun collapse to 0 while
        // producing, no unbounded latency growth.
        util.logInfo("audio queue depth: min {d} B, max {d} B, {d} frame drops", .{ queue_min, queue_max, audio_drops });
    }
}
