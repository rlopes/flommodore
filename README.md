# Flommodore

A fully specified fantasy computer — Gab-16 CPU (16-bit RISC, 20-bit address
bus), VIC-256 video, AUR-1 sound, 512KB RAM — implemented as a reference
emulator and toolchain in **Zig 0.16** with **SDL3**.

**★ Milestone 3 — Interactive Machine — reached** (Block 8): the machine
listens. SDL3 keyboard events forward to the §5.3 scancode queue nearly
verbatim — SDL3 scancodes *are* USB HID usage-page 0x07 values — through a
filter that drops host-synthesised auto-repeats, consumer-page codes above
`$E7`, and the host-reserved keys (Escape quits, F12 is held for the Block 9
debugger). `KMOD` and the `KSTAT` caps/num bits mirror live host state; the
`KCTRL`-gated keyboard IRQ and the `JCTRL` any-transition joystick IRQ both
fire through the real controller. Gamepads hot-plug onto the two §5.4 ports
(d-pad + left stick with press/release hysteresis → directions, south/east
face buttons → fire 1/2), and WASD+Space always merges into joystick 1, so a
keyboard player needs no pad. The whole mapping layer (`src/input.zig`) is
SDL-free and unit-tested headlessly; the bus-level contract is pinned by
`test_io_kbd.rom`, driven by the harness's deterministic host-event
injection (`--key-at CYCLE:HHHH`, `--joy-at CYCLE:PORT:HH` — the exact
schedule is documented on the ROM's builder in `tests/genroms.zig`).

**Block 7 — First Sound — complete**: the AUR-1 synthesises. Four voices
with seven waveforms (comptime sine, square, triangle, saw, pulse-width,
Galois-LFSR noise, RAM wavetables), linear SID-table ADSR with envelope-
completion IRQs, ring mod, hard sync, OPL-style FM pairs with feedback, and
a shared Chamberlin SVF filter — all-integer and bit-deterministic, so the
golden audio hashes in `tests/goldens.txt` hold across hosts (verified in
CI via `harness --audio-golden`; `--dump-wav` regenerates listenable/
plottable output). The chip ticks per master cycle (software PCM per Phase
4 §4.9 works), yields exactly 735 stereo samples per frame, and streams to
SDL3 with queue-depth management: 60 s at 60.000 fps, queue bounded, zero
drops.

**Milestone 2 — First Pixels — reached** (Block 6): the VIC-256 renders.
All four display modes (bitmap 8/4/1bpp, tile with fine scroll, bitmap+tile
overlay, ROM-font text), 64 sprites with flips/sizes/priority/collision and
the authentic 8-per-scanline limit, double buffering via VSWAP, and — the
architecture proof — raster IRQs evaluated per scanline quantum: a copper
chain splitting the background colour mid-frame renders pixel-exactly and is
pinned by golden SHA-256 frame hashes (`tests/goldens.txt`, verified in CI
via `harness --frames N --golden HEX`; `--dump-ppm` regenerates the frames
for eyeballing).

**Milestone 1 — First Execution — reached** (Blocks 1–5): the machine runs.
The scanline-quantum main loop executes exactly 240,000 cycles/frame at a
measured 60.000 fps over 60 s, the CPU boots from the ROM RESET vector,
timers tick, IRQs fire, and `.flapp` programs load and run standalone:

```sh
zig build -Doptimize=ReleaseFast     # Debug is cycle-exact but below real time
./zig-out/bin/flommodore --rom tests/roms/nop_loop.rom
./zig-out/bin/flommodore tests/roms/test_prog.flapp
```

Next: Block 9 — debugger (console first) and Block 10 — assembler → ★ Milestone 4.

## Build

Requires Zig **0.16.0** exactly. SDL3 is fetched and built from source by the
Zig package manager (castholm/SDL) — no system packages needed.

```sh
zig build            # build zig-out/bin/flommodore (and the headless harness)
zig build run        # open the (empty) Flommodore window; ESC or close to quit
zig build test       # unit tests
zig build genroms    # emit generated test ROMs into tests/roms/
zig build harness -- --rom tests/roms/test_cpu_alu.rom --max-cycles 240000 --expect-pass
```

Cross-compilation:

```sh
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-macos      # macOS host only (needs the Apple SDK)
```

## Spec

Implementation follows the v1.1 spec amendment (LOCKED), which supersedes the
v1.0 phase documents wherever they disagree, plus the v1.2 amendment
(`docs/flommodore-spec-amendment-v1_2.md`) covering the points the Block 2–3
implementation surfaced: trap resume PC, shift domains, unsigned DIV/MOD,
20-bit CYC, the completed privilege matrix (supervisor-only RTI, user-ignored
SEI/CLI), user-mode entry, and I/O byte-write/straddle composition (D36–D47).
