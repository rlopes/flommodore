# Flommodore — Phase 7: Emulator / Reference Implementation

## Overview

The emulator is the Flommodore's proof of existence. It translates the paper specification
into a running machine — something you can actually load a program into, see pixels on screen,
and hear audio from. It is also the definitive reference for any ambiguity in the spec:
**what the emulator does is what the Flommodore does**.

---

## 7.1 — Design Goals

- **Correctness first** — accurate to the spec before worrying about performance
- **Readable code** — the emulator is a reference document as much as a program; clarity
  matters more than cleverness
- **Modular** — each component (CPU, VIC-256, AUR-1, RAM, I/O) is an independent module
  with a clean interface
- **Cross-platform** — runs on Linux, macOS, and Windows, built from any host machine
  without additional toolchain setup
- **Debuggable** — built-in debugger from day one, not bolted on later

---

## 7.2 — Technology Stack

| Component | Choice | Reason |
|---|---|---|
| Language | **Zig 0.16** | Cross-compilation, safety, build system, zero-friction C interop |
| Display | **SDL3** | Raw texture upload maps perfectly to framebuffer rendering |
| Audio | **SDL3** | Stream-based PCM push suits AUR-1 real-time synthesis |
| Input | **SDL3** | Raw scancodes and full modifier access |
| Debugger UI | **Dear ImGui** via cimgui | Immediate-mode UI, integrates cleanly with SDL3 |
| Build system | **build.zig** | No external tool needed — Zig builds itself |
| Zig version | **0.14 (pinned)** | Stable release, upgraded deliberately between versions |

### Why Zig over C

| Feature | C | Zig |
|---|---|---|
| Cross-compilation | Needs per-target toolchain setup | Built-in — one command, any target |
| Build system | Makefile / CMake — separate tool | `build.zig` — same language, no external tool |
| Memory safety | Manual, silent undefined behaviour | Explicit allocators, UB caught in safe builds |
| Error handling | Return codes easy to ignore | `error` union types — must be handled or explicitly discarded |
| Null safety | NULL pointer — silent danger | `?Type` optionals — null safety built in |
| C interop | N/A | `@cImport` — any C library, zero wrapper code |

Cross-compilation is the decisive advantage for the Flommodore project. From any single host:

```bash
zig build -Dtarget=x86_64-windows-gnu   # Windows binary
zig build -Dtarget=x86_64-macos        # macOS binary
zig build -Dtarget=aarch64-linux       # ARM Linux binary
```

No MinGW, no cross-compiler setup, no Mac required to build a Mac binary.

### Why SDL3 over SDL2 and Raylib

SDL3 (stable since late 2024) is the correct choice for new projects. Its stream-based audio
API is a natural fit for the AUR-1's real-time sample generation — samples are pushed into
a stream as the CPU executes, rather than pulled by a callback at unpredictable moments.

Raylib was considered but its audio API is abstracted for simplicity (load and play sounds)
rather than raw PCM streaming. Getting AUR-1's synthesised output into Raylib cleanly would
require reaching past its public API into miniaudio internals, defeating the purpose of using
Raylib. SDL3 gives us full control where we need it.

### C interop example

Zig calls SDL3 directly with no wrapper layer:

```zig
const sdl = @cImport(@cInclude("SDL3/SDL.h"));

pub fn main() !void {
    _ = sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_AUDIO);
    defer sdl.SDL_Quit();
    // ...
}
```

---

## 7.3 — Source Layout

