//! test_memory.zig — Block 2.5: Memory subsystem routing tests.
//!
//! Walks every address range defined in the spec and verifies that reads and
//! writes route to the correct module.  Runs headlessly (no SDL3, no window).
//!
//! Run with:   zig build test
//!
//! Pass criteria (spec §1.2):
//!   $00000–$7FFFF  → RAM
//!   $80000–$80FFF  → I/O
//!   $81000–$FBFFF  → open bus ($0000 on read, writes ignored)
//!   $FC000–$FFFFF  → ROM (shadow off) or RAM (shadow on)

const std = @import("std");
const bus = @import("bus.zig");
const ram = @import("ram.zig");
const rom = @import("rom.zig");
const io  = @import("io.zig");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn reset_all() void {
    ram.reset();
    rom.reset();
    io.reset();
}

// ---------------------------------------------------------------------------
// Range: RAM ($00000–$7FFFF)
// ---------------------------------------------------------------------------

test "routing: RAM low boundary ($00000)" {
    reset_all();
    bus.write_u16(0x00000, 0xABCD);
    try std.testing.expect(bus.read_u16(0x00000) == 0xABCD);
    try std.testing.expect(ram.read_u16(0x00000) == 0xABCD); // direct confirm
}

test "routing: RAM mid-range ($01000)" {
    reset_all();
    bus.write_u16(0x01000, 0x1234);
    try std.testing.expect(bus.read_u16(0x01000) == 0x1234);
}

test "routing: VRAM region ($40000–$7FFFF)" {
    reset_all();
    bus.write_u16(0x40000, 0xBEEF);
    try std.testing.expect(bus.read_u16(0x40000) == 0xBEEF);
    bus.write_u16(0x7FFFE, 0x5A5A);
    try std.testing.expect(bus.read_u16(0x7FFFE) == 0x5A5A);
}

test "routing: RAM high boundary ($7FFFE)" {
    reset_all();
    bus.write_byte(0x7FFFF, 0x99);
    try std.testing.expect(bus.read_byte(0x7FFFF) == 0x99);
}

// ---------------------------------------------------------------------------
// Range: I/O ($80000–$80FFF)
// ---------------------------------------------------------------------------

test "routing: SYSCFG write/read via bus" {
    reset_all();
    // Write 0x0001 to SYSCFG through the bus.
    bus.write_u16(0x80000, 0x0001);
    try std.testing.expect(bus.read_u16(0x80000) == 0x0001);
    try std.testing.expect(io.rom_shadow_enabled() == true);
    // Clean up.
    bus.write_u16(0x80000, 0x0000);
}

test "routing: SYSID read via bus returns 0x00F1" {
    reset_all();
    try std.testing.expect(bus.read_u16(0x80002) == 0x00F1);
}

test "routing: I/O high boundary ($80FFF)" {
    reset_all();
    // Should not crash — stub returns 0, write ignored.
    bus.write_u16(0x80FFE, 0x5555);
    _ = bus.read_u16(0x80FFE);
}

// ---------------------------------------------------------------------------
// Range: Open bus ($81000–$FBFFF)
// ---------------------------------------------------------------------------

test "routing: open bus low boundary ($81000) reads 0x0000" {
    reset_all();
    try std.testing.expect(bus.read_u16(0x81000) == 0x0000);
    try std.testing.expect(bus.read_byte(0x81000) == 0x00);
}

test "routing: open bus mid ($90000) reads 0x0000" {
    reset_all();
    try std.testing.expect(bus.read_u16(0x90000) == 0x0000);
}

test "routing: open bus high boundary ($FBFFF) reads 0x0000" {
    reset_all();
    try std.testing.expect(bus.read_byte(0xFBFFF) == 0x00);
}

test "routing: open bus writes do not crash" {
    reset_all();
    bus.write_u16(0x81000, 0xDEAD);
    bus.write_u16(0xFBFFE, 0xBEEF);
    // Verify the bus didn't route these to RAM.
    try std.testing.expect(ram.read_u16(0x81000) == 0x0000);
}

// ---------------------------------------------------------------------------
// Range: ROM ($FC000–$FFFFF), shadow disabled
// ---------------------------------------------------------------------------

test "routing: ROM reads rom module when shadow disabled" {
    reset_all();
    io.set_rom_shadow(false);
    // Load a known pattern into ROM.
    const img = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    try rom.load_bytes(&img);
    try std.testing.expect(bus.read_byte(0xFC000) == 0xAA);
    try std.testing.expect(bus.read_byte(0xFC001) == 0xBB);
    try std.testing.expect(bus.read_u16(0xFC000) == 0xBBAA);
}

test "routing: ROM write is ignored when shadow disabled" {
    reset_all();
    io.set_rom_shadow(false);
    rom.reset();
    bus.write_u16(0xFC000, 0xCAFE);
    // ROM should still be zero.
    try std.testing.expect(bus.read_u16(0xFC000) == 0x0000);
}

// ---------------------------------------------------------------------------
// Range: ROM with shadow enabled
// ---------------------------------------------------------------------------

test "routing: shadow on — ROM range reads from RAM" {
    reset_all();
    // Write sentinel into RAM at the shadow address.
    ram.write_u16(0xFC000, 0xDEAD);
    // Also put something different in ROM.
    const img = [_]u8{ 0x11, 0x22 };
    try rom.load_bytes(&img);
    // Enable shadow via SYSCFG.
    bus.write_u16(0x80000, 0x0001);
    try std.testing.expect(bus.read_u16(0xFC000) == 0xDEAD); // reads RAM
    bus.write_u16(0x80000, 0x0000); // disable shadow
    try std.testing.expect(bus.read_u16(0xFC000) == 0x2211); // reads ROM
}

test "routing: shadow on — bus writes to ROM range go to RAM" {
    reset_all();
    io.set_rom_shadow(true);
    bus.write_u16(0xFC010, 0x5678);
    try std.testing.expect(ram.read_u16(0xFC010) == 0x5678);
    io.set_rom_shadow(false);
}

test "routing: system vector address accessible ($FFBC0)" {
    reset_all();
    // Spec §1.6: RESET vector at $FFBC0 (offset $3BC0 from ROM base).
    io.set_rom_shadow(false);
    rom.reset();
    // Zero — just verify no crash and correct route.
    try std.testing.expect(bus.read_u16(0xFFBC0) == 0x0000);
}

// ---------------------------------------------------------------------------
// 20-bit address masking
// ---------------------------------------------------------------------------

test "routing: addresses above 20 bits are masked" {
    reset_all();
    // $100000 masked to 20 bits == $00000 → RAM.
    ram.write_byte(0x00000, 0x7E);
    try std.testing.expect(bus.read_byte(0x100000) == 0x7E);
    try std.testing.expect(bus.read_byte(0x200000) == 0x7E); // same after masking
}
