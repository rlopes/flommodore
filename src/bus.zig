//! Flommodore — `bus.zig` (Block 2, tasks 2.3–2.5).
//!
//! The memory bus — central address decoder. Every CPU read and write passes
//! through here (Phase 7 §7.4). Routing (plan Block 2 / master §7.3):
//!
//! ```
//! $00000–$7FFFF  → RAM (general RAM + VRAM, one 512KB array)
//! $80000–$80FFF  → I/O (16-bit register per address — amendment D14/§3.1)
//! $81000–$FBFFF  → open bus (reads $0000, writes ignored)
//! $FC000–$FFFFF  → ROM, or the $3C000–$3FFFF RAM window while shadow is on
//! ```
//!
//! Normative access edges (amendment §1.7 / D8):
//!   - Addresses are masked to 20 bits; `$FFFFF + 1 → $00000`.
//!   - Unaligned 16-bit access is legal, no penalty.
//!   - A multi-byte access whose bytes fall in different bus regions is
//!     routed **per byte**.
//!   - Writes to non-shadowed ROM and to open bus are silently ignored;
//!     open-bus reads return `$0000`.
//!
//! I/O access model (amendment D14/§3.1): every I/O register is a 16-bit
//! value at its listed address; a 16-bit access wholly inside the I/O region
//! hits the register at the **exact** address — adjacent addresses are
//! independent registers and never combine. Byte accesses touch the low byte
//! of the register. (Per-byte routing therefore applies only when an access
//! straddles the I/O region's edges.)
//!
//! ROM shadow (amendment D9/§2.2, task 2.4): while `SYSCFG` bit 0 is set the
//! bus maps `$FC000+off ↔ $3C000+off` for **both reads and writes** — the
//! shadowed "ROM" is live-patchable RAM.

const std = @import("std");
const util = @import("util");
const ram_mod = @import("ram");
const rom_mod = @import("rom");

const Ram = ram_mod.Ram;
const Rom = rom_mod.Rom;

// Region boundaries (Phase 1 §1.2).
pub const ram_end: u32 = 0x7FFFF; // 512KB RAM, inclusive
pub const io_base: u32 = 0x80000; // 4KB I/O region
pub const io_end: u32 = 0x80FFF; // inclusive
pub const rom_base: u32 = 0xFC000; // 16KB ROM
pub const shadow_base: u32 = 0x3C000; // fixed shadow window (D9)

/// `SYSCFG` — system configuration register, `$80000` (Phase 5 §5.1).
/// Bit 0 = ROM shadow enable. Owned by the bus because shadow mapping is a
/// bus behaviour (plan task 2.4); the rest of the I/O region is dispatched
/// to the devices as they land (Blocks 6–8).
pub const syscfg_addr: u32 = 0x80000;
/// SYSCFG defined bits — only bit 0 exists; undefined bits read as zero
/// (amendment §3.1).
const syscfg_mask: u16 = 0x0001;

pub const Region = enum { ram, io, open_bus, rom };

pub fn regionOf(addr: u32) Region {
    std.debug.assert(addr <= util.addr_mask);
    if (addr <= ram_end) return .ram;
    if (addr <= io_end) return .io;
    if (addr < rom_base) return .open_bus;
    return .rom;
}