```
flommodore/
├── build.zig               Zig build script (replaces Makefile / CMake)
├── build.zig.zon           Package manifest and dependency declarations
├── src/
│   ├── main.zig            Entry point, main loop, SDL3 initialisation
│   ├── bus.zig             Memory bus — central address routing
│   ├── ram.zig             512KB flat RAM array
│   ├── rom.zig             ROM image load and shadow logic
│   ├── cpu.zig             Gab-16 fetch / decode / execute loop
│   ├── vic256.zig          VIC-256 video chip — scanline renderer
│   ├── aur1.zig            AUR-1 sound chip — real-time synthesiser
│   ├── io.zig              I/O region — timers, keyboard, joystick, IRQ ctrl
│   ├── debugger.zig        Built-in debugger and monitor
│   └── util.zig            Shared helpers — bit ops, logging, sign extend
├── rom/
│   └── flommodore.rom      ROM binary image
└── tests/
    ├── harness.zig         Headless test runner
    └── roms/               Per-component test ROM binaries
```

---

## 7.4 — Memory Bus

The bus is the central nervous system of the emulator. Every CPU read and write passes
through it. It inspects the address and routes the operation to the correct handler.

```zig
pub fn read(addr: u32) u16 {
    const masked = addr & 0xFFFFF; // enforce 20-bit address space
    return switch (masked) {
        0x00000...0x7FFFF => ram.read(masked),
        0x80000...0x80FFF => io.read(masked),
        0x81000...0xFBFFF => 0x0000, // open bus
        0xFC000...0xFFFFF => if (io.rom_shadow_enabled())
                                 ram.read(masked - 0xC0000) // shadow window $3C000–$3FFFF
                             else
                                 rom.read(masked),
        else => unreachable,
    };
}

pub fn write(addr: u32, value: u16) void {
    const masked = addr & 0xFFFFF;
    switch (masked) {
        0x00000...0x7FFFF => ram.write(masked, value),
        0x80000...0x80FFF => io.write(masked, value),
        0xFC000...0xFFFFF => if (io.rom_shadow_enabled())
                                 ram.write(masked - 0xC0000, value), // shadow window
        else => {}, // writes to open bus or ROM (non-shadow) silently ignored
    }
}
```

All addresses are masked to 20 bits at the bus level. The upper 12 bits of any address are
silently discarded, matching the hardware address bus width. Multi-byte accesses whose bytes
fall in different regions are routed **per byte**, and addresses wrap at `$FFFFF → $00000` —
in practice the bus implements 16-bit access as two routed byte accesses.

### Shadow ROM logic

When `SYSCFG` bit 0 is set, accesses to `$FC000 – $FFFFF` are remapped to the **fixed shadow
window `$3C000 – $3FFFF`** in RAM (offset preserved, reads and writes). The bus enforces this
transparently — no other module needs to be aware of the shadow state.

---

## 7.5 — RAM Module

A flat **512KB byte array** — the simplest module in the emulator.

```zig
const RAM_SIZE = 512 * 1024;
var data: [RAM_SIZE]u8 = std.mem.zeroes([RAM_SIZE]u8);

pub fn read(addr: u32) u16 {
    // Little-endian: low byte at lower address
    return @as(u16, data[addr]) | (@as(u16, data[addr + 1]) << 8);
}

pub fn write(addr: u32, value: u16) void {
    data[addr]     = @truncate(value);
    data[addr + 1] = @truncate(value >> 8);
}

pub fn read_byte(addr: u32) u8  { return data[addr]; }
pub fn write_byte(addr: u32, value: u8) void { data[addr] = value; }
```

### Byte order

The Flommodore is **little-endian** — the low byte of a 16-bit word lives at the lower
address. This matches x86 hosts and simplifies the emulator on the most common development
platforms.

Unaligned word accesses (odd addresses) are permitted — they read or write two adjacent
bytes with no bus fault, matching the permissive behaviour of RISC designs.

---

## 7.6 — CPU Module

The CPU module implements the Gab-16 fetch / decode / execute loop. This is the largest and
most critical module in the emulator.

### CPU state

```zig
pub const Gab16 = struct {
    r:          [16]u32,    // R0–R15 (R0 always reads 0)
    pc:         u32,        // Program counter (20-bit)
    flags:      u16,        // FLAGS register
    ivt:        u32,        // Interrupt vector table base
    usp:        u32,        // User stack pointer (saved on interrupt)
    ssp:        u32,        // Supervisor stack pointer (loaded into SP on interrupt)
    sys:        u16,        // System control register
    cyc:        u32,        // Cycle counter (read-only)
    halted:     bool,       // HLT state
    irq_pending: bool,      // Pending IRQ from bus
};
```

