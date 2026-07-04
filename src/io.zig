//! Flommodore — `io.zig` (Block 4).
//!
//! The I/O region `$80000–$80FFF` (Phase 5): register dispatch, system
//! configuration, both timers, the IRQ controller, and the keyboard /
//! joystick register sets (queues and state live here; SDL feeds them in
//! Block 8; AUR-1 and VIC-256 registers arrive in Blocks 6–7).
//!
//! Access model (D14/§3.1, composition per D47): every register is a 16-bit
//! value at its exact address; registers narrower than 16 bits read back
//! with the upper bits zero; reserved/undefined bits read zero and ignore
//! writes. Byte access hits the low byte (the bus performs the D47
//! read-modify-write for byte writes).
//!
//! Timing: `tick()` advances the devices by exactly one master cycle and is
//! called once per CPU step of any kind (D41 — instructions, deliveries,
//! and halted idle all cost 1 cycle). Emulator ordering, documented: the
//! CPU step runs first, then `tick()`; the CPU samples the IRQ line at the
//! start of the next step, so a device event in cycle k is deliverable from
//! cycle k+1.
//!
//! Implementation decisions where Phase 5 is silent (marked at use sites,
//! candidates for a v1.3 amendment):
//!   a. Timer load semantics: the counter is loaded from the reload value
//!      (and the prescaler cleared) when TxCTRL bit 0 transitions 0→1.
//!      Writing the reload registers while running changes only the value
//!      used at the next reload.
//!   b. Timer period: expiry occurs every `reload × divisor` master cycles
//!      exactly — required by the normative rate table ("÷8, reload 40 →
//!      45.0 kHz exact"). A reload of 0 behaves as 65536 (16-bit wrap).
//!   c. SYSPWR reads as 0; SYSVER reads $01 (v1 firmware).
//!   d. KDATA reads $0000 when the queue is empty; KSTAT bit 1 reflects
//!      "queue currently full" (new events are dropped while set).
//!   e. IRQACK is write-only and reads $0000.

const std = @import("std");
const util = @import("util");
const vic_mod = @import("vic256");

// ---------------------------------------------------------------------------
// Register addresses (Phase 5 §5.1–§5.5; audit Appendix D).
// ---------------------------------------------------------------------------

pub const io_base: u32 = 0x80000;

// System configuration (§5.1)
pub const syscfg_addr: u32 = 0x80000;
pub const sysid_addr: u32 = 0x80001;
pub const sysver_addr: u32 = 0x80002;
pub const syspwr_addr: u32 = 0x80003;

// Timers (§5.2)
pub const timer_a_base: u32 = 0x80010;
pub const timer_b_base: u32 = 0x80018;

// Keyboard (§5.3)
pub const kstat_addr: u32 = 0x80020;
pub const kdata_addr: u32 = 0x80021;
pub const kmod_addr: u32 = 0x80022;
pub const kctrl_addr: u32 = 0x80023;

// Joysticks (§5.4)
pub const joy1_addr: u32 = 0x80030;
pub const joy2_addr: u32 = 0x80031;
pub const jctrl_addr: u32 = 0x80032;

// IRQ controller (§5.5)
pub const irqstat_addr: u32 = 0x80040;
pub const irqmask_addr: u32 = 0x80041;
pub const irqack_addr: u32 = 0x80042;

/// IRQ source bits (§5.5). Bit 7 is reserved.
pub const irq_timer_a: u8 = 1 << 0;
pub const irq_timer_b: u8 = 1 << 1;
pub const irq_keyboard: u8 = 1 << 2;
pub const irq_joystick: u8 = 1 << 3;
pub const irq_vblank: u8 = 1 << 4;
pub const irq_raster: u8 = 1 << 5;
pub const irq_audio: u8 = 1 << 6;
const irq_defined_mask: u8 = 0x7F;

/// Machine ID (§5.1): $F1 = Flommodore.
pub const machine_id: u8 = 0xF1;
/// DECISION c: firmware version reported by SYSVER.
pub const firmware_version: u8 = 0x01;