pub const Bus = struct {
    ram: *Ram,
    rom: *Rom,
    syscfg: u16 = 0,

    pub fn init(ram: *Ram, rom: *Rom) Bus {
        return .{ .ram = ram, .rom = rom };
    }

    pub fn shadowEnabled(bus: *const Bus) bool {
        return (bus.syscfg & 0x0001) != 0;
    }

    // ------------------------------------------------------------------
    // Byte access — the routing primitive.
    // ------------------------------------------------------------------

    pub fn read8(bus: *const Bus, addr_in: u32) u8 {
        const addr = util.maskAddr(addr_in);
        return switch (regionOf(addr)) {
            .ram => bus.ram.readByte(addr),
            .io => @truncate(bus.ioRead16(addr)), // low byte of the register (§3.1)
            .open_bus => 0x00, // open-bus reads return $0000 (§1.7)
            .rom => if (bus.shadowEnabled())
                bus.ram.readByte(shadow_base + (addr - rom_base)) // D9: $FC000+off → $3C000+off
            else
                bus.rom.readByte(addr - rom_base),
        };
    }

    pub fn write8(bus: *Bus, addr_in: u32, value: u8) void {
        const addr = util.maskAddr(addr_in);
        switch (regionOf(addr)) {
            .ram => bus.ram.writeByte(addr, value),
            .io => {
                // Byte writes touch the low byte of the register (§3.1).
                const old = bus.ioRead16(addr);
                bus.ioWrite16(addr, (old & 0xFF00) | value);
            },
            .open_bus => {}, // writes ignored (§1.7)
            .rom => if (bus.shadowEnabled()) {
                bus.ram.writeByte(shadow_base + (addr - rom_base), value); // live-patchable (§2.2)
            }, // else: writes to non-shadowed ROM silently ignored (§1.7)
        }
    }

    // ------------------------------------------------------------------
    // 16-bit access — little-endian; per-byte routing across region edges
    // (§1.7), exact-register semantics wholly inside I/O (D14/§3.1).
    // ------------------------------------------------------------------

    pub fn read16(bus: *const Bus, addr_in: u32) u16 {
        const a0 = util.maskAddr(addr_in);
        const a1 = util.maskAddr(addr_in +% 1); // wraps $FFFFF → $00000 (§1.7)
        if (regionOf(a0) == .io and regionOf(a1) == .io) {
            return bus.ioRead16(a0); // 16-bit register at the exact address (D14)
        }
        const lo: u16 = bus.read8(a0);
        const hi: u16 = bus.read8(a1);
        return lo | (hi << 8);
    }

    pub fn write16(bus: *Bus, addr_in: u32, value: u16) void {
        const a0 = util.maskAddr(addr_in);
        const a1 = util.maskAddr(addr_in +% 1);
        if (regionOf(a0) == .io and regionOf(a1) == .io) {
            bus.ioWrite16(a0, value); // exact register (D14)
            return;
        }
        bus.write8(a0, @truncate(value));
        bus.write8(a1, @truncate(value >> 8));
    }

    // ------------------------------------------------------------------
    // I/O region internals. Block 2 implements only SYSCFG ($80000);
    // every other I/O address reads $0000 and ignores writes until its
    // device block lands (timers/keyboard/joystick Block 8, VIC Block 6,
    // AUR-1 Block 7).
    // ------------------------------------------------------------------

    fn ioRead16(bus: *const Bus, addr: u32) u16 {
        return switch (addr) {
            syscfg_addr => bus.syscfg,
            else => 0x0000, // unimplemented device registers (Blocks 6–8)
        };
    }

    fn ioWrite16(bus: *Bus, addr: u32, value: u16) void {
        switch (addr) {
            syscfg_addr => bus.syscfg = value & syscfg_mask,
            else => {}, // unimplemented device registers (Blocks 6–8)
        }
    }
};

// ---------------------------------------------------------------------------
// Tests — task 2.5: walk every address range and verify routing, including
// boundary-straddling words, the $FFFFF wrap, and the shadow round-trip.
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    ram: *Ram,
    rom: *Rom,
    bus: Bus,

    fn setup() !Fixture {
        const ram = try testing.allocator.create(Ram);
        errdefer testing.allocator.destroy(ram);
        const rom = try testing.allocator.create(Rom);
        ram.init();
        rom.init();
        return .{ .ram = ram, .rom = rom, .bus = Bus.init(ram, rom) };
    }

    fn teardown(f: *Fixture) void {
        testing.allocator.destroy(f.ram);
        testing.allocator.destroy(f.rom);
    }
};

test "bus: region decode across the whole map" {
    try testing.expectEqual(Region.ram, regionOf(0x00000));
    try testing.expectEqual(Region.ram, regionOf(0x3C000)); // shadow window is plain RAM
    try testing.expectEqual(Region.ram, regionOf(0x40000)); // VRAM base
    try testing.expectEqual(Region.ram, regionOf(0x7FFFF));
    try testing.expectEqual(Region.io, regionOf(0x80000));
    try testing.expectEqual(Region.io, regionOf(0x80FFF));
    try testing.expectEqual(Region.open_bus, regionOf(0x81000));
    try testing.expectEqual(Region.open_bus, regionOf(0xFBFFF));
    try testing.expectEqual(Region.rom, regionOf(0xFC000));
    try testing.expectEqual(Region.rom, regionOf(0xFFFFF));
}

test "bus: RAM round-trip, byte and word, unaligned" {
    var f = try Fixture.setup();
    defer f.teardown();

    f.bus.write8(0x00000, 0x12);
    f.bus.write16(0x04100, 0xBEEF); // canonical load address (D10)
    f.bus.write16(0x04101, 0xCAFE); // unaligned — legal, no penalty (§1.7)
    try testing.expectEqual(@as(u8, 0x12), f.bus.read8(0x00000));
    try testing.expectEqual(@as(u16, 0xCAFE), f.bus.read16(0x04101));
    // Little-endian: the unaligned write overlapped the aligned one.
    try testing.expectEqual(@as(u8, 0xEF), f.bus.read8(0x04100));
    try testing.expectEqual(@as(u8, 0xFE), f.bus.read8(0x04101));
}

