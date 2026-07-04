//! Flommodore — `machine.zig` (Block 6).
//!
//! Machine composition and the scanline-quantum frame loop, shared by the
//! emulator (main.zig) and the headless harness — the golden-frame tests
//! (task 6.21) are only meaningful if both run *identical* raster timing.
//! (Layout note: added beyond the Block 1 file list for exactly that
//! single-source-of-truth reason, like flapp.zig.)
//!
//! Per-cycle ordering (pinned, io.zig header): sample IRQ line → CPU step →
//! device tick. Per-line ordering (v1.1 §4/§5.6): vic.startLine (raster /
//! VBLANK IRQs assert at the START of the line) → run CYCLES_PER_LINE
//! cycles → vic.renderLine (the line draws with post-handler state).

const std = @import("std");
const util = @import("util");
const ram_mod = @import("ram");
const rom_mod = @import("rom");
const io_mod = @import("io");
const bus_mod = @import("bus");
const cpu_mod = @import("cpu");
const vic_mod = @import("vic256");

pub const Machine = struct {
    ram: *ram_mod.Ram,
    rom: *rom_mod.Rom,
    io: *io_mod.Io,
    vic: *vic_mod.Vic,
    bus: bus_mod.Bus,
    cpu: cpu_mod.Gab16,

    pub fn create(gpa: std.mem.Allocator) !*Machine {
        const m = try gpa.create(Machine);
        errdefer gpa.destroy(m);
        m.ram = try gpa.create(ram_mod.Ram);
        errdefer gpa.destroy(m.ram);
        m.rom = try gpa.create(rom_mod.Rom);
        errdefer gpa.destroy(m.rom);
        m.io = try gpa.create(io_mod.Io);
        errdefer gpa.destroy(m.io);
        m.vic = try gpa.create(vic_mod.Vic);
        m.ram.init();
        m.rom.init();
        m.io.* = io_mod.Io.init();
        m.vic.init();
        m.io.vic = m.vic; // $80200–$802FF dispatch (Block 6)
        m.bus = bus_mod.Bus.init(m.ram, m.rom, m.io);
        return m;
    }

    pub fn destroy(m: *Machine, gpa: std.mem.Allocator) void {
        gpa.destroy(m.vic);
        gpa.destroy(m.io);
        gpa.destroy(m.rom);
        gpa.destroy(m.ram);
        gpa.destroy(m);
    }

    /// One master cycle.
    pub inline fn cycle(m: *Machine) void {
        m.cpu.irq_line = m.io.irqLine();
        _ = m.cpu.step(&m.bus);
        m.io.tick();
    }

    /// One full frame — exactly 240,000 cycles in every mode (D17/D41,
    /// util.mode_timing). Frame geometry latches at startFrame (VIC
    /// DECISION A), so the whole frame runs one line structure.
    pub fn runFrame(m: *Machine) void {
        const timing = m.vic.startFrame();
        var line: u32 = 0;
        while (line < timing.total_lines) : (line += 1) {
            const irqs = m.vic.startLine(line);
            if (irqs.vblank) m.io.raise(io_mod.irq_vblank);
            if (irqs.raster) m.io.raise(io_mod.irq_raster);
            var c: u32 = 0;
            while (c < timing.cycles_per_line) : (c += 1) {
                m.cycle();
            }
            m.vic.renderLine(line, m.ram, m.rom);
        }
        // ── frame hook: audio push of 735 samples (Block 7).
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "machine: a frame is exactly 240,000 cycles; VBLANK IRQ reaches the CPU" {
    const m = try Machine.create(testing.allocator);
    defer m.destroy(testing.allocator);
    // ROM: RESET → $FC200: SEI; JMPA self. IRQ vector → handler: count, ack, RTI.
    var image: [rom_mod.size]u8 = @splat(0);
    std.mem.writeInt(u32, image[rom_mod.vectors_offset..][0..4], 0xFC200, .little);
    std.mem.writeInt(u32, image[rom_mod.vectors_offset + 8 ..][0..4], 0xFC300, .little);
    const encode = @import("encode");
    const setup = [_]u32{
        encode.li(15, 0x1100), //  SP
        encode.li(1, 0xFFC0), //   IVT = $FFFC0
        encode.lui(1, 0xF),
        encode.mtsr(.ivt, 1),
        encode.li(2, 0x0200), //   VIC: enable VBLANK IRQ (VIRQEN $80216)
        encode.lui(2, 0x8),
        encode.li(3, 1),
        encode.sw(2, 0x16, 3),
        encode.li(4, 0x0040), //   IRQMASK = VBLANK bit ($80041)
        encode.lui(4, 0x8),
        encode.li(3, 0x10),
        encode.sw(4, 1, 3),
        encode.sei(),
        encode.jmpa(0xFC234), //   spin (address of this instruction)
    };
    for (setup, 0..) |w, i| {
        std.mem.writeInt(u32, image[0x200 + 4 * i ..][0..4], w, .little);
    }
    const handler = [_]u32{
        encode.addi(10, 10, 1),
        encode.li(5, 0x0042), //   IRQACK ($80042) ← VBLANK bit
        encode.lui(5, 0x8),
        encode.li(3, 0x10),
        encode.sw(5, 0, 3),
        encode.rti(),
    };
    for (handler, 0..) |w, i| {
        std.mem.writeInt(u32, image[0x300 + 4 * i ..][0..4], w, .little);
    }
    try m.rom.loadFromSlice(&image);
    m.cpu.reset(&m.bus);

    m.runFrame();
    try testing.expectEqual(@as(u32, 240_000), m.cpu.cyc);
    try testing.expectEqual(@as(u32, 1), m.cpu.getReg(10)); // one VBLANK per frame
    m.runFrame();
    try testing.expectEqual(@as(u32, 480_000), m.cpu.cyc);
    try testing.expectEqual(@as(u32, 2), m.cpu.getReg(10));
}
