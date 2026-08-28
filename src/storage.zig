//! Flommodore — `storage.zig` (Block 14, task 14.4).
//!
//! FDD-1, the sector storage device (amendment v1.3 §2): registers at
//! `$80050–$8005F`, one fixed 512-byte sector size, a flat 16-bit LBA, a
//! DMA buffer in general RAM, and a completion flag that reaches the CPU
//! through IRQ source 7 (v1.3 D53 — the last reserved source).
//!
//! This is the smallest device that lets the machine keep anything. Before
//! it, Phase 6 §6.10's `LOAD` command had nothing to load from and every
//! application that produces data — a sound designer, a sprite editor, a
//! tracker, a game with saved progress — was blocked.
//!
//! Host-I/O-free, like every other device module: `Storage` owns a slice
//! of sector bytes that main.zig or the harness attaches and flushes. The
//! module never opens a file, so all of it runs under `zig build test`.
//!
//! Timing: `tick()` is called once per master cycle, from machine.zig
//! rather than io.tick — the transfer needs RAM access, and that is where
//! it lives. A command is busy for exactly `busy_cycles` and the transfer
//! commits at the completion cycle (v1.3 D51/D52), so a correctly polling
//! program can never observe a half-done sector.
//!
//! Implementation decisions where amendment v1.3 §2 is silent (marked at
//! use sites; candidates for a v1.4 amendment):
//!   STO-a  Command 0 and unrecognised codes 4–255 are ignored outright:
//!          no busy window, no error, no completion. Only 1/2/3 are
//!          accepted. (v1.3 defines no error code for "bad command", and
//!          inventing one to describe a write nobody should make buys
//!          nothing.)
//!   STO-b  Usable sectors are capped at 65,535, not 65,536: the identify
//!          record reports the count in a 16-bit field, and a 65,536-
//!          sector volume would report 0. Trailing sectors of a larger
//!          image are unreachable.
//!   STO-c  Completed writes are announced through `takeDirty()`; the
//!          caller flushes that sector to the backing file. The device
//!          itself never touches the host filesystem.
//!   STO-d  Error priority at completion: no media, then bad buffer, then
//!          per command — for a write, write-protection outranks a bad
//!          LBA (a protected disk should say so, not quibble about the
//!          sector number).
//!   STO-e  STSTAT's write-protect bit only shows with media present; it
//!          describes the volume, and with no volume there is nothing to
//!          protect.
//!   STO-f  STCTRL bit 0 is sampled at completion, not at acceptance —
//!          the §5.5 model in which a device-level enable gates the
//!          *setting* of the IRQSTAT bit.
//!   STO-g  All validation happens at completion rather than acceptance.
//!          Media cannot change during a command in this machine (there
//!          is no eject), so the distinction is unobservable, and one
//!          validation site is easier to keep correct than two.

const std = @import("std");
const ram_mod = @import("ram");

const Ram = ram_mod.Ram;

pub const base_addr: u32 = 0x80050;
pub const end_addr: u32 = 0x8005F;

// Register offsets from $80050 (v1.3 §2.2). Single 16-bit registers, not
// LO/HI byte pairs (D50): D14 already makes every I/O address a 16-bit
// register, and both the LBA and the buffer base fit one.
const r_stcmd: u32 = 0x0; // write-only
const r_ststat: u32 = 0x1; // read-only
const r_stlba: u32 = 0x2;
const r_stbuf: u32 = 0x3; // buffer base ÷ 16
const r_stctrl: u32 = 0x4;
const r_sterr: u32 = 0x5; // read-only

// STSTAT bits (v1.3 §2.2).
const st_busy: u16 = 0x0001;
const st_media: u16 = 0x0002;
const st_error: u16 = 0x0004;
const st_protected: u16 = 0x0008;

// Commands (v1.3 §2.3).
pub const cmd_none: u8 = 0;
pub const cmd_read: u8 = 1;
pub const cmd_write: u8 = 2;
pub const cmd_identify: u8 = 3;

// Error codes (v1.3 §2.6).
pub const err_none: u8 = 0;
pub const err_no_media: u8 = 1;
pub const err_bad_lba: u8 = 2;
pub const err_write_protected: u8 = 3;
pub const err_bad_buffer: u8 = 4;
pub const err_busy: u8 = 5;

/// One sector, everywhere (D54).
pub const sector_size: u32 = 512;

/// Every accepted command is busy for exactly this many master cycles,
/// whatever it is and however it ends (D52). 139 µs at 14.4 MHz.
pub const busy_cycles: u32 = 2000;