`r[0]` is never written — any write to register 0 is silently discarded:

```zig
fn set_reg(cpu: *Gab16, reg: u4, val: u32) void {
    if (reg != 0) cpu.r[reg] = val & 0xFFFFF; // registers hold 20 significant bits
}
```

### Main execution loop

```zig
pub fn step(cpu: *Gab16) void {
    // Check for pending IRQ before fetch
    if (cpu.irq_pending and (cpu.flags & FLAG_I != 0)) {
        handle_irq(cpu);
        return;
    }
    if (cpu.halted) return;

    // Fetch — two 16-bit bus reads form one 32-bit instruction
    const lo: u32 = bus.read(cpu.pc);
    const hi: u32 = bus.read(cpu.pc + 2);
    const instr: u32 = lo | (hi << 16);
    cpu.pc = (cpu.pc + 4) & 0xFFFFF;

    // Decode and execute
    execute(cpu, instr);
    cpu.cyc +%= 1;
}
```

### Instruction decode

The 6-bit opcode is extracted from bits 31:26 and dispatched:

```zig
fn execute(cpu: *Gab16, instr: u32) void {
    const opcode: u6  = @truncate(instr >> 26);
    const rd: u4      = @truncate((instr >> 22) & 0xF);
    const ra: u4      = @truncate((instr >> 18) & 0xF);
    const rb: u4      = @truncate((instr >> 14) & 0xF);
    const imm18: i32  = sign_extend(instr & 0x3FFFF, 18);
    const addr26: u32 = instr & 0x3FFFFFF;

    switch (opcode) {
        .LW    => set_reg(cpu, rd, bus.read(
                      @intCast((cpu.r[ra] +% @as(u32, @bitCast(imm18))) & 0xFFFFF))),
        .SW    => bus.write(
                      @intCast((cpu.r[ra] +% @as(u32, @bitCast(imm18))) & 0xFFFFF),
                      @truncate(cpu.r[rb])),
        .ADD   => { const res = cpu.r[ra] +% cpu.r[rb];
                    update_flags(cpu, res, cpu.r[ra], cpu.r[rb]);
                    set_reg(cpu, rd, res); },
        .CALL  => { cpu.r[14] = cpu.pc;
                    cpu.pc = cpu.r[ra] & 0xFFFFF; },
        .CALLA => { cpu.r[14] = cpu.pc;
                    cpu.pc = addr26 & 0xFFFFF; },
        .RET   => { cpu.pc = cpu.r[14] & 0xFFFFF; },
        .HLT   => { cpu.halted = true; },
        // ... all opcodes ...
        else   => cpu_trap(cpu, .illegal_opcode),
    }
}
```

### Flag updates

Flags are always derived from the **low 16 bits** per the Phase 2 §2.4 flag table. C and V
differ between addition and subtraction — the ADD form is shown; SUB/CMP use C = no-borrow
and V = `((a^b) & (a^r))` bit 15:

```zig
fn update_flags_add(cpu: *Gab16, result: u32, a: u32, b: u32) void {
    cpu.flags &= ~(FLAG_Z | FLAG_N | FLAG_C | FLAG_V);
    if (result & 0xFFFF == 0)                   cpu.flags |= FLAG_Z;
    if (result & 0x8000 != 0)                   cpu.flags |= FLAG_N;
    if ((a & 0xFFFF) + (b & 0xFFFF) > 0xFFFF)   cpu.flags |= FLAG_C;
    if ((~(a ^ b) & (a ^ result)) & 0x8000 != 0) cpu.flags |= FLAG_V;
}
```

---

## 7.7 — VIC-256 Module