// ---------------------------------------------------------------------------
// Timer (§5.2, v1.1 §3.2: bit 1 repeat, 0 = one-shot which disables itself).
// ---------------------------------------------------------------------------

const Timer = struct {
    reload: u16 = 0, // assembled from TxLOADLO/TxLOADHI
    count: u16 = 0, // TxCNTLO/TxCNTHI, read-only
    ctrl: u16 = 0, // bit 0 enable | bit 1 repeat | bit 2 IRQ enable
    div: u16 = 0, // bits 1:0 — 0=÷1, 1=÷8, 2=÷64, 3=÷256
    expired: bool = false, // TxSTAT bit 0, w1c
    prescaler: u32 = 0,

    const ctrl_mask: u16 = 0x0007;
    const div_mask: u16 = 0x0003;

    fn divisor(t: *const Timer) u32 {
        return switch (@as(u2, @truncate(t.div))) {
            0 => 1,
            1 => 8,
            2 => 64,
            3 => 256,
        };
    }

    /// One master cycle. Returns true on an expiry event (the IRQ candidate;
    /// the caller applies the TxCTRL bit-2 gate).
    fn tick(t: *Timer) bool {
        if (t.ctrl & 0x0001 == 0) return false;
        t.prescaler += 1;
        if (t.prescaler < t.divisor()) return false;
        t.prescaler = 0;
        t.count -%= 1; // DECISION b: reload 0 wraps → period 65536
        if (t.count != 0) return false;
        t.expired = true;
        if (t.ctrl & 0x0002 != 0) {
            t.count = t.reload; // repeat: next period is another `reload` ticks
        } else {
            t.ctrl &= ~@as(u16, 0x0001); // one-shot disables itself (v1.1 §3.2)
        }
        return true;
    }

    fn writeCtrl(t: *Timer, value: u16) void {
        const was_enabled = (t.ctrl & 0x0001) != 0;
        t.ctrl = value & ctrl_mask;
        const now_enabled = (t.ctrl & 0x0001) != 0;
        if (!was_enabled and now_enabled) {
            // DECISION a: 0→1 enable loads the counter and clears the
            // prescaler, so the first period is exactly reload × divisor.
            t.count = t.reload;
            t.prescaler = 0;
        }
    }

    /// Register read/write by offset from the timer base (§5.2 table).
    fn read(t: *const Timer, offset: u32) u16 {
        return switch (offset) {
            0 => t.reload & 0x00FF, // TxLOADLO — byte register, upper bits zero
            1 => t.reload >> 8, //     TxLOADHI
            2 => t.count & 0x00FF, //  TxCNTLO (read-only)
            3 => t.count >> 8, //      TxCNTHI (read-only)
            4 => t.ctrl, //            TxCTRL
            5 => t.div, //             TxDIV
            6 => @intFromBool(t.expired), // TxSTAT bit 0
            else => 0x0000, // +07 reserved
        };
    }

    fn write(t: *Timer, offset: u32, value: u16) void {
        switch (offset) {
            0 => t.reload = (t.reload & 0xFF00) | (value & 0x00FF),
            1 => t.reload = (t.reload & 0x00FF) | ((value & 0x00FF) << 8),
            2, 3 => {}, // TxCNT is read-only
            4 => t.writeCtrl(value),
            5 => t.div = value & div_mask,
            6 => if (value & 0x0001 != 0) {
                t.expired = false; // w1c
            },
            else => {},
        }
    }
};

// ---------------------------------------------------------------------------
// Keyboard (§5.3). The 16-entry queue and register semantics live here;
// SDL enqueues via `keyEvent` in Block 8.
// ---------------------------------------------------------------------------

