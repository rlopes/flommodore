//! bootcheck — Block 12 boot-sequence verifier (part 3/3 groundwork for
//! task 12.16).
//!
//! Usage: bootcheck <flommodore.rom>
//!
//! Loads the flas+fll-built BIOS ROM into a real Machine, runs exactly one
//! frame (240,000 cycles — the full boot needs ~50K), and audits the §6.8
//! Stage 1–6 postconditions: the ROM header, the CPU environment (task
//! 12.1), the RAM clears (12.2), the device safe defaults (12.3), the
//! palette copy + VIC base registers (12.4), the banner (12.12), and the
//! stage-6 IRQ unmasking with the shell parked in its GETLINE poll
//! (12.13).
//!
//! DECISION bk: boot verification is a state audit — pinning the shell's
//! PC would churn the check every time BIOS code grows. bootcheck asserts
//! the observable Stage 1–6 postconditions, reading RAM directly and I/O
//! through the debugger's side-effect-free `peek16` path (inspecting boot
//! state must not dequeue the keyboard queue it just flushed); the
//! build-graph golden boot frame covers the visible pixels. Addresses and
//! expected values are transcribed
//! from Phase 6 §6.8, Phase 3 §3.8, and Phase 5 — not from bios.asm — so
//! the BIOS and its test cannot share a typo.
//!
//! Wired into `zig build test` (and standalone `zig build boottest`): flas
//! assembles src/bios/bios.asm, `fll --raw --base $FC000 --size 16K` emits
//! the image, and this tool must approve it. TEST-ONLY scaffolding.

const std = @import("std");
const rom_mod = @import("rom");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");

// --- Phase 6 §6.3 ROM header -----------------------------------------------
const hdr_entry_off: u32 = 0x0C; // BIOS kernel entry pointer
const rom_base: u32 = 0xFC000;
const vectors_off: u32 = 0x3FC0; // $FFFC0 - $FC000

// --- Phase 6 §6.8 Stage 1 boot environment ---------------------------------
const boot_sp: u32 = 0x01100;
const boot_ssp: u32 = 0x020F0;
const boot_ivt: u32 = 0xFFFC0;

// --- BIOS RAM (decisions bd/bi) --------------------------------------------
const cur_attr_addr: u32 = 0x01104; // expected $0001: white on black
const palram: u32 = 0x02100; // 768 B palette RAM
const satram: u32 = 0x02400; // 512 B sprite attribute table
const textmat: u32 = 0x02600; // 80×43×2 = 6880 B text matrix
const rom_palette_off: u32 = 0xFF800 - rom_base; // §6.6 default palette

// --- Phase 3 §3.8 VIC registers --------------------------------------------
const reg_vmode: u32 = 0x80200;
const reg_vresx: u32 = 0x80202;
const reg_vresy: u32 = 0x80203;
const reg_vpalbase_lo: u32 = 0x8020B;
const reg_vsatbase_lo: u32 = 0x8020D;
const reg_vtmapbase_lo: u32 = 0x8020F;
const reg_vsprena: u32 = 0x80213;
const reg_virqen: u32 = 0x80216;

// --- Phase 5 I/O registers --------------------------------------------------
const reg_tactrl: u32 = 0x80014;
const reg_tbctrl: u32 = 0x8001C;
const reg_kctrl: u32 = 0x80023;
const reg_jctrl: u32 = 0x80032;
const reg_irqmask: u32 = 0x80041;
const reg_amvol: u32 = 0x80140; // AUR master block +$40

var failures: u32 = 0;

fn check(ok: bool, comptime what: []const u8, got: u32, want: u32) void {
    if (ok) return;
    failures += 1;
    std.debug.print("bootcheck: FAIL {s}: got ${X}, want ${X}\n", .{ what, got, want });
}

