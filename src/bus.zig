//! bus.zig — Memory bus: central address decoder.
//!
//! All CPU reads and writes pass through here.  The bus inspects the 20-bit
//! address and routes the operation to the correct handler.
//!
//! Routing table (spec §1.2 / §1.5):
//!   $00000 – $7FFFF   → RAM  (512KB: general + VRAM)
//!   $80000 – $80FFF   → I/O  (device registers)
//!   $81000 – $FBFFF   → open bus (returns $0000, writes silently ignored)
//!   $FC000 – $FFFFF   → ROM  (or RAM if shadow enabled via SYSCFG bit 0)
//!
//! All addresses are masked to 20 bits before routing.
//!
//! ROM shadow logic (spec §1.7):
//!   When SYSCFG bit 0 is set, reads from $FC000–$FFFFF resolve to RAM
//!   instead of the ROM buffer.  Writes to that range also go to RAM when
//!   shadow is active (allowing the shadow to be patched after the initial
//!   ROM→RAM copy).
//!
//! Implemented in Block 2.3 (routing) and Block 2.4 (shadow logic).

const std = @import("std");
const ram = @import("ram.zig");
const rom = @import("rom.zig");
const io = @import("io.zig");

// ---------------------------------------------------------------------------
// Address-space constants
// ---------------------------------------------------------------------------

const ADDR_MASK: u32 = 0x000F_FFFF; // 20-bit mask

const RAM_END: u32 = 0x7FFFF;
const IO_START: u32 = 0x80000;
const IO_END: u32 = 0x80FFF;
const OPEN_BUS_END: u32 = 0xFBFFF;
const ROM_START: u32 = 0xFC000;
// ROM_END == ADDR_MASK (0xFFFFF)

// ---------------------------------------------------------------------------
// Internal shadow-ROM flag
//
// The I/O module owns SYSCFG ($80000).  The bus queries it via
// io.rom_shadow_enabled() rather than caching a local copy, so the bus
// always reflects the current register value without a synchronisation step.
// ---------------------------------------------------------------------------

// (No local flag — truth lives in io.zig.)

// ---------------------------------------------------------------------------
// Byte reads / writes
// ---------------------------------------------------------------------------

pub fn read_byte(addr: u32) u8 {
    const a = addr & ADDR_MASK;
    return switch (a) {
        0x00000...RAM_END => ram.read_byte(a),
        IO_START...IO_END => @truncate(io.read_u16(a)),
        IO_END + 1...OPEN_BUS_END => 0x00,
        ROM_START...ADDR_MASK => if (io.rom_shadow_enabled()) ram.read_shadow_byte(a) else rom.read_byte(a),
        else => unreachable,
    };
}

pub fn write_byte(addr: u32, value: u8) void {
    const a = addr & ADDR_MASK;
    switch (a) {
        0x00000...RAM_END => ram.write_byte(a, value),
        IO_START...IO_END => io.write_u16(a, @as(u16, value)),
        IO_END + 1...OPEN_BUS_END => {}, // open bus — ignore
        ROM_START...ADDR_MASK => {
            if (io.rom_shadow_enabled()) ram.write_shadow_byte(a, value);
            // else: write to real ROM is ignored
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Word (16-bit) reads / writes
//
// The CPU fetches 32-bit instructions as two 16-bit bus reads.
// All word accesses use the same routing — no special alignment handling.
// ---------------------------------------------------------------------------

pub fn read_u16(addr: u32) u16 {
    const a = addr & ADDR_MASK;
    return switch (a) {
        0x00000...RAM_END => ram.read_u16(a),
        IO_START...IO_END => io.read_u16(a),
        IO_END + 1...OPEN_BUS_END => 0x0000,
        ROM_START...ADDR_MASK => if (io.rom_shadow_enabled()) ram.read_shadow_u16(a) else rom.read_u16(a),
        else => unreachable,
    };
}

pub fn write_u16(addr: u32, value: u16) void {
    const a = addr & ADDR_MASK;
    switch (a) {
        0x00000...RAM_END => ram.write_u16(a, value),
        IO_START...IO_END => io.write_u16(a, value),
        IO_END + 1...OPEN_BUS_END => {}, // open bus — ignore
        ROM_START...ADDR_MASK => {
            if (io.rom_shadow_enabled()) ram.write_shadow_u16(a, value);
            // else: write to real ROM is ignored
        },
        else => unreachable,
    }
}

pub fn init() void {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "bus: 20-bit address masking" {
    // Addresses beyond 20 bits must be masked down before routing.
    // $100000 & 0xFFFFF == $00000 — routes to RAM.
    ram.reset();
    ram.write_byte(0x00000, 0x5A);
    // Read via the over-range address — should hit RAM[0].
    const v = read_byte(0x100000);
    try std.testing.expect(v == 0x5A);
}

test "bus: RAM region routes to ram module" {
    ram.reset();
    write_u16(0x00010, 0xABCD);
    try std.testing.expect(read_u16(0x00010) == 0xABCD);
    // Also verify the byte lives in RAM directly.
    try std.testing.expect(ram.read_byte(0x00010) == 0xCD); // low byte
    try std.testing.expect(ram.read_byte(0x00011) == 0xAB); // high byte
}

test "bus: VRAM region routes to ram module" {
    ram.reset();
    write_u16(0x40000, 0x1234);
    try std.testing.expect(read_u16(0x40000) == 0x1234);
}

test "bus: open bus returns 0x0000" {
    try std.testing.expect(read_u16(0x81000) == 0x0000);
    try std.testing.expect(read_byte(0xFBFFF) == 0x00);
    // Writes to open bus must not crash.
    write_u16(0x90000, 0xDEAD);
    write_byte(0xA0000, 0xFF);
}

test "bus: ROM region routes to rom module when shadow disabled" {
    // Ensure shadow is off.
    io.set_rom_shadow(false);
    rom.reset();
    const img = [_]u8{ 0x11, 0x22 };
    try rom.load_bytes(&img);
    try std.testing.expect(read_u16(0xFC000) == 0x2211);
}

test "bus: ROM region routes to RAM when shadow enabled" {
    ram.reset();
    rom.reset();
    // Write a value into the RAM at the ROM shadow address range.
    ram.write_shadow_u16(0xFC000, 0xDEAD);
    // Enable shadow and read via the bus.
    io.set_rom_shadow(true);
    try std.testing.expect(read_u16(0xFC000) == 0xDEAD);
    // Write via bus should also go to the shadow mirror.
    write_u16(0xFC000, 0x1234);
    try std.testing.expect(ram.read_shadow_u16(0xFC000) == 0x1234);
    // Disable shadow — bus should now return rom contents (zeroed).
    io.set_rom_shadow(false);
    try std.testing.expect(read_u16(0xFC000) == 0x0000);
}

test "bus: write to ROM (shadow disabled) is silently ignored" {
    io.set_rom_shadow(false);
    rom.reset();
    // Write to ROM range — should do nothing.
    write_u16(0xFC000, 0xBEEF);
    // ROM still returns zero.
    try std.testing.expect(read_u16(0xFC000) == 0x0000);
}