The VIC-256 renders **one scanline per `render_line()` call**, interleaved with CPU
execution by the main loop (§7.10) — this is what lets raster IRQ handlers change VIC
registers mid-frame.

### Render pipeline (per scanline, driven by the main loop)

```
For each scanline Y (main loop runs CYCLES_PER_LINE CPU cycles, then):
    1. Check raster IRQ — fire if VSCAN matches Y
    2. Fill scanline buffer with VBGCOL (background colour)
    3. If bitmap mode enabled  → composite bitmap pixels
    4. If tile mode enabled    → composite tile pixels over bitmap
    5. If sprites enabled      → composite sprite pixels (max 8 per scanline)
    6. Write scanline buffer to SDL3 texture row
End
Fire VBLANK IRQ
Present SDL3 texture to screen
```

### Framebuffer pixel read

```zig
fn get_pixel(fb_base: u32, x: u32, y: u32, width: u32, bpp: u32) u8 {
    const bit_offset = (y * width + x) * bpp;
    const byte_addr  = fb_base + (bit_offset / 8);
    const byte_val   = ram.read_byte(byte_addr);
    const shift: u3  = @truncate(8 - bpp - (bit_offset % 8));
    return (byte_val >> shift) & @as(u8, (@as(u8, 1) << @truncate(bpp)) - 1);
}
```

### Palette lookup

```zig
fn palette_lookup(index: u8) u32 {
    const addr = vic.pal_base + (@as(u32, index) * 3);
    const r = ram.read_byte(addr);
    const g = ram.read_byte(addr + 1);
    const b = ram.read_byte(addr + 2);
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}
```

### SDL3 texture presentation

The VIC-256 renders into a locked SDL3 texture (pixel format `SDL_PIXELFORMAT_RGB24`),
then presents it scaled to the host window. The window can be any size — the texture is
scaled with nearest-neighbour filtering to preserve the pixel art aesthetic.

---

## 7.8 — AUR-1 Module

The AUR-1 module generates audio samples on demand. SDL3's audio stream is fed by the
emulator's main loop, which pushes one frame's worth of samples after each video frame.

### Sample generation

```zig
pub fn generate_samples(buf: []i16, sample_count: usize) void {
    for (0..sample_count) |i| {
        tick_all_voices();
        const left  = mix_voices(.left);
        const right = mix_voices(.right);
        buf[i * 2]     = left;
        buf[i * 2 + 1] = right;
    }
}
```

### Per-voice tick

```zig
fn tick_voice(v: *Voice) void {
    v.phase +%= v.freq_word;

    const raw: i16 = switch (v.waveform) {
        .sine     => sine_table[v.phase >> 8],
        .square   => if (v.phase & 0x8000 != 0) 32767 else -32768,
        .triangle => triangle_from_phase(v.phase),
        .sawtooth => @bitCast(@as(u16, v.phase) -% 32768),
        .pulse    => if (v.phase > @as(u32, v.pulse_width) << 8) 32767 else -32768,
        .noise    => noise_tick(&v.lfsr), // LFSR seeded $ACE1 at reset (deterministic)
        .wavetable => (@as(i16, ram.read_byte(v.wtb_base + (v.phase >> 8))) - 128) << 8,
        else      => 0,
    };

    const enveloped = @as(i32, raw) * adsr_level(v) >> 15;
    v.current_sample = @truncate(@as(i32, enveloped) * v.vol >> 8);
}
```

### Noise generation

White noise uses a **16-bit Galois LFSR** — the same technique used by the SID and YM chips:

```zig
fn noise_tick(lfsr: *u16) i16 {
    const feedback: u16 = if (lfsr.* & 1 != 0) 0xB400 else 0;
    lfsr.* = (lfsr.* >> 1) ^ feedback;
    return @as(i16, @bitCast(lfsr.*)) >> 1;
}
```

### SDL3 audio stream

