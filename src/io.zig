//! io.zig — I/O register space ($80000 – $80FFF).
//!
//! I/O region layout (spec §1.5):
//!   $80000 – $8000F   System config & misc control (SYSCFG, SYSID, …)
//!   $80010 – $8001F   Timer A & Timer B
//!   $80020 – $8002F   Keyboard
//!   $80030 – $8003F   Joystick
//!   $80040 – $8004F   IRQ control & status
//!   $80050 – $800FF   Reserved
//!   $80100 – $801FF   AUR-1 Sound Chip
//!   $80200 – $802FF   VIC-256 Control
//!   $80300 – $80FFF   Reserved
//!
//! This stub implements only SYSCFG (bit 0 = ROM shadow enable) so that the
//! Block 2 memory subsystem can be tested end-to-end.
//! Full register dispatch is implemented in Block 4.
//!
//! SYSCFG register ($80000):
//!   bit 0  ROM shadow enable — when 1, $FC000–$FFFFF resolves to RAM

const std = @import("std");

// ---------------------------------------------------------------------------
// SYSCFG  ($80000)
// ---------------------------------------------------------------------------

pub const SYSCFG_ADDR: u32 = 0x80000;
pub const SYSID_ADDR:  u32 = 0x80002; // SYSID always returns $00F1 (spec §4)
pub const SYSID_VALUE: u16 = 0x00F1;

var syscfg: u16 = 0x0000;

/// Returns true when SYSCFG bit 0 is set (ROM shadow active).
pub fn rom_shadow_enabled() bool {
    return (syscfg & 0x0001) != 0;
}

/// Set or clear the ROM shadow bit directly (used by tests and by the I/O
/// write path below once SYSCFG is wired up).
pub fn set_rom_shadow(enabled: bool) void {
    if (enabled) {
        syscfg |= 0x0001;
    } else {
        syscfg &= ~@as(u16, 0x0001);
    }
}

// ---------------------------------------------------------------------------
// Register dispatch — stub (full implementation in Block 4)
// ---------------------------------------------------------------------------

pub fn read_u16(addr: u32) u16 {
    return switch (addr) {
        SYSCFG_ADDR => syscfg,
        SYSID_ADDR  => SYSID_VALUE,
        else        => 0x0000, // unimplemented registers return 0
    };
}

pub fn write_u16(addr: u32, value: u16) void {
    switch (addr) {
        SYSCFG_ADDR => syscfg = value,
        else        => {}, // unimplemented registers — ignore
    }
}

pub fn init() void {}

pub fn reset() void {
    syscfg = 0x0000;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "io: SYSID always returns 0x00F1" {
    try std.testing.expect(read_u16(SYSID_ADDR) == 0x00F1);
}

test "io: SYSCFG shadow bit set/clear via write" {
    reset();
    try std.testing.expect(rom_shadow_enabled() == false);
    write_u16(SYSCFG_ADDR, 0x0001);
    try std.testing.expect(rom_shadow_enabled() == true);
    write_u16(SYSCFG_ADDR, 0x0000);
    try std.testing.expect(rom_shadow_enabled() == false);
}

test "io: set_rom_shadow helper" {
    reset();
    set_rom_shadow(true);
    try std.testing.expect(rom_shadow_enabled() == true);
    set_rom_shadow(false);
    try std.testing.expect(rom_shadow_enabled() == false);
}

test "io: unimplemented register reads return 0" {
    try std.testing.expect(read_u16(0x80010) == 0x0000);
    try std.testing.expect(read_u16(0x80100) == 0x0000);
}