fn checkEq(got: u32, want: u32, comptime what: []const u8) void {
    check(got == want, what, got, want);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: bootcheck <flommodore.rom>\n", .{});
        return error.BadUsage;
    }

    const image = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 20));

    // ------------------------------------------------------------------
    // The image itself: 16KB, 'F','L' magic, and the header's entry
    // pointer must agree with the RESET vector — both name `boot`.
    // ------------------------------------------------------------------
    checkEq(@intCast(image.len), rom_mod.size, "image size");
    if (failures != 0) return error.BootCheckFailed; // nothing else is safe to index
    checkEq(image[0], 'F', "header magic[0]");
    checkEq(image[1], 'L', "header magic[1]");
    const hdr_entry = std.mem.readInt(u32, image[hdr_entry_off..][0..4], .little);
    const reset_vec = std.mem.readInt(u32, image[vectors_off..][0..4], .little);
    checkEq(hdr_entry, reset_vec, "header entry == RESET vector");
    check(reset_vec >= rom_base + 0x200, "RESET vector in kernel area", reset_vec, rom_base + 0x200);

    // ------------------------------------------------------------------
    // Boot: load, reset, one full frame — plenty for the ~50K-cycle boot;
    // the rest of the frame is the shell polling an empty keyboard queue.
    // ------------------------------------------------------------------
    const gpa = init.gpa;
    const m = try machine_mod.Machine.create(gpa);
    defer m.destroy(gpa);
    try m.rom.loadFromSlice(image);
    m.cpu.reset(&m.bus);
    checkEq(m.cpu.pc, reset_vec, "PC from RESET vector");
    m.runFrame();

    // Stage 1 — CPU & stack environment (task 12.1). The booted machine
    // is BUSY: the shell's GETLINE polls KSTAT with four registers saved
    // (LR/R5/R6/R7 — hence SP exactly 16 below the boot value).
    check(!m.cpu.halted, "CPU busy in the shell (not halted)", 1, 0);
    check(m.cpu.pc >= 0xFC200 and m.cpu.pc < 0xFE000, "PC inside the kernel", m.cpu.pc, 0xFC200);
    check(m.cpu.flags & cpu_mod.flag_s != 0, "FLAGS.S (supervisor)", m.cpu.flags, cpu_mod.flag_s);
    check(m.cpu.flags & cpu_mod.flag_i != 0, "FLAGS.I set (Stage 6 ran)", m.cpu.flags, cpu_mod.flag_i);
    checkEq(m.cpu.getReg(cpu_mod.Gab16.sp), boot_sp - 16, "SP (GETLINE's four saves)");
    checkEq(m.cpu.ssp, boot_ssp, "SSP");
    checkEq(m.cpu.usp, boot_sp, "USP mirrors boot SP");
    checkEq(m.cpu.ivt, boot_ivt, "IVT");

    // Stages 2 + 5 — the matrix went through the stage-2 clear, the
    // stage-5 CLRSCR, and the banner: row 0 opens with the stars, READY.
    // sits on row 3, and the cursor waits at the start of row 4.
    checkEq(m.ram.readByte(textmat), '*', "banner stars at (0,0)");
    checkEq(m.ram.readByte(textmat + 3 * 160), 'R', "READY. on row 3");
    const cc = @as(u32, m.ram.readByte(0x01100)) | (@as(u32, m.ram.readByte(0x01101)) << 8);
    const cr = @as(u32, m.ram.readByte(0x01102)) | (@as(u32, m.ram.readByte(0x01103)) << 8);
    checkEq(cc, 0, "cursor column home for input");
    checkEq(cr, 4, "cursor on the input row");
    const cur_attr = @as(u32, m.ram.readByte(cur_attr_addr)) |
        (@as(u32, m.ram.readByte(cur_attr_addr + 1)) << 8);
    checkEq(cur_attr, 0x0001, "CUR_ATTR white-on-black");
    const rng = @as(u32, m.ram.readByte(0x01106)) |
        (@as(u32, m.ram.readByte(0x01107)) << 8);
    checkEq(rng, 0x0001, "RNG_STATE seeded $0001 (amendment G18)");

    // Stage 3 — device safe defaults (task 12.3), through peek16 so the
    // audit itself is side-effect-free.
    checkEq(m.io.peek16(reg_tactrl), 0, "TACTRL disabled");
    checkEq(m.io.peek16(reg_tbctrl), 0, "TBCTRL disabled");
    checkEq(m.io.peek16(reg_irqmask), 0x15, "IRQMASK: timer A + keyboard + VBLANK (Stage 6)");
    checkEq(m.io.peek16(reg_kctrl), 0x0001, "KCTRL key IRQ enabled, flush clear");
    checkEq(m.io.peek16(reg_jctrl), 0, "JCTRL passive");
    checkEq(m.io.peek16(reg_amvol), 0, "AUR master volume muted");
    checkEq(m.io.peek16(reg_virqen), 0, "VIRQEN off");
    checkEq(m.io.peek16(reg_vsprena), 0, "VSPRENA off");
    checkEq(m.io.peek16(reg_vmode), 3, "VMODE text");
    checkEq(m.io.peek16(reg_vresx), 1, "VRESX 640");
    checkEq(m.io.peek16(reg_vresy), 1, "VRESY 360");

    // Stage 4 — palette copy + VIC bases (task 12.4, ÷16 convention).
    checkEq(m.io.peek16(reg_vpalbase_lo), (palram / 16) & 0xFF, "VPALBASE lo");
    checkEq(m.io.peek16(reg_vpalbase_lo + 1), (palram / 16) >> 8, "VPALBASE hi");
    checkEq(m.io.peek16(reg_vsatbase_lo), (satram / 16) & 0xFF, "VSATBASE lo");
    checkEq(m.io.peek16(reg_vsatbase_lo + 1), (satram / 16) >> 8, "VSATBASE hi");
    checkEq(m.io.peek16(reg_vtmapbase_lo), (textmat / 16) & 0xFF, "VTMAPBASE lo");
    checkEq(m.io.peek16(reg_vtmapbase_lo + 1), (textmat / 16) >> 8, "VTMAPBASE hi");

    var pal_mismatch: u32 = 0;
    var pal_nonzero = false;
    var i: u32 = 0;
    while (i < 768) : (i += 1) {
        const want = image[rom_palette_off + i];
        if (want != 0) pal_nonzero = true;
        if (m.ram.readByte(palram + i) != want) pal_mismatch += 1;
    }
    checkEq(pal_mismatch, 0, "palette RAM == ROM $FF800 (bytes off)");
    check(pal_nonzero, "ROM palette not all-zero", 0, 1);

    if (failures != 0) {
        std.debug.print("bootcheck: {d} check(s) FAILED\n", .{failures});
        return error.BootCheckFailed;
    }
    std.debug.print(
        "bootcheck: {s} boots clean to READY. — §6.8 stages 1–6 postconditions hold ({d} cycles budgeted, shell polling at ${X:0>5})\n",
        .{ args[1], @as(u32, 240_000), m.cpu.pc },
    );
}