test "bus: ROM reads, writes ignored, out-of-image zeros" {
    var f = try Fixture.setup();
    defer f.teardown();

    var image: [8]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    try f.rom.loadFromSlice(&image);

    try testing.expectEqual(@as(u8, 0x11), f.bus.read8(0xFC000));
    try testing.expectEqual(@as(u16, 0x4433), f.bus.read16(0xFC002));
    // Beyond the loaded bytes the image is zero-filled.
    try testing.expectEqual(@as(u16, 0x0000), f.bus.read16(0xFFFC0)); // RESET vector slot
    // Writes to non-shadowed ROM are silently ignored (§1.7).
    f.bus.write8(0xFC000, 0xFF);
    f.bus.write16(0xFC002, 0xFFFF);
    try testing.expectEqual(@as(u8, 0x11), f.bus.read8(0xFC000));
    try testing.expectEqual(@as(u16, 0x4433), f.bus.read16(0xFC002));
}

test "bus: open bus reads $0000, writes ignored" {
    var f = try Fixture.setup();
    defer f.teardown();

    f.bus.write8(0x81000, 0xAB);
    f.bus.write16(0xA0000, 0xCDEF);
    try testing.expectEqual(@as(u8, 0x00), f.bus.read8(0x81000));
    try testing.expectEqual(@as(u16, 0x0000), f.bus.read16(0xA0000));
    try testing.expectEqual(@as(u16, 0x0000), f.bus.read16(0xFBFFE));
}

test "bus: I/O exact-register model (D14) — SYSCFG" {
    var f = try Fixture.setup();
    defer f.teardown();

    // 16-bit access wholly inside I/O hits the exact register.
    f.bus.write16(syscfg_addr, 0x0001);
    try testing.expectEqual(@as(u16, 0x0001), f.bus.read16(syscfg_addr));
    // Adjacent registers never combine: $80001 (SYSID slot, unimplemented
    // until Block 8) is independent and reads $0000.
    try testing.expectEqual(@as(u16, 0x0000), f.bus.read16(0x80001));
    // Byte access touches the register's low byte.
    try testing.expectEqual(@as(u8, 0x01), f.bus.read8(syscfg_addr));
    f.bus.write8(syscfg_addr, 0x00);
    try testing.expectEqual(@as(u16, 0x0000), f.bus.read16(syscfg_addr));
    // Undefined SYSCFG bits are masked off and read as zero (§3.1).
    f.bus.write16(syscfg_addr, 0xFFFF);
    try testing.expectEqual(@as(u16, 0x0001), f.bus.read16(syscfg_addr));
    f.bus.write16(syscfg_addr, 0x0000);
}

test "bus: region-straddling 16-bit accesses route per byte (§1.7)" {
    var f = try Fixture.setup();
    defer f.teardown();

    // RAM/I-O edge: low byte from RAM $7FFFF, high byte = SYSCFG low byte.
    f.bus.write8(0x7FFFF, 0x5A);
    f.bus.write16(syscfg_addr, 0x0001);
    try testing.expectEqual(@as(u16, 0x015A), f.bus.read16(0x7FFFF));
    // A straddling write: low byte lands in RAM; high byte is a byte write
    // to SYSCFG's low byte.
    f.bus.write16(0x7FFFF, 0x00A7);
    try testing.expectEqual(@as(u8, 0xA7), f.bus.read8(0x7FFFF));
    try testing.expectEqual(@as(u16, 0x0000), f.bus.read16(syscfg_addr)); // bit 0 cleared

    // I-O/open-bus edge: low byte from $80FFF (unimplemented → $00),
    // high byte from open bus ($00).
    try testing.expectEqual(@as(u16, 0x0000), f.bus.read16(0x80FFF));

    // Open-bus/ROM edge: high byte comes from ROM byte 0.
    try f.rom.loadFromSlice(&.{0xC3});
    try testing.expectEqual(@as(u16, 0xC300), f.bus.read16(0xFBFFF));
}