```zig
// At init:
const stream = sdl.SDL_OpenAudioDeviceStream(
    sdl.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
    &.{ .format = sdl.SDL_AUDIO_S16, .channels = 2, .freq = 44100 },
    null, null);
sdl.SDL_ResumeAudioStreamDevice(stream);

// Each frame, after CPU execution:
var sample_buf: [SAMPLES_PER_FRAME * 2]i16 = undefined;
aur1.generate_samples(&sample_buf, SAMPLES_PER_FRAME);
_ = sdl.SDL_PutAudioStreamData(stream, &sample_buf, @sizeOf(@TypeOf(sample_buf)));
```

---

## 7.9 — I/O Module

The I/O module handles reads and writes to `$80000 – $80FFF`. Each device sub-block is a
register struct with read/write handlers.

```zig
pub fn read(addr: u32) u16 {
    return switch (addr) {
        0x80000 => io_state.syscfg,
        0x80001 => 0x00F1,              // SYSID — always $F1
        0x80002 => ROM_VERSION,
        0x80010 => timer_a.load & 0xFF,
        0x80011 => timer_a.load >> 8,
        0x80012 => timer_a.count & 0xFF,  // read-only current count
        0x80013 => timer_a.count >> 8,
        0x80020 => keyboard_stat(),
        0x80021 => keyboard_dequeue(),    // advances queue on read
        0x80030 => joystick_read(0),
        0x80031 => joystick_read(1),
        0x80040 => irq_stat(),
        else    => 0x0000,
    };
}
```

### Timer emulation

Timers are advanced once per CPU cycle in the main loop:

```zig
pub fn tick(t: *Timer) void {
    if (!t.enabled) return;
    t.prescale += 1;                       // honour TxDIV: ÷1 / ÷8 / ÷64 / ÷256
    if (t.prescale < t.divisor_period) return;
    t.prescale = 0;
    if (t.count == 0) {
        t.stat |= TIMER_EXPIRED;
        if (t.irq_enable) bus.assert_irq(.timer_a);
        if (t.repeat) t.count = t.load
        else t.enabled = false;
    } else {
        t.count -= 1;
    }
}
```

---

## 7.10 — Main Loop

The main loop ties everything together, running at the Flommodore's target speed:

```zig
pub fn main() !void {
    try bus.init();
    try ram.init();
    try rom.load("rom/flommodore.rom");
    try vic256.init();
    try aur1.init();
    try io.init();
    try sdl_init();

    cpu.reset();

    while (running) {
        // One frame = total_lines scanline quanta (mode-dependent, Phase 3 §3.11)
        for (0..vic256.total_lines()) |line| {
            var i: u32 = 0;
            while (i < vic256.cycles_per_line()) : (i += 1) {
                cpu.step();
                io.timer_tick();
            }
            vic256.render_line(line);    // renders the line, evaluates raster IRQ
        }
        vic256.fire_vblank();
        sdl_present();                   // flip SDL3 texture to screen
        aur1_push_audio();               // 735 samples (44_100 / 60)
        sdl_poll_events();               // keyboard, joystick, quit, debugger hotkey
    }
}
```

`CYCLES_PER_FRAME = 240_000` exactly (14,400,000 Hz ÷ 60). CPU execution and rendering
**interleave per scanline**, so raster IRQ handlers can change VIC registers mid-frame —
required for sprite multiplexing and split-screen effects.

---

## 7.11 — Built-in Debugger

The debugger is always compiled in and activated by pressing **F12** or by a `BRK`
instruction in the running program. It pauses emulation and presents an interactive monitor.

### Debugger features

| Feature | Description |
|---|---|
| **Register view** | Live display of all R0–R15, PC, FLAGS, SP, LR, cycle count |
| **Disassembler** | Decode and display instructions around current PC |
| **Memory viewer** | Hex + ASCII dump of any address range |
| **Breakpoints** | Up to 16 address breakpoints — halt on hit |
| **Watchpoints** | Halt on read or write to a specified address |
| **Step** | Execute one instruction and return to debugger |
| **Step over** | Step but treat CALL as a single unit |
| **Continue** | Resume full-speed execution |
| **VRAM viewer** | Render VRAM region as pixels for visual inspection |
| **I/O viewer** | Display all I/O register values live |
| **Audio monitor** | Display voice states, envelope levels, current waveforms |