const Keyboard = struct {
    queue: [16]u16 = @splat(0),
    head: usize = 0,
    len: usize = 0,
    kmod: u16 = 0, // bit 0 shift | 1 ctrl | 2 alt | 3 super
    irq_enable: bool = false, // KCTRL bit 0
    locks: u16 = 0, // KSTAT bits 2 (caps) / 3 (num), host-mirrored in Block 8

    fn kstat(kb: *const Keyboard) u16 {
        var v: u16 = 0;
        if (kb.len > 0) v |= 0x0001; // event available
        if (kb.len == kb.queue.len) v |= 0x0002; // DECISION d: queue full
        return v | (kb.locks & 0x000C);
    }

    /// Dequeue — the KDATA side effect, fired on ANY read width (§3.1).
    fn dequeue(kb: *Keyboard) u16 {
        if (kb.len == 0) return 0x0000; // DECISION d: empty reads $0000
        const scancode = kb.queue[kb.head];
        kb.head = (kb.head + 1) % kb.queue.len;
        kb.len -= 1;
        return scancode;
    }

    /// Enqueue a 16-bit scancode event (bit 15 = key up). Returns true if
    /// the event was accepted and should raise the keyboard IRQ (subject to
    /// KCTRL bit 0); events are dropped while the queue is full (§5.3).
    fn enqueue(kb: *Keyboard, scancode: u16) bool {
        if (kb.len == kb.queue.len) return false;
        kb.queue[(kb.head + kb.len) % kb.queue.len] = scancode;
        kb.len += 1;
        return true;
    }

    fn flush(kb: *Keyboard) void {
        kb.head = 0;
        kb.len = 0;
    }
};

// ---------------------------------------------------------------------------
// The I/O region.
// ---------------------------------------------------------------------------