/// STO-b: the identify count is 16-bit, so 65,535 is the last usable LBA.
pub const max_sectors: u32 = 65535;

/// General RAM ends here; the whole 512-byte block must fit below it
/// (Phase 1 §1.1 — VRAM above is the VIC's, and the DMA buffer is not).
const general_ram_end: u32 = 0x40000;

/// Backing for the no-media default. A zero-length array needs no storage;
/// naming it keeps the slice default unambiguous.
var empty_media: [0]u8 = .{};

pub const Storage = struct {
    /// Sector image, owned by the host (main.zig / the harness), never by
    /// this module. Empty ⇒ no media.
    image: []u8 = &empty_media,
    write_protected: bool = false,

    // Registers.
    lba: u16 = 0,
    buf: u16 = 0, // ÷ 16
    ctrl: u16 = 0, // bit 0 = IRQ on completion
    err: u8 = err_none,

    // Command in flight.
    busy: u32 = 0, // master cycles remaining; 0 = idle
    cmd: u8 = cmd_none,
    cmd_lba: u16 = 0, // latched at acceptance (§2.3)
    cmd_buf: u16 = 0,

    /// Sector index of the most recently completed write (STO-c). The
    /// caller takes it and flushes that sector to the backing file.
    dirty_lba: ?u16 = null,

    pub fn init() Storage {
        return .{};
    }

    /// Attach a host image. `image` must outlive the device; a slice
    /// shorter than one sector counts as no media.
    pub fn attach(s: *Storage, image: []u8, write_protected: bool) void {
        s.image = image;
        s.write_protected = write_protected;
    }

    /// Usable sectors on the attached volume (STO-b).
    pub fn sectorCount(s: *const Storage) u32 {
        const whole: u32 = @intCast(@min(s.image.len / sector_size, max_sectors));
        return whole;
    }

    fn mediaPresent(s: *const Storage) bool {
        return s.sectorCount() > 0;
    }

    /// Take the pending flush notification, if any (STO-c).
    pub fn takeDirty(s: *Storage) ?u16 {
        const d = s.dirty_lba;
        s.dirty_lba = null;
        return d;
    }

    /// One master cycle. Returns true when a completing command should
    /// raise IRQ source 7 (STCTRL bit 0 gates the *setting*, STO-f).
    pub fn tick(s: *Storage, ram: *Ram) bool {
        if (s.busy == 0) return false;
        s.busy -= 1;
        if (s.busy != 0) return false;
        s.complete(ram);
        return (s.ctrl & 0x0001) != 0;
    }

    /// Command acceptance (§2.3). Writing while busy is rejected outright.
    fn accept(s: *Storage, cmd: u8) void {
        if (s.busy != 0) {
            s.err = err_busy; // rejected: no latch, no completion, no IRQ
            return;
        }
        switch (cmd) {
            cmd_read, cmd_write, cmd_identify => {},
            else => return, // STO-a: 0 and 4–255 are ignored outright
        }
        s.err = err_none; // acceptance clears the previous outcome
        s.cmd = cmd;
        s.cmd_lba = s.lba; // latched — later writes don't affect this command
        s.cmd_buf = s.buf;
        s.busy = busy_cycles;
    }

    /// The completion cycle: validate, then transfer atomically (D51).
    fn complete(s: *Storage, ram: *Ram) void {
        const cmd = s.cmd;
        s.cmd = cmd_none;
        const base = @as(u32, s.cmd_buf) * 16;

        // STO-d: priority is media, then buffer, then per-command.
        if (!s.mediaPresent()) {
            s.err = err_no_media;
            return;
        }
        if (base + sector_size > general_ram_end) {
            s.err = err_bad_buffer;
            return;
        }
        switch (cmd) {
            cmd_read => {
                if (s.cmd_lba >= s.sectorCount()) {
                    s.err = err_bad_lba;
                    return;
                }
                const off = @as(u32, s.cmd_lba) * sector_size;
                var i: u32 = 0;
                while (i < sector_size) : (i += 1) {
                    ram.writeByte(base + i, s.image[off + i]);
                }
            },
            cmd_write => {
                if (s.write_protected) {
                    s.err = err_write_protected;
                    return;
                }
                if (s.cmd_lba >= s.sectorCount()) {
                    s.err = err_bad_lba;
                    return;
                }
                const off = @as(u32, s.cmd_lba) * sector_size;
                var i: u32 = 0;
                while (i < sector_size) : (i += 1) {
                    s.image[off + i] = ram.readByte(base + i);
                }
                s.dirty_lba = s.cmd_lba; // STO-c: the host flushes it
            },
            cmd_identify => s.writeIdentify(ram, base),
            else => {},
        }
        s.err = err_none;
    }

    /// The identify record (§2.3), zero-padded to a full sector so every
    /// command moves exactly one block.
    fn writeIdentify(s: *const Storage, ram: *Ram, base: u32) void {
        var rec: [16]u8 = @splat(0);
        rec[0] = 'F';
        rec[1] = 'D';
        rec[2] = 'D';
        rec[3] = '1';
        std.mem.writeInt(u16, rec[4..6], 1, .little); // device version
        std.mem.writeInt(u16, rec[6..8], @intCast(sector_size), .little);
        std.mem.writeInt(u16, rec[8..10], @intCast(s.sectorCount()), .little);
        std.mem.writeInt(u16, rec[10..12], @intFromBool(s.write_protected), .little);
        var i: u32 = 0;
        while (i < sector_size) : (i += 1) {
            ram.writeByte(base + i, if (i < rec.len) rec[i] else 0);
        }
    }

    fn status(s: *const Storage) u16 {
        var v: u16 = 0;
        if (s.busy != 0) v |= st_busy;
        if (s.mediaPresent()) {
            v |= st_media;
            if (s.write_protected) v |= st_protected; // STO-e
        }
        if (s.err != err_none) v |= st_error;
        return v;
    }

    // ------------------------------------------------------------------
    // Register dispatch — 16-bit register per exact address (D14).
    // No register has a read side effect, so peek16 == read16 for the
    // whole block (v1.3 §7.6).
    // ------------------------------------------------------------------

    pub fn read(s: *const Storage, addr: u32) u16 {
        return switch (addr - base_addr) {
            r_stcmd => 0x0000, // write-only
            r_ststat => s.status(),
            r_stlba => s.lba,
            r_stbuf => s.buf,
            r_stctrl => s.ctrl,
            r_sterr => s.err,
            else => 0x0000, // $80056–$8005F reserved
        };
    }

    pub fn write(s: *Storage, addr: u32, value: u16) void {
        switch (addr - base_addr) {
            r_stcmd => s.accept(@truncate(value)),
            r_ststat => {}, // read-only
            r_stlba => s.lba = value,
            r_stbuf => s.buf = value,
            r_stctrl => s.ctrl = value & 0x0001,
            r_sterr => {}, // read-only
            else => {},
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const expectEqual = testing.expectEqual;

const Fixture = struct {
    ram: *Ram,
    dev: *Storage,
    image: []u8,

    fn setup(sectors: u32) !Fixture {
        const ram = try testing.allocator.create(Ram);
        errdefer testing.allocator.destroy(ram);
        const dev = try testing.allocator.create(Storage);
        errdefer testing.allocator.destroy(dev);
        const image = try testing.allocator.alloc(u8, sectors * sector_size);
        @memset(image, 0);
        ram.init();
        dev.* = Storage.init();
        dev.attach(image, false);
        return .{ .ram = ram, .dev = dev, .image = image };
    }

    fn teardown(f: *Fixture) void {
        testing.allocator.free(f.image);
        testing.allocator.destroy(f.dev);
        testing.allocator.destroy(f.ram);
    }

    /// Issue a command and run the busy window out. Returns whether the
    /// completion asked for the IRQ.
    fn run(f: *Fixture, cmd: u8, lba: u16, buf_div16: u16) bool {
        f.dev.write(base_addr + r_stlba, lba);
        f.dev.write(base_addr + r_stbuf, buf_div16);
        f.dev.write(base_addr + r_stcmd, cmd);
        var irq = false;
        var c: u32 = 0;
        while (c < busy_cycles) : (c += 1) {
            if (f.dev.tick(f.ram)) irq = true;
        }
        return irq;
    }
};

test "14.4 registers: round-trip, read-only enforcement, reserved reads zero" {
    var f = try Fixture.setup(4);
    defer f.teardown();
    const d = f.dev;

    d.write(base_addr + r_stlba, 0xBEEF);
    d.write(base_addr + r_stbuf, 0x1234);
    try expectEqual(@as(u16, 0xBEEF), d.read(base_addr + r_stlba));
    try expectEqual(@as(u16, 0x1234), d.read(base_addr + r_stbuf));
    // STCTRL keeps one bit.
    d.write(base_addr + r_stctrl, 0xFFFF);
    try expectEqual(@as(u16, 0x0001), d.read(base_addr + r_stctrl));
    // STCMD is write-only; STSTAT and STERR are read-only.
    try expectEqual(@as(u16, 0x0000), d.read(base_addr + r_stcmd));
    d.write(base_addr + r_ststat, 0xFFFF);
    d.write(base_addr + r_sterr, 0xFFFF);
    try expectEqual(@as(u16, st_media), d.read(base_addr + r_ststat));
    try expectEqual(@as(u16, err_none), d.read(base_addr + r_sterr));
    // Reserved tail.
    try expectEqual(@as(u16, 0), d.read(base_addr + 0x6));
    try expectEqual(@as(u16, 0), d.read(end_addr));
}

test "14.4 read: sector lands in RAM, atomically at completion" {
    var f = try Fixture.setup(4);
    defer f.teardown();
    // Sector 2 gets a recognisable pattern.
    for (0..sector_size) |i| f.image[2 * sector_size + i] = @truncate(i +% 7);

    const buf: u16 = 0x02100 / 16;
    f.dev.write(base_addr + r_stlba, 2);
    f.dev.write(base_addr + r_stbuf, buf);
    f.dev.write(base_addr + r_stcmd, cmd_read);
    // Busy immediately, and nothing has moved yet (D51).
    try expectEqual(@as(u16, st_busy | st_media), f.dev.read(base_addr + r_ststat));
    var c: u32 = 0;
    while (c < busy_cycles - 1) : (c += 1) _ = f.dev.tick(f.ram);
    try expectEqual(@as(u8, 0), f.ram.readByte(0x02100)); // still untouched
    _ = f.dev.tick(f.ram); // the completion cycle
    try expectEqual(@as(u16, st_media), f.dev.read(base_addr + r_ststat));
    try expectEqual(@as(u16, err_none), f.dev.read(base_addr + r_sterr));
    for (0..sector_size) |i| {
        try expectEqual(@as(u8, @truncate(i +% 7)), f.ram.readByte(0x02100 + @as(u32, @intCast(i))));
    }
}

test "14.4 write: RAM lands in the sector and announces the flush" {
    var f = try Fixture.setup(4);
    defer f.teardown();
    const buf: u16 = 0x03000 / 16;
    for (0..sector_size) |i| f.ram.writeByte(0x03000 + @as(u32, @intCast(i)), @truncate(i *% 3));

    try testing.expect(f.dev.takeDirty() == null);
    _ = f.run(cmd_write, 1, buf);
    try expectEqual(@as(u16, err_none), f.dev.read(base_addr + r_sterr));
    for (0..sector_size) |i| {
        try expectEqual(@as(u8, @truncate(i *% 3)), f.image[sector_size + i]);
    }
    try expectEqual(@as(?u16, 1), f.dev.takeDirty());
    try testing.expect(f.dev.takeDirty() == null); // taken once
}

test "14.4 identify: the record describes the volume, padded to a sector" {
    var f = try Fixture.setup(9);
    defer f.teardown();
    f.dev.attach(f.image, true); // write-protected volume
    const buf: u16 = 0x02100 / 16;
    _ = f.run(cmd_identify, 0xFFFF, buf); // LBA ignored (§2.3)
    try expectEqual(@as(u16, err_none), f.dev.read(base_addr + r_sterr));
    try expectEqual(@as(u8, 'F'), f.ram.readByte(0x02100));
    try expectEqual(@as(u8, 'D'), f.ram.readByte(0x02101));
    try expectEqual(@as(u8, 'D'), f.ram.readByte(0x02102));
    try expectEqual(@as(u8, '1'), f.ram.readByte(0x02103));
    try expectEqual(@as(u8, 1), f.ram.readByte(0x02104)); // version
    try expectEqual(@as(u8, 0x00), f.ram.readByte(0x02106)); // 512 = $0200
    try expectEqual(@as(u8, 0x02), f.ram.readByte(0x02107));
    try expectEqual(@as(u8, 9), f.ram.readByte(0x02108)); // sector count
    try expectEqual(@as(u8, 1), f.ram.readByte(0x0210A)); // write-protected
    try expectEqual(@as(u8, 0), f.ram.readByte(0x02110)); // padded
    try expectEqual(@as(u8, 0), f.ram.readByte(0x022FF)); // …to 512 bytes
    // STSTAT advertises the protection (STO-e).
    try expectEqual(@as(u16, st_media | st_protected), f.dev.read(base_addr + r_ststat));
}

test "14.4 errors: no media, bad LBA, write protect, bad buffer — each completes" {
    // No media: the device still completes, it just reports why not.
    var empty = try Fixture.setup(0);
    defer empty.teardown();
    try expectEqual(@as(u16, 0), empty.dev.read(base_addr + r_ststat)); // no media bit
    _ = empty.run(cmd_read, 0, 0x02100 / 16);
    try expectEqual(@as(u16, err_no_media), empty.dev.read(base_addr + r_sterr));
    try expectEqual(@as(u16, st_error), empty.dev.read(base_addr + r_ststat));

    var f = try Fixture.setup(4);
    defer f.teardown();
    // Bad LBA: 4 sectors means 0–3.
    _ = f.run(cmd_read, 4, 0x02100 / 16);
    try expectEqual(@as(u16, err_bad_lba), f.dev.read(base_addr + r_sterr));
    // Bad buffer: VRAM is not general RAM, and neither is a block that
    // would straddle the boundary.
    _ = f.run(cmd_read, 0, 0x40000 / 16);
    try expectEqual(@as(u16, err_bad_buffer), f.dev.read(base_addr + r_sterr));
    _ = f.run(cmd_read, 0, 0x3FF00 / 16); // starts inside, ends outside
    try expectEqual(@as(u16, err_bad_buffer), f.dev.read(base_addr + r_sterr));
    _ = f.run(cmd_read, 0, 0x3FE00 / 16); // the last legal buffer
    try expectEqual(@as(u16, err_none), f.dev.read(base_addr + r_sterr));
    // Write protection outranks a bad LBA (STO-d).
    f.dev.attach(f.image, true);
    _ = f.run(cmd_write, 99, 0x02100 / 16);
    try expectEqual(@as(u16, err_write_protected), f.dev.read(base_addr + r_sterr));
    // A fresh acceptance clears the previous outcome.
    f.dev.attach(f.image, false);
    _ = f.run(cmd_write, 0, 0x02100 / 16);
    try expectEqual(@as(u16, err_none), f.dev.read(base_addr + r_sterr));
    try expectEqual(@as(u16, st_media), f.dev.read(base_addr + r_ststat));
}

test "14.4 busy is exactly 2,000 cycles; a command during it is refused" {
    var f = try Fixture.setup(4);
    defer f.teardown();
    const d = f.dev;
    d.write(base_addr + r_stbuf, 0x02100 / 16);
    d.write(base_addr + r_stcmd, cmd_identify);
    try testing.expect(d.read(base_addr + r_ststat) & st_busy != 0);
    var c: u32 = 0;
    while (c < busy_cycles - 1) : (c += 1) {
        try testing.expect(!d.tick(f.ram));
        try testing.expect(d.read(base_addr + r_ststat) & st_busy != 0);
    }
    // A second command inside the window: refused, and it neither
    // disturbs the one in flight nor produces a second completion.
    d.write(base_addr + r_stcmd, cmd_read);
    try expectEqual(@as(u16, err_busy), d.read(base_addr + r_sterr));
    _ = d.tick(f.ram); // cycle 2,000 — the original completes
    try testing.expect(d.read(base_addr + r_ststat) & st_busy == 0);
    try expectEqual(@as(u8, 'F'), f.ram.readByte(0x02100)); // identify ran
    // Idle ticks cost nothing and ask for nothing.
    try testing.expect(!d.tick(f.ram));
}

test "14.4 completion IRQ follows STCTRL bit 0; unknown commands are inert" {
    var f = try Fixture.setup(4);
    defer f.teardown();
    const buf: u16 = 0x02100 / 16;
    try testing.expect(!f.run(cmd_identify, 0, buf)); // STCTRL clear: no IRQ
    f.dev.write(base_addr + r_stctrl, 1);
    try testing.expect(f.run(cmd_identify, 0, buf));
    // Even a failing command completes and raises (v1.3 §2.5) — a program
    // waiting on the IRQ can never hang on a bad command.
    f.dev.attach(f.image, true);
    try testing.expect(f.run(cmd_write, 0, buf));
    try expectEqual(@as(u16, err_write_protected), f.dev.read(base_addr + r_sterr));
    // STO-a: command 0 and unrecognised codes do nothing at all.
    f.dev.write(base_addr + r_sterr, 0); // read-only; state unchanged
    f.dev.write(base_addr + r_stcmd, cmd_none);
    try testing.expect(f.dev.read(base_addr + r_ststat) & st_busy == 0);
    f.dev.write(base_addr + r_stcmd, 42);
    try testing.expect(f.dev.read(base_addr + r_ststat) & st_busy == 0);
    try expectEqual(@as(u16, err_write_protected), f.dev.read(base_addr + r_sterr)); // untouched
}
