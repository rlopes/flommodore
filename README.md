# Flommodore

A fully specified fantasy computer — Gab-16 CPU (16-bit RISC, 20-bit address
bus), VIC-256 video, AUR-1 sound, 512KB RAM — implemented as a reference
emulator and toolchain in **Zig 0.16** with **SDL3**.

Block 4 status: the I/O region is live — system config (SYSID/SYSPWR),
both 16-bit timers with exact prescaler timing (÷1/÷8/÷64/÷256 at 14.4 MHz),
the IRQ controller (raw IRQSTAT, mask, w1c ack) wired to the CPU line, and
the keyboard/joystick register sets awaiting SDL in Block 8. Next: Block 5,
the scanline-quantum main loop — Milestone 1.

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
