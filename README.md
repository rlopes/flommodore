# Flommodore

A fully specified fantasy computer — Gab-16 CPU (16-bit RISC, 20-bit address
bus), VIC-256 video, AUR-1 sound, 512KB RAM — implemented as a reference
emulator and toolchain in **Zig 0.16** with **SDL3**.

Block 1 status: project scaffold. The window opens; the machine arrives in
Blocks 2+.

## Build

Requires Zig **0.16.0** exactly. SDL3 is fetched and built from source by the
Zig package manager (castholm/SDL) — no system packages needed.

```sh
zig build            # build zig-out/bin/flommodore
zig build run        # open the (empty) Flommodore window; ESC or close to quit
zig build test       # unit tests
zig build genroms    # test-ROM generator (placeholder until Block 2)
```

Cross-compilation:

```sh
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-macos      # macOS host only (needs the Apple SDK)
```

## Spec

Implementation follows the v1.1 spec amendment (LOCKED), which supersedes the
v1.0 phase documents wherever they disagree.
