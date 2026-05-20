//! main.zig — Flommodore emulator entry point.
//!
//! Block 1 version: opens an SDL3 window and closes cleanly.
//! Stubs for the main emulation loop will be filled in by Block 5.
//!
//! Zig 0.16 notes:
//!   • @cImport is removed — SDL3 is imported via the "sdl3" module produced
//!     by addTranslateC in build.zig.
//!   • std.io.getStdOut() is gone — use std.debug.print for simple output,
//!     or the new std.Io interface for file I/O.

const std = @import("std");
// "sdl3" is the module produced by build.zig's addTranslateC step.
//const sdl = @import("sdl3");
const sdl = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {}); // We are providing our own entry point
    @cInclude("SDL3/SDL_main.h");
});

const util = @import("util.zig");
const bus = @import("bus.zig");
const cpu = @import("cpu.zig");
const vic256 = @import("vic256.zig");
const aur1 = @import("aur1.zig");
const io = @import("io.zig");
const debugger = @import("debugger.zig");

const log = util.log;

// ── Window defaults ──────────────────────────────────────────────────────────
// Native Flommodore resolution: 320×180 (16:9, pixel-doubled).
// Window is 4× that for a comfortable default on modern displays.
const WINDOW_TITLE = "Flommodore Fantasy Computer";
const WINDOW_WIDTH = 320 * 4; // 1280
const WINDOW_HEIGHT = 180 * 4; // 720

pub fn main() !void {
    log.info("Flommodore emulator — Block 1 scaffold (Zig 0.16)", .{});

    // ── SDL3 initialisation ──────────────────────────────────────────────────
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_AUDIO)) {
        log.err("SDL_Init failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow(
        WINDOW_TITLE,
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.SDL_WINDOW_RESIZABLE,
    ) orelse {
        log.err("SDL_CreateWindow failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlWindowFailed;
    };
    defer sdl.SDL_DestroyWindow(window);

    log.info("Window opened ({d}×{d}) — Block 1 OK", .{ WINDOW_WIDTH, WINDOW_HEIGHT });

    // ── Stub initialisation of all subsystems ────────────────────────────────
    // These are no-ops in Block 1.  Each module's real init() is implemented
    // in the corresponding block.
    bus.init();
    cpu.init();
    vic256.init();
    aur1.init();
    io.init();
    debugger.init();

    // ── Minimal event loop — exit on quit ────────────────────────────────────
    // The real emulation loop (timing, CPU ticks, frame render) is Block 5.
    var event: sdl.SDL_Event = undefined;
    var running = true;
    while (running) {
        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => running = false,
                sdl.SDL_EVENT_KEY_DOWN => {
                    if (event.key.scancode == sdl.SDL_SCANCODE_ESCAPE) {
                        running = false;
                    }
                },
                else => {},
            }
        }
        // Nothing to render yet — sleep to avoid burning CPU.
        sdl.SDL_Delay(16);
    }

    log.info("Clean exit.", .{});
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("test_memory.zig");
}
