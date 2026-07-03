//! Flommodore — `main.zig` (Block 1).
//!
//! Entry point. For Block 1 this opens an SDL3 window titled "Flommodore",
//! polls events, and exits cleanly on window close or ESC (task 1.2).
//! The emulator main loop (scanline-quantum scheduling, 240,000 cycles/frame)
//! arrives in Block 5.

const std = @import("std");
const sdl = @import("sdl3");

const util = @import("util.zig");
const bus = @import("bus.zig");
const ram = @import("ram.zig");
const rom = @import("rom.zig");
const cpu = @import("cpu.zig");
const vic256 = @import("vic256.zig");
const aur1 = @import("aur1.zig");
const io = @import("io.zig");
const debugger = @import("debugger.zig");
const encode = @import("encode.zig");

// Force semantic analysis of every stub so dead modules can't rot between
// blocks (Zig 0.16 analyses lazily; an unreferenced file is never checked).
comptime {
    _ = &bus.init;
    _ = &ram.init;
    _ = &rom.init;
    _ = &cpu.init;
    _ = &vic256.init;
    _ = &aur1.init;
    _ = &io.init;
    _ = &debugger.init;
    _ = &encode.init;
    _ = &util.maskAddr;
}

/// Initial window size. Placeholder until the VIC-256 render pipeline
/// (Block 6) fixes the framebuffer dimensions per display mode.
const initial_window_width = 960;
const initial_window_height = 540;

pub fn main() !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
        util.logErr("SDL_Init failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow(
        "Flommodore",
        initial_window_width,
        initial_window_height,
        0,
    ) orelse {
        util.logErr("SDL_CreateWindow failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlCreateWindowFailed;
    };
    defer sdl.SDL_DestroyWindow(window);

    util.logInfo("Flommodore Block 1 scaffold — window open; close or press ESC to quit", .{});

    var running = true;
    while (running) {
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
        // Nothing to render yet; don't spin a core while idle.
        sdl.SDL_Delay(10);
    }
}
