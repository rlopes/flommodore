/*
 * sdl3.h — thin C header wrapper for addTranslateC.
 *
 * In Zig 0.16, @cImport is removed.  build.zig runs addTranslateC on this
 * file and exposes the result as an importable module named "sdl3".
 * Source files use:
 *
 *   const sdl = @import("sdl3");
 *
 * instead of the old:
 *
 *   const sdl = @cImport(@cInclude("SDL3/SDL.h"));
 */
#include <SDL3/SDL.h>