test "bus: address wrap $FFFFF → $00000 (§1.7)" {
    var f = try Fixture.setup();
    defer f.teardown();

    var image: [rom_mod.size]u8 = @splat(0);
    image[rom_mod.size - 1] = 0x9D; // ROM byte at $FFFFF
    try f.rom.loadFromSlice(&image);
    f.bus.write8(0x00000, 0x3C); // RAM byte at $00000

    // 16-bit read at the top of the address space: low byte $FFFFF (ROM),
    // high byte wraps to $00000 (RAM).
    try testing.expectEqual(@as(u16, 0x3C9D), f.bus.read16(0xFFFFF));
    // Wrapping write: low byte ignored (ROM), high byte lands at $00000.
    f.bus.write16(0xFFFFF, 0x77EE);
    try testing.expectEqual(@as(u8, 0x9D), f.bus.read8(0xFFFFF));
    try testing.expectEqual(@as(u8, 0x77), f.bus.read8(0x00000));
    // Addresses above 20 bits are masked before routing.
    try testing.expectEqual(@as(u8, 0x77), f.bus.read8(0xF00000));
}

test "bus: ROM shadow round-trip — copy, patch, enable, read through $FCxxx (task 2.4)" {
    var f = try Fixture.setup();
    defer f.teardown();

    // Build a recognisable ROM image.
    var image: [rom_mod.size]u8 = undefined;
    for (&image, 0..) |*b, i| b.* = @truncate(i);
    try f.rom.loadFromSlice(&image);

    // 1. Copy ROM ($FC000–$FFFFF) → shadow window ($3C000–$3FFFF) via the bus
    //    (the amendment §2.2 procedure, sans BIOS).
    var off: u32 = 0;
    while (off < rom_mod.size) : (off += 1) {
        f.bus.write8(shadow_base + off, f.bus.read8(rom_base + off));
    }
    // 2. Patch the copy.
    f.bus.write8(shadow_base + 0x123, 0xEA);
    // 3. Enable shadow — reads at $FC123 now come from the patched window.
    f.bus.write16(syscfg_addr, 0x0001);
    try testing.expectEqual(@as(u8, 0xEA), f.bus.read8(rom_base + 0x123));
    // Unpatched bytes still read the copied values.
    try testing.expectEqual(@as(u8, @truncate(0x456)), f.bus.read8(rom_base + 0x456));
    // Shadowed "ROM" is live-patchable: writes to $FCxxx land in the window.
    f.bus.write16(rom_base + 0x200, 0xF00D);
    try testing.expectEqual(@as(u16, 0xF00D), f.bus.read16(rom_base + 0x200));
    try testing.expectEqual(@as(u16, 0xF00D), f.bus.read16(shadow_base + 0x200));
    // 4. Disable — real ROM is back, unmodified.
    f.bus.write16(syscfg_addr, 0x0000);
    try testing.expectEqual(@as(u8, @truncate(0x123)), f.bus.read8(rom_base + 0x123));
    try testing.expectEqual(@as(u16, 0x0100), f.bus.read16(rom_base + 0x200)); // image bytes $00,$01 (LE)
}

test "bus: full address-space walk verifies routing everywhere (task 2.5)" {
    var f = try Fixture.setup();
    defer f.teardown();

    var image: [rom_mod.size]u8 = undefined;
    for (&image, 0..) |*b, i| b.* = @truncate(i *% 7);
    try f.rom.loadFromSlice(&image);

    // Write a marker byte at every 257th address (prime stride hits odd and
    // even, all pages), then read it back and check per-region behaviour.
    var addr: u32 = 0;
    while (addr <= util.addr_mask) : (addr += 257) {
        f.bus.write8(addr, 0xA5);
    }
    // The stride never lands on SYSCFG ($80000 is not a multiple of 257),
    // so shadow stays disabled throughout.
    try testing.expect(!f.bus.shadowEnabled());
    addr = 0;
    while (addr <= util.addr_mask) : (addr += 257) {
        const got = f.bus.read8(addr);
        switch (regionOf(addr)) {
            .ram => try testing.expectEqual(@as(u8, 0xA5), got),
            // Only SYSCFG is implemented in Block 2; everything else in the
            // I/O region ignores writes and reads $00.
            .io => try testing.expectEqual(@as(u8, if (addr == syscfg_addr) 0x01 else 0x00), got),
            .open_bus => try testing.expectEqual(@as(u8, 0x00), got),
            // Shadow disabled → writes were ignored; the image shows through.
            .rom => try testing.expectEqual(@as(u8, @truncate((addr - rom_base) *% 7)), got),
        }
    }

    // Full ROM sweep for good measure.
    addr = rom_base;
    while (addr <= util.addr_mask) : (addr += 1) {
        try testing.expectEqual(@as(u8, @truncate((addr - rom_base) *% 7)), f.bus.read8(addr));
    }
}