### Debugger interface

The debugger renders as an **immediate-mode GUI overlay** via Dear ImGui (cimgui bindings),
displayed in a separate SDL3 window alongside the Flommodore screen. It can also be driven
from a **text console** (stdin/stdout) for headless or scripted debugging sessions.

---

## 7.12 — Testing Strategy

Each module has a dedicated test ROM — a small binary that exercises the module and writes a
pass/fail byte to address `$00010`. The test harness runs the emulator headlessly, loads the
test ROM, executes for a fixed number of cycles, and reads `$00010` for the result.

### Test ROM set

| Test ROM | What it tests |
|---|---|
| `test_cpu_alu.rom` | All ALU opcodes, flag behaviour, overflow and carry cases |
| `test_cpu_branch.rom` | All branch conditions, forward and backward targets |
| `test_cpu_load_store.rom` | LW/LB/SW/SB, all addressing modes, alignment |
| `test_cpu_stack.rom` | PUSH/POP/PUSHA/POPA, SP behaviour, nested calls |
| `test_cpu_irq.rom` | IRQ entry/exit, FLAGS save/restore, RTI |
| `test_vic_text.rom` | Text mode rendering, font display, cursor |
| `test_vic_bitmap.rom` | Bitmap mode, palette lookup, double buffer swap |
| `test_vic_sprite.rom` | Sprite positioning, flip, priority, collision flag |
| `test_aur_basic.rom` | Voice gate on/off, waveform output, ADSR progression |
| `test_aur_fm.rom` | FM pairing, modulation depth, feedback |
| `test_io_timer.rom` | Timer reload, repeat mode, one-shot, IRQ |
| `test_io_kbd.rom` | Keyboard queue enqueue/dequeue, overflow, modifier state |

### Headless test harness

```zig
// tests/harness.zig
pub fn run_test(rom_path: []const u8, max_cycles: u64) !bool {
    try rom.load(rom_path);
    cpu.reset();
    var cycles: u64 = 0;
    while (cycles < max_cycles) : (cycles += 1) {
        cpu.step();
        io.timer_tick();
        if (ram.read_byte(0x00010) != 0) break; // test signalled completion
    }
    return ram.read_byte(0x00010) == 0xFF; // 0xFF = pass, anything else = fail
}
```

---

## Phase 7 — Key Facts (carry forward to all phases)

| Item | Detail |
|---|---|
| Language | Zig 0.16, pinned version |
| Libraries | SDL3 (display, audio, input), Dear ImGui via cimgui (debugger UI) |
| Build | `build.zig` — cross-compiles to Linux, macOS, Windows from any host |
| Byte order | Little-endian (low byte at lower address) |
| Modules | main, bus, ram, rom, cpu, vic256, aur1, io, debugger, util |
| Bus | Central address decoder, 20-bit masking, shadow ROM logic |
| CPU loop | Fetch 32-bit instruction (two 16-bit reads), decode, execute, update flags |
| VIC-256 | Scanline renderer — raster IRQ per line, VBLANK IRQ at frame end |
| AUR-1 | Sample generation per frame, pushed to SDL3 audio stream |
| Noise | 16-bit Galois LFSR |
| Main loop | 240,000 cycles/frame (14.4 MHz / 60 Hz), scanline-interleaved |
| Debugger | F12 to activate, ImGui overlay, breakpoints, watchpoints, step/continue |
| Test result | Written to `$00010` — `$FF` = pass |
| Test harness | Headless, one test ROM per module |

---

*Flommodore Fantasy Computer — Design Document*
*Phase 7: Emulator / Reference Implementation — Status: LOCKED (v1.1 — Block 0 amendments applied)*
