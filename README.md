# Flommodore

A fully specified fantasy computer — Gab-16 CPU (16-bit RISC, 20-bit address
bus), VIC-256 video, AUR-1 sound, 512KB RAM — implemented as a reference
emulator and toolchain in **Zig 0.16** with **SDL3**.

**★ Milestone 5 — Complete Machine — reached** (Block 12): the machine
has firmware and a voice. `src/bios/bios.asm` — 3.8KB of Flommodore
assembly built by the machine's own toolchain (`zig build bios`) — boots
through all six §6.8 stages to the banner and the `READY.` shell, with
all 29 system calls live behind the permanent `$FC100` jump table:
console (80×43 text, scroll, cursor), keyboard (HID-to-ASCII with shift,
line editing), video (modes, palette, VBLANK, FILLSCR), sound (AUR-1
one-call-one-note), memory, timers, and the IRQ dispatcher with
CALL/RET handlers via `SYS_IRQSET`. Autoboot probes `$04100` for the
`.flapp` `FB` header and runs what it finds. Three verifiers pin it:
`boottest` (every stage 1–6 postcondition plus a golden boot frame),
`systest` (the whole ABI exercised by host-injected calls, ~130 checks,
ending with the published §8.3 `hello.asm` typed into the shell as `RUN
4100` and printing through `SYS_PUTSTR`), and the five VIC/AUR goldens
untouched. The ImGui debug panels (9.12–9.14) remain the one deferred
nicety.

**★ Milestone 4 — Working Toolchain — reached** (Blocks 10–11): the
machine programs itself. `flas` assembles the full Phase 8 language —
two-pass, macros, INCLUDE, EQU expressions, listings — onto the same
`encode.zig` opcode table the emulator and disassembler share, so one
truth encodes and decodes. `fll` links `.flobj` objects through `.flld`
linker scripts into `.flapp` executables (with `.flsym` symbols for the
debugger) or, with `--raw`, into bare ROM images. Both ends are pinned:
`asmtest` proves flas output byte-identical to the generated golden ROM,
and `hellotest` assembles, links, and runs `examples/hello.asm` to a
golden frame hash in the headless harness.

**Block 9 — Debugger — console monitor complete**: the machine is
inspectable. `--debug` (or F12 in the window) drops into a console
monitor: registers, symbol-annotated disassembly built on the shared
`encode.zig` opcode table, hex+ASCII memory dumps through a
side-effect-free peek path (inspecting KDATA cannot dequeue the keyboard
queue or trip your own watchpoints), single-step, step-over CALL/CALLA,
16 breakpoints, bus-level read/write watchpoints, and `.flsym` symbol
loading (`--sym`, plus auto-load beside the `.flapp`). Paused and stepped
execution drive the exact `Machine.stepFrameCycle` path as free running —
timing is bit-identical, and pausing mid-frame presents the partially
rendered frame, so raster effects are directly inspectable. Traps break
into the monitor only while the debugger is armed (decision k in
`src/debugger.zig`) — architectural BRK-vector use by guest programs is
untouched. The debugger core is SDL-free and unit-tested headlessly. The
ImGui overlay (plan 9.12–9.14) remains a second pass; the 9.1 cimgui
spike is deferred to a display-equipped environment — per audit P5 the
console monitor is the primary deliverable regardless.

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

★ Milestone 5 reached — the Flommodore is a complete machine. Ideas
beyond the plan: the FL language (a future phase), storage for `LOAD`,
and the deferred ImGui debug panels.

## Build

Requires Zig **0.16.0** exactly. SDL3 is fetched and built from source by the
Zig package manager (castholm/SDL) — no system packages needed.

```sh
zig build            # build zig-out/bin/flommodore (and the headless harness)
zig build run        # open the (empty) Flommodore window; ESC or close to quit
zig build test       # unit tests + asmtest/hellotest/boottest/systest e2e
zig build genroms    # emit generated test ROMs into tests/roms/
zig build bios       # flas+fll the BIOS into rom/flommodore.rom
zig build boottest   # BIOS boots to READY (§6.8 stages 1–6 + golden frame)
zig build systest    # the full syscall ABI + shell + autoboot, end to end
zig build harness -- --rom tests/roms/test_cpu_alu.rom --max-cycles 240000 --expect-pass
```

Cross-compilation:

```sh
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-macos      # macOS host only (needs the Apple SDK)
```

## Running the BIOS

The firmware is a build product — `zig build bios` assembles
`src/bios/bios.asm` with the project's own flas and frames the 16KB image
with `fll --raw --base $FC000 --size 16K` into `rom/flommodore.rom`. Boot
it in the emulator:

```sh
zig build bios
./zig-out/bin/flommodore --rom rom/flommodore.rom
```

This is the complete machine: the boot banner, the `READY.` shell
(`MEM`, `POKE`, `PEEK`, `RUN`, `LOAD`, `RESET`, `VER`, `HELP` — hex
arguments, optional `$`), and autoboot: a valid `.flapp` at `$04100`
starts automatically and drops back to `READY.` if it returns. Type
`RUN 4100` to start a loaded program by hand; the published Phase 8
§8.3 `hello.asm` runs exactly as printed.

Headless (no SDL — CI, servers, containers):

```sh
zig build harness -- --rom rom/flommodore.rom --frames 2 --dump-ppm boot.ppm
```

and the boot-state verifiers run against a freshly built image any time via
`zig build boottest` and `zig build systest`.

## Debugger

```sh
./zig-out/bin/flommodore --debug program.flapp        # start paused at entry
./zig-out/bin/flommodore --debug --sym prog.flsym --rom custom.rom
```

F12 pauses/resumes at any time; a `prog.flsym` sitting beside `prog.flapp`
auto-loads (master spec §8.7). Commands at the `dbg>` prompt:

| Command | Action |
|---|---|
| `r` | registers: R0–R15, PC, FLAGS, SP, LR, SSP, USP, IVT, CYC |
| `d [ADDR] [N]` | disassemble (defaults: PC, 8) — symbols annotate labels and targets |
| `m ADDR [LEN]` | hex + ASCII memory dump (side-effect-free; KDATA is peeked) |
| `s [N]` | step N instructions |
| `n` | step over CALL/CALLA |
| `c` | continue at full speed |
| `b ADDR` / `bl` / `bc N\|all` | breakpoints (16, Phase 7 §7.11) |
| `w ADDR [r\|w\|rw]` / `wl` / `wc N\|all` | bus watchpoints — fetches count as reads |
| `sym` | list symbols; every ADDR accepts `$hex`, decimal, or a symbol name |
| `q` | quit the emulator |

Pausing mid-frame presents the partial frame — the screen shows exactly
what the machine has drawn so far. Piped scripts work for headless use:
`printf "r\nd\nc\n" | flommodore --debug --max-frames 2 prog.flapp`.

## Spec

Implementation follows the v1.1 spec amendment (LOCKED), which supersedes the
v1.0 phase documents wherever they disagree, plus the v1.2 amendment
(`docs/flommodore-spec-amendment-v1_2.md`) covering the points the Block 2–3
implementation surfaced: trap resume PC, shift domains, unsigned DIV/MOD,
20-bit CYC, the completed privilege matrix (supervisor-only RTI, user-ignored
SEI/CLI), user-mode entry, and I/O byte-write/straddle composition (D36–D47).