pub const Io = struct {
    syscfg: u16 = 0,
    /// SYSPWR bit 0 written 1: the emulator must exit cleanly (§5.1). The
    /// main loop / harness polls this.
    power_off: bool = false,
    timer_a: Timer = .{},
    timer_b: Timer = .{},
    keyboard: Keyboard = .{},
    joy1: u8 = 0, // 0 = nothing pressed (§5.4)
    joy2: u8 = 0,
    jctrl: u16 = 0, // bit 0 = IRQ on state change
    irqstat: u8 = 0, // raw pending, mask-independent (§5.5)
    irqmask: u8 = 0,
    /// VIC-256 register dispatch ($80200–$802FF), wired by machine.zig
    /// (Block 6). Null until then — reads return $0000, writes are ignored,
    /// matching the Block 4 behaviour.
    vic: ?*vic_mod.Vic = null,

    pub fn init() Io {
        return .{};
    }

    /// ROM shadow enable — SYSCFG bit 0 (§5.1); the bus queries this.
    pub fn shadowEnabled(io: *const Io) bool {
        return (io.syscfg & 0x0001) != 0;
    }

    /// The single CPU IRQ line: asserted while (IRQSTAT & IRQMASK) ≠ 0
    /// (§5.5). Level-sensitive; cleared only by IRQACK.
    pub fn irqLine(io: *const Io) bool {
        return (io.irqstat & io.irqmask) != 0;
    }

    /// A device raises its IRQSTAT bit (device-level enables are applied by
    /// the caller — they gate the *setting*, §5.5). Pub: the VIC and AUR-1
    /// raise through machine.zig.
    pub fn raise(io: *Io, source: u8) void {
        io.irqstat |= source & irq_defined_mask;
    }

    /// Advance every cycle-counting device by one master cycle (D41: called
    /// once per CPU step of any kind).
    pub fn tick(io: *Io) void {
        if (io.timer_a.tick() and (io.timer_a.ctrl & 0x0004) != 0) io.raise(irq_timer_a);
        if (io.timer_b.tick() and (io.timer_b.ctrl & 0x0004) != 0) io.raise(irq_timer_b);
    }

    // ------------------------------------------------------------------
    // Block 8 entry points (SDL input) — usable by unit tests today.
    // ------------------------------------------------------------------

    /// Keyboard event from the host. Raises IRQ bit 2 if KCTRL bit 0 is set.
    pub fn keyEvent(io: *Io, scancode: u16) void {
        if (io.keyboard.enqueue(scancode) and io.keyboard.irq_enable) {
            io.raise(irq_keyboard);
        }
    }

    /// Joystick state from the host. Any bit transition of either port
    /// raises IRQ bit 3 if JCTRL bit 0 is set (§5.4).
    pub fn setJoystick(io: *Io, port: u1, state: u8) void {
        const old = if (port == 0) io.joy1 else io.joy2;
        if (port == 0) io.joy1 = state else io.joy2 = state;
        if (state != old and (io.jctrl & 0x0001) != 0) {
            io.raise(irq_joystick);
        }
    }

    // ------------------------------------------------------------------
    // Register dispatch (task 4.1) — 16-bit register per exact address.
    // NOTE: read16 takes *Io because KDATA dequeues on read (§3.1).
    // ------------------------------------------------------------------

    pub fn read16(io: *Io, addr: u32) u16 {
        std.debug.assert(addr >= io_base and addr <= 0x80FFF);
        if (addr >= timer_a_base and addr < timer_a_base + 8) return io.timer_a.read(addr - timer_a_base);
        if (addr >= timer_b_base and addr < timer_b_base + 8) return io.timer_b.read(addr - timer_b_base);
        if (addr >= vic_mod.base_addr and addr <= vic_mod.end_addr) {
            return if (io.vic) |v| v.read(addr) else 0x0000;
        }
        return switch (addr) {
            syscfg_addr => io.syscfg,
            sysid_addr => machine_id, // read-only (§5.1)
            sysver_addr => firmware_version, // read-only
            syspwr_addr => 0x0000, // DECISION c
            kstat_addr => io.keyboard.kstat(),
            kdata_addr => io.keyboard.dequeue(), // side effect on ANY width (§3.1)
            kmod_addr => io.keyboard.kmod,
            kctrl_addr => @intFromBool(io.keyboard.irq_enable), // flush bit is self-clearing
            joy1_addr => io.joy1,
            joy2_addr => io.joy2,
            jctrl_addr => io.jctrl,
            irqstat_addr => io.irqstat, // raw, mask-independent (§5.5)
            irqmask_addr => io.irqmask,
            irqack_addr => 0x0000, // DECISION e: write-only
            else => 0x0000, // reserved / not-yet-implemented (AUR-1 Block 7, VIC-256 Block 6)
        };
    }

    pub fn write16(io: *Io, addr: u32, value: u16) void {
        std.debug.assert(addr >= io_base and addr <= 0x80FFF);
        if (addr >= timer_a_base and addr < timer_a_base + 8) return io.timer_a.write(addr - timer_a_base, value);
        if (addr >= timer_b_base and addr < timer_b_base + 8) return io.timer_b.write(addr - timer_b_base, value);
        if (addr >= vic_mod.base_addr and addr <= vic_mod.end_addr) {
            if (io.vic) |v| v.write(addr, value);
            return;
        }
        switch (addr) {
            syscfg_addr => io.syscfg = value & 0x0001, // bit 0 only (D47.5)
            sysid_addr, sysver_addr => {}, // read-only
            syspwr_addr => {
                if (value & 0x0001 != 0) io.power_off = true; // §5.1: clean exit
            },
            kstat_addr => {}, // read-only
            kdata_addr => {}, // writes undefined → ignored (the D47 RMW read still dequeued)
            kmod_addr => io.keyboard.kmod = value & 0x000F, // host-fed in Block 8
            kctrl_addr => {
                io.keyboard.irq_enable = (value & 0x0001) != 0;
                if (value & 0x0002 != 0) io.keyboard.flush(); // write-1, self-clearing (§5.3)
            },
            joy1_addr, joy2_addr => {}, // read-only (host-fed)
            jctrl_addr => io.jctrl = value & 0x0001,
            irqstat_addr => {}, // read-only (§5.5)
            irqmask_addr => io.irqmask = @truncate(value & irq_defined_mask),
            irqack_addr => io.irqstat &= ~@as(u8, @truncate(value & irq_defined_mask)), // w1c per source
            else => {},
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const expectEqual = testing.expectEqual;

test "4.2 system config: SYSID $F1, SYSVER, SYSCFG bit 0, SYSPWR exit" {
    var io = Io.init();
    try expectEqual(@as(u16, 0xF1), io.read16(sysid_addr));
    try expectEqual(@as(u16, 0x01), io.read16(sysver_addr));
    io.write16(sysid_addr, 0xFFFF); // read-only
    try expectEqual(@as(u16, 0xF1), io.read16(sysid_addr));
    io.write16(syscfg_addr, 0xFFFF); // only bit 0 defined
    try expectEqual(@as(u16, 0x0001), io.read16(syscfg_addr));
    try testing.expect(io.shadowEnabled());
    io.write16(syscfg_addr, 0);
    try testing.expect(!io.shadowEnabled());
    try testing.expect(!io.power_off);
    io.write16(syspwr_addr, 0x0000);
    try testing.expect(!io.power_off);
    io.write16(syspwr_addr, 0x0001);
    try testing.expect(io.power_off);
    try expectEqual(@as(u16, 0x0000), io.read16(syspwr_addr)); // DECISION c
}

test "4.3 timer: exact period reload × divisor at every prescale (14.4 MHz)" {
    // The §5.2 rate table is normative: ÷8 with reload 40 must expire every
    // 320 cycles → 45.0 kHz exactly at 14.4 MHz.
    const cases = [_]struct { div: u16, reload: u16, period: u32 }{
        .{ .div = 0, .reload = 20, .period = 20 }, //     ÷1
        .{ .div = 1, .reload = 40, .period = 320 }, //    ÷8 → 45.0 kHz
        .{ .div = 1, .reload = 80, .period = 640 }, //    ÷8 → 22.5 kHz
        .{ .div = 2, .reload = 3, .period = 192 }, //     ÷64
        .{ .div = 3, .reload = 2, .period = 512 }, //     ÷256
    };
    for (cases) |c| {
        var io = Io.init();
        io.write16(timer_a_base + 0, c.reload & 0xFF);
        io.write16(timer_a_base + 1, c.reload >> 8);
        io.write16(timer_a_base + 5, c.div);
        io.write16(timer_a_base + 4, 0x0003); // enable | repeat
        // First expiry after exactly `period` ticks, then every `period`.
        var cycle: u32 = 0;
        var expiries: u32 = 0;
        while (cycle < c.period * 3) : (cycle += 1) {
            io.tick();
            const expired = io.read16(timer_a_base + 6) & 1 != 0;
            if (expired) {
                expiries += 1;
                try expectEqual(@as(u32, 0), (cycle + 1) % c.period); // exact boundary
                io.write16(timer_a_base + 6, 1); // w1c for the next round
            }
        }
        try expectEqual(@as(u32, 3), expiries);
    }
}

test "4.3 timer: one-shot disables itself; enable reloads count and prescaler" {
    var io = Io.init();
    io.write16(timer_a_base + 0, 5);
    io.write16(timer_a_base + 4, 0x0001); // enable, one-shot, no IRQ
    try expectEqual(@as(u16, 5), io.read16(timer_a_base + 2)); // count loaded
    for (0..5) |_| io.tick();
    try expectEqual(@as(u16, 1), io.read16(timer_a_base + 6)); // expired
    try expectEqual(@as(u16, 0), io.read16(timer_a_base + 4) & 1); // self-disabled
    try expectEqual(@as(u16, 0), io.read16(timer_a_base + 2)); // count froze at 0
    for (0..20) |_| io.tick(); // disabled: nothing moves
    try expectEqual(@as(u16, 0), io.read16(timer_a_base + 2));
    // Re-enable: count reloads, full period again.
    io.write16(timer_a_base + 6, 1); // clear STAT
    io.write16(timer_a_base + 4, 0x0001);
    try expectEqual(@as(u16, 5), io.read16(timer_a_base + 2));
    for (0..4) |_| io.tick();
    try expectEqual(@as(u16, 0), io.read16(timer_a_base + 6) & 1); // not yet
    io.tick();
    try expectEqual(@as(u16, 1), io.read16(timer_a_base + 6) & 1);
}

test "4.3 timer: LOAD registers are byte-wide; CNT is read-only; reload mid-run" {
    var io = Io.init();
    io.write16(timer_a_base + 0, 0xABCD); // only the low byte lands
    io.write16(timer_a_base + 1, 0x1112);
    try expectEqual(@as(u16, 0xCD), io.read16(timer_a_base + 0));
    try expectEqual(@as(u16, 0x12), io.read16(timer_a_base + 1));
    io.write16(timer_a_base + 2, 0x99); // CNT read-only
    io.write16(timer_a_base + 3, 0x99);
    try expectEqual(@as(u16, 0), io.read16(timer_a_base + 2));
    // Reload written while running takes effect at the next reload only.
    var io2 = Io.init();
    io2.write16(timer_a_base + 0, 4);
    io2.write16(timer_a_base + 4, 0x0003); // enable | repeat
    io2.tick();
    io2.write16(timer_a_base + 0, 200); // mid-period
    try expectEqual(@as(u16, 3), io2.read16(timer_a_base + 2)); // count untouched
    for (0..3) |_| io2.tick(); // finish the 4-tick period
    try expectEqual(@as(u16, 1), io2.read16(timer_a_base + 6) & 1);
    try expectEqual(@as(u16, 200), io2.read16(timer_a_base + 2)); // reloaded new value
}

test "4.4 timers A and B tick independently" {
    var io = Io.init();
    io.write16(timer_a_base + 0, 3);
    io.write16(timer_b_base + 0, 5);
    io.write16(timer_a_base + 4, 0x0003);
    io.write16(timer_b_base + 4, 0x0003);
    for (0..3) |_| io.tick();
    try expectEqual(@as(u16, 1), io.read16(timer_a_base + 6) & 1);
    try expectEqual(@as(u16, 0), io.read16(timer_b_base + 6) & 1);
    for (0..2) |_| io.tick();
    try expectEqual(@as(u16, 1), io.read16(timer_b_base + 6) & 1);
    // A expired at tick 3, reloaded to 3, then ticked twice more → count 1.
    try expectEqual(@as(u16, 1), io.read16(timer_a_base + 2));
}

test "4.5/4.6 IRQ controller: raw IRQSTAT, mask, w1c ack, device gate" {
    var io = Io.init();
    // Timer A with IRQ enable, Timer B without.
    io.write16(timer_a_base + 0, 2);
    io.write16(timer_b_base + 0, 2);
    io.write16(timer_a_base + 4, 0x0007); // enable | repeat | IRQ
    io.write16(timer_b_base + 4, 0x0003); // enable | repeat (no IRQ)
    for (0..2) |_| io.tick();
    // A raised its bit; B's device gate blocked the set (§5.5).
    try expectEqual(@as(u16, irq_timer_a), io.read16(irqstat_addr));
    // Raw and mask-independent: line stays low until masked in.
    try testing.expect(!io.irqLine());
    io.write16(irqmask_addr, irq_timer_a);
    try testing.expect(io.irqLine());
    // IRQSTAT is read-only.
    io.write16(irqstat_addr, 0x0000);
    try expectEqual(@as(u16, irq_timer_a), io.read16(irqstat_addr));
    // IRQACK is w1c per source and write-only.
    io.write16(irqack_addr, irq_timer_b); // wrong bit: no effect
    try testing.expect(io.irqLine());
    io.write16(irqack_addr, irq_timer_a);
    try testing.expect(!io.irqLine());
    try expectEqual(@as(u16, 0), io.read16(irqstat_addr));
    try expectEqual(@as(u16, 0), io.read16(irqack_addr)); // DECISION e
    // TxSTAT is independent of IRQACK (separate latch).
    try expectEqual(@as(u16, 1), io.read16(timer_a_base + 6) & 1);
    // Reserved bit 7 can't be set or masked.
    io.write16(irqmask_addr, 0xFFFF);
    try expectEqual(@as(u16, 0x7F), io.read16(irqmask_addr));
}

test "4.8 keyboard: queue, dequeue-on-read, overflow drop, flush, KCTRL" {
    var io = Io.init();
    try expectEqual(@as(u16, 0x0000), io.read16(kstat_addr)); // sane defaults
    try expectEqual(@as(u16, 0x0000), io.read16(kdata_addr)); // empty → $0000
    // Enqueue 3 events without IRQ enable: no IRQSTAT bit.
    io.keyEvent(0x0004); // 'a' down
    io.keyEvent(0x8004); // 'a' up
    io.keyEvent(0x0005);
    try expectEqual(@as(u16, 0), io.read16(irqstat_addr));
    try expectEqual(@as(u16, 0x0001), io.read16(kstat_addr)); // event available
    try expectEqual(@as(u16, 0x0004), io.read16(kdata_addr)); // FIFO order
    try expectEqual(@as(u16, 0x8004), io.read16(kdata_addr)); // key-up bit intact
    try expectEqual(@as(u16, 0x0005), io.read16(kdata_addr));
    try expectEqual(@as(u16, 0x0000), io.read16(kstat_addr));
    // IRQ enable via KCTRL bit 0.
    io.write16(kctrl_addr, 0x0001);
    io.keyEvent(0x0006);
    try expectEqual(@as(u16, irq_keyboard), io.read16(irqstat_addr));
    io.write16(irqack_addr, irq_keyboard);
    // Fill to 16: full flag set, further events dropped (§5.3).
    var i: u16 = 0;
    while (io.read16(kstat_addr) & 0x0002 == 0) : (i += 1) io.keyEvent(0x0100 + i);
    try expectEqual(@as(u16, 15), i); // 1 already queued + 15 = 16
    io.keyEvent(0x0BAD); // dropped
    try expectEqual(@as(u16, 0x0006), io.read16(kdata_addr)); // head unchanged
    // Flush: write-1, self-clearing.
    io.write16(kctrl_addr, 0x0003); // IRQ enable + flush
    try expectEqual(@as(u16, 0x0000), io.read16(kstat_addr));
    try expectEqual(@as(u16, 0x0001), io.read16(kctrl_addr)); // flush bit not stored
    // KMOD round-trips its 4 defined bits.
    io.write16(kmod_addr, 0xFFFF);
    try expectEqual(@as(u16, 0x000F), io.read16(kmod_addr));
}

test "4.9 joystick: default zero, state read, transition IRQ via JCTRL" {
    var io = Io.init();
    try expectEqual(@as(u16, 0), io.read16(joy1_addr));
    try expectEqual(@as(u16, 0), io.read16(joy2_addr));
    io.setJoystick(0, 0x09); // Up + Right (§5.4)
    try expectEqual(@as(u16, 0x09), io.read16(joy1_addr));
    try expectEqual(@as(u16, 0), io.read16(irqstat_addr)); // JCTRL off: no IRQ
    io.write16(jctrl_addr, 0x0001);
    io.setJoystick(0, 0x09); // no transition: no IRQ
    try expectEqual(@as(u16, 0), io.read16(irqstat_addr));
    io.setJoystick(1, 0x40); // fire 1 on port 2: transition
    try expectEqual(@as(u16, irq_joystick), io.read16(irqstat_addr));
    io.write16(joy1_addr, 0xFF); // read-only from the bus side
    try expectEqual(@as(u16, 0x09), io.read16(joy1_addr));
}

test "4.1 dispatch: adjacent registers never combine; reserved reads zero" {
    var io = Io.init();
    io.write16(syscfg_addr, 1);
    // Exact-address model: $80000 and $80001 are independent registers.
    try expectEqual(@as(u16, 0x0001), io.read16(syscfg_addr));
    try expectEqual(@as(u16, 0x00F1), io.read16(sysid_addr));
    // Every address in the region answers without crashing.
    var addr: u32 = io_base;
    while (addr <= 0x80FFF) : (addr += 1) {
        if (addr == kdata_addr) continue; // side-effecting; tested above
        _ = io.read16(addr);
    }
    try expectEqual(@as(u16, 0), io.read16(0x80050)); // reserved expansion
    try expectEqual(@as(u16, 0), io.read16(0x80FFF));
}
