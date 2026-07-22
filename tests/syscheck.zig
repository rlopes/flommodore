//! syscheck — Block 12 syscall ABI verifier (tasks 12.5–12.16: the full syscall ABI, the IRQ dispatcher, autoboot, and the published §8.3 hello).
//!
//! Usage: syscheck <flommodore.rom> <hello.raw>
//!
//! Boots the BIOS exactly like bootcheck, then drives system calls through
//! their PERMANENT jump-table addresses ($FC100 + 4×id — the public ABI,
//! not the private implementation labels) and audits the console contract:
//! glyph/attribute placement, the decision-bl control characters (LF, CR,
//! non-destructive BS), column-80 wrap, the row-42 scroll, cursor clamping,
//! attribute packing, multi-line scrolls, and the decision-be register
//! conventions (R5–R11/R13/SP preserved, unimplemented slots answer $FFFF
//! per decision bj).
//!
//! DECISION bm: syscalls are exercised by HOST-INJECTED calls on a booted
//! machine — the checker plants a single HLT word in free RAM, points LR
//! at it, sets PC to the jump-table entry and the argument registers, and
//! runs cycles until the CPU halts. The RET→HLT round trip proves the
//! CALLA/RET contract from the caller's side without a guest test
//! program. Cursor state and the matrix are then read straight
//! from RAM; expected addresses come from the specs and the decision-bi
//! System Variables layout, not from bios.asm.
//!
//! Wired into `zig build test` (and standalone `zig build systest`).
//! TEST-ONLY scaffolding.

const std = @import("std");
const rom_mod = @import("rom");
const cpu_mod = @import("cpu");
const machine_mod = @import("machine");
const encode = @import("encode");

// --- Phase 6 §6.4: the permanent jump table ---------------------------------
const jump_table: u32 = 0xFC100;
const sys_putchar: u32 = 0;
const sys_putstr: u32 = 1;
const sys_clrscr: u32 = 2;
const sys_setcursor: u32 = 3;
const sys_setcolor: u32 = 4;
const sys_scroll: u32 = 5;
const sys_getkey: u32 = 6;
const sys_pollkey: u32 = 7;
const sys_getchar: u32 = 8;
const sys_getline: u32 = 9;
const sys_setmode: u32 = 10;
const sys_setpal: u32 = 11;
const sys_loadpal: u32 = 12;
const sys_vblank: u32 = 13;
const sys_fillscr: u32 = 14;
const sys_memcmp: u32 = 17;
const sys_sndinit: u32 = 18;
const sys_sndplay: u32 = 19;
const sys_sndstop: u32 = 20;
const sys_sndvol: u32 = 21;
const sys_tset: u32 = 22;
const sys_twait: u32 = 23;
const sys_getid: u32 = 24;
const sys_irqset: u32 = 26;
const sys_rand: u32 = 27;
const sys_seed: u32 = 28;
const sys_reserved_29: u32 = 29; // first reserved slot (decision bj)

// --- Decision bi/bd BIOS RAM -------------------------------------------------
const cur_col: u32 = 0x01100;
const cur_row: u32 = 0x01102;
const cur_attr: u32 = 0x01104;
const textmat: u32 = 0x02600;
const palram_base: u32 = 0x02100;
const vmode_cur: u32 = 0x01108;
const cols: u32 = 80;
const rows: u32 = 43;

// --- Host scratch (Program/User RAM, untouched by boot) ----------------------
const stub_addr: u32 = 0x05000; // one HLT word: the syscall "caller"
const str_addr: u32 = 0x05100; // NUL-terminated test strings

var failures: u32 = 0;

fn check(ok: bool, comptime what: []const u8, got: u32, want: u32) void {
    if (ok) return;
    failures += 1;
    std.debug.print("syscheck: FAIL {s}: got ${X}, want ${X}\n", .{ what, got, want });
}

fn checkEq(got: u32, want: u32, comptime what: []const u8) void {
    check(got == want, what, got, want);
}

const M = machine_mod.Machine;

fn ramWord(m: *M, addr: u32) u32 {
    return @as(u32, m.ram.readByte(addr)) | (@as(u32, m.ram.readByte(addr + 1)) << 8);
}

/// Character byte of the cell at (row, col).
fn cellChar(m: *M, row: u32, col: u32) u32 {
    return m.ram.readByte(textmat + row * cols * 2 + col * 2);
}

/// Attribute byte of the cell at (row, col).
fn cellAttr(m: *M, row: u32, col: u32) u32 {
    return m.ram.readByte(textmat + row * cols * 2 + col * 2 + 1);
}

/// Host-injected system call (decision bm): argument registers in, PC at
/// the jump-table entry, LR at the HLT stub; run until the CPU halts.
/// Steps through the REAL frame loop (not bare cycles) so scanline-timed
/// state — VSTAT.VBLANK for SYS_VBLANK — advances exactly as it would in
/// the emulator. Returns R1 (the result register, decision be).
fn syscall(m: *M, id: u32, r1: u32, r2: u32, r3: u32) u32 {
    m.cpu.setReg(1, r1);
    m.cpu.setReg(2, r2);
    m.cpu.setReg(3, r3);
    m.cpu.setReg(cpu_mod.Gab16.lr, stub_addr);
    m.cpu.pc = jump_table + 4 * id;
    m.cpu.halted = false;
    var budget: u64 = 3_000_000; // SYS_SCROLL 43 needs ~1.5M cycles
    outer: while (budget > 0) {
        var fs = m.beginFrame();
        while (budget > 0) {
            budget -= 1;
            const r = m.stepFrameCycle(&fs);
            if (m.cpu.halted) break :outer;
            if (r.frame_done) break;
        }
    }
    check(m.cpu.halted, "syscall returned to the HLT stub", 0, 1);
    return m.cpu.getReg(1);
}

/// Run N whole frames through the real frame loop, halted or not — IRQs
/// wake a parked CPU exactly as they do in the emulator.
fn runFrames(m: *M, n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var fs = m.beginFrame();
        while (!m.stepFrameCycle(&fs).frame_done) {}
    }
}

/// Frames end at arbitrary cycles — possibly mid-dispatcher, with an IRQ
/// frame on the stack and FLAGS.I hardware-cleared. Forcing the next
/// injected call there would abandon that frame (a permanent stack leak)
/// and lose the I flag. Settle: step until the CPU parks at its HLT.
fn settle(m: *M) void {
    var budget: u32 = 500_000;
    while (!m.cpu.halted and budget > 0) {
        var fs = m.beginFrame();
        while (budget > 0) {
            budget -= 1;
            if (m.stepFrameCycle(&fs).frame_done) break;
            if (m.cpu.halted) return;
        }
    }
    check(m.cpu.halted, "CPU settled back to the parked HLT", 0, 1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: syscheck <flommodore.rom> <hello.raw>\n", .{});
        return error.BadUsage;
    }
    const image = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 20));
    const hello_raw = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(1 << 20));

    // Boot exactly like bootcheck: one frame lands the machine in the
    // shell's GETLINE poll (stage 6 ran — IRQs unmasked, FLAGS.I set).
    const gpa = init.gpa;
    const m = try M.create(gpa);
    defer m.destroy(gpa);
    try m.rom.loadFromSlice(image);
    m.cpu.reset(&m.bus);
    m.runFrame();
    check(!m.cpu.halted, "BIOS booted into the shell", 1, 0);

    // Take deterministic control for the injected calls (bm): park the
    // CPU on the stub with a fresh stack and quiet IRQs — the shell's
    // own behaviour belongs to bootcheck and the golden boot frame.
    m.bus.write8(0x80041, 0x00); // IRQMASK
    m.cpu.flags &= ~cpu_mod.flag_i;
    m.cpu.setReg(cpu_mod.Gab16.sp, 0x01100);
    m.cpu.pc = stub_addr;
    m.cpu.halted = true;

    // Plant the caller: HLT + a jump back to it — an IRQ wakes a parked
    // CPU and RTI resumes PAST the HLT, so the stub must loop exactly
    // like the BIOS shell_entry does (little-endian, like every
    // instruction fetch through cpu.read32).
    cpu_mod.write32(&m.bus, stub_addr, encode.hlt());
    cpu_mod.write32(&m.bus, stub_addr + 4, encode.jmpa(stub_addr));

    // ------------------------------------------------------------------
    // Register conventions (decision be): R5–R11, R13, SP survive the
    // deepest console path (PUTSTR → PUTCHAR → advance_row → scroll1 →
    // MEMCPY). Sentinels in, sentinels out.
    // ------------------------------------------------------------------
    var reg: u4 = 5;
    while (reg <= 11) : (reg += 1) m.cpu.setReg(reg, 0x1000 + @as(u32, reg));
    m.cpu.setReg(13, 0x100D);
    const sp_before = m.cpu.getReg(cpu_mod.Gab16.sp);

    // ------------------------------------------------------------------
    // SYS_PUTCHAR (task 12.5): glyph + attribute at the home cursor (the
    // banner is on screen, so clear first), column advances.
    // ------------------------------------------------------------------
    _ = syscall(m, sys_clrscr, 0, 0, 0);
    _ = syscall(m, sys_putchar, 'A', 0, 0);
    checkEq(cellChar(m, 0, 0), 'A', "PUTCHAR glyph at (0,0)");
    checkEq(cellAttr(m, 0, 0), 0x01, "PUTCHAR boot attribute (white on black)");
    checkEq(ramWord(m, cur_col), 1, "PUTCHAR advances the column");
    checkEq(ramWord(m, cur_row), 0, "PUTCHAR stays on the row");

    // CR homes the column; BS is non-destructive and stops at column 0.
    _ = syscall(m, sys_putchar, 0x0D, 0, 0);
    checkEq(ramWord(m, cur_col), 0, "CR homes the column");
    _ = syscall(m, sys_putchar, 0x08, 0, 0);
    checkEq(ramWord(m, cur_col), 0, "BS stops at column 0");
    _ = syscall(m, sys_putchar, 'B', 0, 0);
    _ = syscall(m, sys_putchar, 0x08, 0, 0);
    checkEq(ramWord(m, cur_col), 0, "BS steps the column back");
    checkEq(cellChar(m, 0, 0), 'B', "BS is non-destructive");

    // ------------------------------------------------------------------
    // SYS_SETCOLOR + SYS_SETCURSOR: attribute packing, position, clamping.
    // ------------------------------------------------------------------
    _ = syscall(m, sys_setcolor, 0x2, 0x7, 0);
    checkEq(ramWord(m, cur_attr), 0x72, "SETCOLOR packs bg<<4 | fg");
    _ = syscall(m, sys_setcolor, 0x12, 0x17, 0); // out-of-range indices mask
    checkEq(ramWord(m, cur_attr), 0x72, "SETCOLOR masks both indices to 4 bits");

    _ = syscall(m, sys_setcursor, 5, 10, 0);
    checkEq(ramWord(m, cur_col), 5, "SETCURSOR column");
    checkEq(ramWord(m, cur_row), 10, "SETCURSOR row");
    _ = syscall(m, sys_putchar, 'C', 0, 0);
    checkEq(cellChar(m, 10, 5), 'C', "PUTCHAR lands at the set cursor");
    checkEq(cellAttr(m, 10, 5), 0x72, "PUTCHAR writes the set attribute");

    _ = syscall(m, sys_setcursor, 200, 999, 0);
    checkEq(ramWord(m, cur_col), cols - 1, "SETCURSOR clamps the column");
    checkEq(ramWord(m, cur_row), rows - 1, "SETCURSOR clamps the row");

    // ------------------------------------------------------------------
    // SYS_PUTSTR (with the LF from decision bl) from a mid-screen cursor.
    // ------------------------------------------------------------------
    for ("HI\n", 0..) |ch, i| m.bus.write8(str_addr + @as(u32, @intCast(i)), ch);
    m.bus.write8(str_addr + 3, 0);
    _ = syscall(m, sys_setcursor, 0, 3, 0);
    _ = syscall(m, sys_putstr, str_addr, 0, 0);
    checkEq(cellChar(m, 3, 0), 'H', "PUTSTR first glyph");
    checkEq(cellChar(m, 3, 1), 'I', "PUTSTR second glyph");
    checkEq(ramWord(m, cur_col), 0, "PUTSTR LF homes the column");
    checkEq(ramWord(m, cur_row), 4, "PUTSTR LF advances the row");

    // Column-80 wrap behaves like LF.
    _ = syscall(m, sys_setcursor, cols - 1, 5, 0);
    _ = syscall(m, sys_putchar, 'X', 0, 0);
    checkEq(cellChar(m, 5, cols - 1), 'X', "wrap: glyph in the last column");
    checkEq(ramWord(m, cur_col), 0, "wrap homes the column");
    checkEq(ramWord(m, cur_row), 6, "wrap advances the row");

    // ------------------------------------------------------------------
    // Row-42 scroll: a LF on the bottom row shifts the screen up one line
    // and holds the cursor. 'H' written at (3,0) above must land on (2,0).
    // ------------------------------------------------------------------
    _ = syscall(m, sys_setcursor, 0, rows - 1, 0);
    _ = syscall(m, sys_putchar, 0x0A, 0, 0);
    checkEq(ramWord(m, cur_row), rows - 1, "scroll holds the cursor on row 42");
    checkEq(ramWord(m, cur_col), 0, "scroll LF homes the column");
    checkEq(cellChar(m, 2, 0), 'H', "scroll shifts rows up by one");
    checkEq(cellChar(m, rows - 1, 0), 0x20, "scroll clears the freed row to spaces");
    checkEq(cellAttr(m, rows - 1, 0), 0x72, "freed row carries the current attribute");

    // SYS_SCROLL by 2: 'H' (now on row 2) lands on row 0.
    _ = syscall(m, sys_scroll, 2, 0, 0);
    checkEq(cellChar(m, 0, 0), 'H', "SCROLL 2 shifts rows up by two");

    // ------------------------------------------------------------------
    // SYS_CLRSCR: every cell ' ' + attribute, cursor home. Then SCROLL
    // with the clamp path (R1 ≥ 43) leaves the screen identical.
    // ------------------------------------------------------------------
    _ = syscall(m, sys_clrscr, 0, 0, 0);
    checkEq(ramWord(m, cur_col), 0, "CLRSCR homes the column");
    checkEq(ramWord(m, cur_row), 0, "CLRSCR homes the row");
    var dirty: u32 = 0;
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            if (cellChar(m, r, c) != 0x20 or cellAttr(m, r, c) != 0x72) dirty += 1;
        }
    }
    checkEq(dirty, 0, "CLRSCR fills every cell with ' ' + attribute (cells off)");

    _ = syscall(m, sys_scroll, 0xFFFF, 0, 0); // clamp: 43 full scrolls
    dirty = 0;
    r = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            if (cellChar(m, r, c) != 0x20 or cellAttr(m, r, c) != 0x72) dirty += 1;
        }
    }
    checkEq(dirty, 0, "SCROLL $FFFF clamps and leaves a clear screen (cells off)");

    // ------------------------------------------------------------------
    // Keyboard (task 12.7, decision bn). Events are enqueued host-side
    // BEFORE each call, so the busy-polling blockers return immediately.
    // ------------------------------------------------------------------
    _ = syscall(m, sys_clrscr, 0, 0, 0); // known console state for echo checks

    // GETKEY: a release is consumed and discarded; the press comes back
    // as its event word (== HID code).
    m.io.keyEvent(0x8004); // 'a' release
    m.io.keyEvent(0x0004); // 'a' press
    checkEq(syscall(m, sys_getkey, 0, 0, 0), 0x0004, "GETKEY discards releases, returns the press");

    // POLLKEY: empty queue → 0; then raw words, presses and releases alike.
    checkEq(syscall(m, sys_pollkey, 0, 0, 0), 0, "POLLKEY empty queue returns 0");
    m.io.keyEvent(0x0005); // 'b' press
    m.io.keyEvent(0x8005); // 'b' release
    checkEq(syscall(m, sys_pollkey, 0, 0, 0), 0x0005, "POLLKEY returns the press word");
    checkEq(syscall(m, sys_pollkey, 0, 0, 0), 0x8005, "POLLKEY returns the release word too");

    // GETCHAR: HID→ASCII through the ROM table; shift via KMOD; unmapped
    // presses (F1 = $3A) are swallowed.
    m.io.keyEvent(0x0004);
    checkEq(syscall(m, sys_getchar, 0, 0, 0), 'a', "GETCHAR maps HID $04 to 'a'");
    m.io.keyboard.kmod = 0x0001; // shift held
    m.io.keyEvent(0x0004);
    checkEq(syscall(m, sys_getchar, 0, 0, 0), 'A', "GETCHAR applies shift via KMOD");
    m.io.keyEvent(0x001E);
    checkEq(syscall(m, sys_getchar, 0, 0, 0), '!', "GETCHAR shifted digit row");
    m.io.keyboard.kmod = 0x0000;
    m.io.keyEvent(0x003A); // F1 — unmapped
    m.io.keyEvent(0x0028); // Enter
    checkEq(syscall(m, sys_getchar, 0, 0, 0), 0x0D, "GETCHAR swallows unmapped, Enter maps to CR");

    // GETLINE into LINEBUF-adjacent scratch: type "hx", erase the 'x',
    // type "i", Enter. Buffer "hi", length 2, echo edited on screen.
    const line_buf: u32 = 0x05200;
    m.io.keyEvent(0x000B); // h
    m.io.keyEvent(0x001B); // x
    m.io.keyEvent(0x002A); // Backspace
    m.io.keyEvent(0x000C); // i
    m.io.keyEvent(0x0028); // Enter
    checkEq(syscall(m, sys_getline, line_buf, 80, 0), 2, "GETLINE returns the length");
    checkEq(m.ram.readByte(line_buf), 'h', "GETLINE buffer[0]");
    checkEq(m.ram.readByte(line_buf + 1), 'i', "GETLINE buffer[1]");
    checkEq(m.ram.readByte(line_buf + 2), 0, "GETLINE NUL-terminates");
    checkEq(cellChar(m, 0, 0), 'h', "GETLINE echo survives the edit");
    checkEq(cellChar(m, 0, 1), 'i', "GETLINE echoed the replacement");
    checkEq(cellChar(m, 0, 2), 0x20, "GETLINE erased the 'x' on screen");
    checkEq(ramWord(m, cur_row), 1, "GETLINE Enter echoed a newline");

    // Max length: R2 = 2 swallows the third character.
    m.io.keyEvent(0x0004); // a
    m.io.keyEvent(0x0005); // b
    m.io.keyEvent(0x0006); // c — beyond max, swallowed
    m.io.keyEvent(0x0028); // Enter
    checkEq(syscall(m, sys_getline, line_buf, 2, 0), 2, "GETLINE clamps at max length");
    checkEq(m.ram.readByte(line_buf), 'a', "GETLINE clamped buffer[0]");
    checkEq(m.ram.readByte(line_buf + 1), 'b', "GETLINE clamped buffer[1]");
    checkEq(m.ram.readByte(line_buf + 2), 0, "GETLINE clamped NUL");

    // ------------------------------------------------------------------
    // SYS_MEMCMP (task 12.8): 0 / 1 / $FFFF per amendment G18, unsigned.
    // ------------------------------------------------------------------
    const cmp_a: u32 = 0x05300;
    const cmp_b: u32 = 0x05310;
    for ([_]u8{ 1, 2, 3, 4 }, 0..) |v, i| {
        m.bus.write8(cmp_a + @as(u32, @intCast(i)), v);
        m.bus.write8(cmp_b + @as(u32, @intCast(i)), v);
    }
    checkEq(syscall(m, sys_memcmp, cmp_a, cmp_b, 4), 0, "MEMCMP equal");
    checkEq(syscall(m, sys_memcmp, cmp_a, cmp_b, 0), 0, "MEMCMP zero length is equal");
    m.bus.write8(cmp_b + 2, 0xFF); // a[2]=3 < b[2]=$FF unsigned
    checkEq(syscall(m, sys_memcmp, cmp_a, cmp_b, 4), 0xFFFF, "MEMCMP first-diff less (unsigned)");
    checkEq(syscall(m, sys_memcmp, cmp_b, cmp_a, 4), 1, "MEMCMP first-diff greater");

    // ------------------------------------------------------------------
    // Video & palette (task 12.9, decision bo).
    // ------------------------------------------------------------------
    // SETPAL: red rides in R3 (20-bit registers cannot carry RGB24).
    _ = syscall(m, sys_setpal, 5, (0xBB << 8) | 0xCC, 0xAA);
    checkEq(m.ram.readByte(palram_base + 15), 0xAA, "SETPAL red byte");
    checkEq(m.ram.readByte(palram_base + 16), 0xBB, "SETPAL green byte");
    checkEq(m.ram.readByte(palram_base + 17), 0xCC, "SETPAL blue byte");

    // LOADPAL: a full 768-byte replacement from RAM.
    const pal_src: u32 = 0x05400;
    var pi: u32 = 0;
    while (pi < 768) : (pi += 1) m.bus.write8(pal_src + pi, @truncate(pi *% 7));
    _ = syscall(m, sys_loadpal, pal_src, 0, 0);
    var pal_off: u32 = 0;
    pi = 0;
    while (pi < 768) : (pi += 1) {
        if (m.ram.readByte(palram_base + pi) != @as(u8, @truncate(pi *% 7))) pal_off += 1;
    }
    checkEq(pal_off, 0, "LOADPAL replaces all 768 bytes (bytes off)");

    // SYS_VBLANK: returns exactly at the rising edge of VSTAT bit 0.
    _ = syscall(m, sys_vblank, 0, 0, 0);
    checkEq(m.io.peek16(0x80217) & 1, 1, "VBLANK returns inside the blank");

    // SETMODE: geometry + depth + mode, mirrored into VMODE_CUR.
    _ = syscall(m, sys_setmode, 0, 0, 3); // bitmap, 320×180, 8bpp
    checkEq(m.io.peek16(0x80200), 0, "SETMODE VMODE bitmap");
    checkEq(m.io.peek16(0x80202), 0, "SETMODE VRESX 320");
    checkEq(m.io.peek16(0x80203), 0, "SETMODE VRESY 180");
    checkEq(m.io.peek16(0x80201), 3, "SETMODE VPALETTE 8bpp");
    checkEq(ramWord(m, vmode_cur), 0, "SETMODE mirrors VMODE_CUR");

    // FILLSCR at 8bpp: 320×180 = 57600 bytes of the index at VBUF×16,
    // and not one byte more.
    m.bus.write8(0x80206, 0x00); // VBUFLO
    m.bus.write8(0x80207, 0x10); // VBUFHI → VBUF $1000 → base $10000
    const fb: u32 = 0x10000;
    m.bus.write8(fb + 57600, 0x77); // the fence beyond the buffer
    checkEq(syscall(m, sys_fillscr, 0xAB, 0, 0), 0, "FILLSCR returns success");
    var fb_off: u32 = 0;
    var fi: u32 = 0;
    while (fi < 57600) : (fi += 1) {
        if (m.ram.readByte(fb + fi) != 0xAB) fb_off += 1;
    }
    checkEq(fb_off, 0, "FILLSCR fills 320×180 @ 8bpp (bytes off)");
    checkEq(m.ram.readByte(fb + 57600), 0x77, "FILLSCR stops at the buffer end");

    // FILLSCR at 4bpp replicates the nibble and halves the byte count.
    _ = syscall(m, sys_setmode, 0, 0, 1);
    m.bus.write8(fb + 28800, 0x66); // new fence at the 4bpp boundary
    _ = syscall(m, sys_fillscr, 0x5, 0, 0);
    checkEq(m.ram.readByte(fb), 0x55, "FILLSCR 4bpp nibble-replicated byte");
    checkEq(m.ram.readByte(fb + 28799), 0x55, "FILLSCR 4bpp last byte");
    checkEq(m.ram.readByte(fb + 28800), 0x66, "FILLSCR 4bpp fence holds");

    // Text mode has no framebuffer: refuse with $FFFF, write nothing.
    _ = syscall(m, sys_setmode, 3, 1, 1);
    m.bus.write8(fb, 0x11);
    checkEq(syscall(m, sys_fillscr, 0xAB, 0, 0), 0xFFFF, "FILLSCR refuses text mode");
    checkEq(m.ram.readByte(fb), 0x11, "FILLSCR text mode writes nothing");

    // ------------------------------------------------------------------
    // Sound (task 12.10, decision bp).
    // ------------------------------------------------------------------
    const aur: u32 = 0x80100;
    _ = syscall(m, sys_sndplay, 1, 0x1234, 2);
    checkEq(m.io.peek16(aur + 0x10), 0x34, "SNDPLAY VFREQLO");
    checkEq(m.io.peek16(aur + 0x11), 0x12, "SNDPLAY VFREQHI");
    checkEq(m.io.peek16(aur + 0x12), 2, "SNDPLAY VWAVE");
    checkEq(m.io.peek16(aur + 0x13), 0x80, "SNDPLAY gate on");
    checkEq(m.io.peek16(aur + 0x17), 0xFF, "SNDPLAY full pre-mixer volume");
    checkEq(m.io.peek16(aur + 0x1E), 0x0F, "SNDPLAY pan left");
    checkEq(m.io.peek16(aur + 0x1D), 0x0F, "SNDPLAY pan right");
    checkEq(m.io.peek16(aur + 0x15), 0xF4, "SNDPLAY default sustain/release");
    checkEq(m.io.peek16(aur + 0x43) & 0x02, 0x02, "SNDPLAY routes the voice");

    _ = syscall(m, sys_sndvol, 0x80, 0, 0);
    checkEq(m.io.peek16(aur + 0x40), 0x80, "SNDVOL master volume");
    checkEq(m.io.peek16(aur + 0x41), 0x0F, "AMVOLL parked at $0F (bp)");

    _ = syscall(m, sys_sndstop, 1, 0, 0);
    checkEq(m.io.peek16(aur + 0x13), 0, "SNDSTOP releases the gate");
    checkEq(m.io.peek16(aur + 0x43) & 0x02, 0x02, "SNDSTOP keeps the routing");

    _ = syscall(m, sys_sndinit, 0, 0, 0);
    checkEq(m.io.peek16(aur + 0x40), 0, "SNDINIT master volume 0");
    checkEq(m.io.peek16(aur + 0x43), 0, "SNDINIT no voices routed");
    checkEq(m.io.peek16(aur + 0x41), 0x0F, "SNDINIT parks AMVOLL");

    // ------------------------------------------------------------------
    // Timers & system (task 12.11, decisions bq/br).
    // ------------------------------------------------------------------
    // TWAIT on a disabled timer: immediate $FFFF.
    checkEq(syscall(m, sys_twait, 1, 0, 0), 0xFFFF, "TWAIT disabled timer refuses");

    // TSET one-shot on B, then TWAIT twice: the first waits out the 50
    // ticks and consumes the expiry; the second finds the one-shot
    // disarmed (v1.1 §3.2) and refuses.
    _ = syscall(m, sys_tset, 1, 50, 0b101); // enable + IRQ-en, one-shot
    checkEq(m.io.peek16(0x80018), 50, "TSET reload low byte");
    checkEq(m.io.peek16(0x8001C), 0b101, "TSET control written");
    checkEq(syscall(m, sys_twait, 1, 0, 0), 0, "TWAIT rides out the one-shot");
    checkEq(m.io.peek16(0x8001E) & 1, 0, "TWAIT consumed the expiry");
    checkEq(syscall(m, sys_twait, 1, 0, 0), 0xFFFF, "TWAIT sees the self-disarm");

    // GETID: SYSID in R1, the ROM header version word in R2 (bq).
    checkEq(syscall(m, sys_getid, 0, 0, 0), m.io.peek16(0x80001), "GETID machine id");
    checkEq(m.cpu.getReg(2), std.mem.readInt(u16, image[2..4], .little), "GETID ROM header version");

    // RAND/SEED: boot seeded $0001 (checked by bootcheck); a seeded step
    // matches the host-computed Galois LFSR, and SEED coerces 0 → 1.
    _ = syscall(m, sys_seed, 0x0ABC, 0, 0);
    var expect: u32 = 0x0ABC;
    var ri: u32 = 0;
    while (ri < 3) : (ri += 1) {
        expect = (expect >> 1) ^ (if (expect & 1 != 0) @as(u32, 0xB400) else 0);
        checkEq(syscall(m, sys_rand, 0, 0, 0), expect, "RAND matches the $B400 LFSR");
    }
    _ = syscall(m, sys_seed, 0, 0, 0);
    checkEq(ramWord(m, 0x01106), 1, "SEED coerces 0 to $0001");

    // ------------------------------------------------------------------
    // The IRQ dispatcher, end to end (br): a host-assembled handler in
    // RAM counts timer-A expiries. IRQSET installs it; the host unmasks
    // bit 0 and sets FLAGS.I; a repeating 200-cycle timer then wakes the
    // HLT-parked CPU through vector → dispatcher → CALL → RET → RTI.
    // ------------------------------------------------------------------
    const handler: u32 = 0x05800;
    const counter: u32 = 0x05900;
    cpu_mod.write32(&m.bus, handler + 0, encode.lw(1, 0, @intCast(counter)));
    cpu_mod.write32(&m.bus, handler + 4, encode.addi(1, 1, 1));
    cpu_mod.write32(&m.bus, handler + 8, encode.sw(0, @intCast(counter), 1));
    cpu_mod.write32(&m.bus, handler + 12, encode.ret());
    _ = syscall(m, sys_irqset, 0, handler, 0);
    checkEq(ramWord(m, 0x01110), handler & 0xFFFF, "IRQSET writes the DISPATCH slot");

    m.bus.write8(0x80041, 0x01); // IRQMASK: timer A only
    m.cpu.flags |= cpu_mod.flag_i; // interrupts on for the parked CPU
    _ = syscall(m, sys_tset, 0, 200, 0b111); // repeat + IRQ + enable
    runFrames(m, 1); // 240,000 cycles ≈ 1,200 expiries
    settle(m); // never abandon an in-flight dispatcher frame
    const fired = ramWord(m, counter);
    check(fired >= 100, "dispatcher delivered repeating IRQs", fired, 100);

    // Uninstall: the ack-only path keeps the machine alive, the counter
    // stops.
    _ = syscall(m, sys_irqset, 0, 0, 0);
    const frozen = ramWord(m, counter);
    runFrames(m, 1);
    settle(m);
    checkEq(ramWord(m, counter), frozen, "uninstalled handler stays silent");
    _ = syscall(m, sys_tset, 0, 0, 0); // timer off — no new expiries
    runFrames(m, 1); // drain: any latched pending gets dispatched + acked
    settle(m);
    checkEq(m.io.peek16(0x80040) & 1, 0, "dispatcher acked the source");
    m.bus.write8(0x80041, 0x00);
    m.cpu.flags &= ~cpu_mod.flag_i;

    // ------------------------------------------------------------------
    // Conventions: preserved registers and SP round-trip; a reserved slot
    // still answers $FFFF (decision bj held after the table gained real
    // entries).
    // ------------------------------------------------------------------
    reg = 5;
    while (reg <= 11) : (reg += 1)
        checkEq(m.cpu.getReg(reg), 0x1000 + @as(u32, reg), "R5-R11 preserved");
    checkEq(m.cpu.getReg(13), 0x100D, "R13 (FP) preserved");
    checkEq(m.cpu.getReg(cpu_mod.Gab16.sp), sp_before, "SP balanced");
    checkEq(syscall(m, sys_reserved_29, 0, 0, 0), 0xFFFF, "reserved slot answers $FFFF");

    // ------------------------------------------------------------------
    // FINALE (tasks 12.15–12.16) — these re-boot the machine, so they
    // run last.
    //
    // 1. Autoboot + SYS_RESET, end to end: a hand-built FB image at
    //    $04100 (a program that raises a RAM flag and RETs), then the
    //    RESET jump-table entry. The re-boot must find the header, CALL
    //    the program, and drop to READY when it returns (decision bs).
    // ------------------------------------------------------------------
    const boot_img: u32 = 0x04100;
    const flag: u32 = 0x05A00;
    m.bus.write8(boot_img + 0, 'F'); // §6.9 magic
    m.bus.write8(boot_img + 1, 'B');
    m.bus.write8(boot_img + 2, 1); // version 1
    m.bus.write8(boot_img + 3, 0);
    m.bus.write8(boot_img + 4, 12); // entry offset — first payload byte
    m.bus.write8(boot_img + 5, 0);
    m.bus.write8(boot_img + 6, 64); // needs 64KB
    m.bus.write8(boot_img + 7, 0);
    m.bus.write8(boot_img + 8, 0x00); // load address $04100, 32-bit LE
    m.bus.write8(boot_img + 9, 0x41);
    m.bus.write8(boot_img + 10, 0x00);
    m.bus.write8(boot_img + 11, 0x00);
    cpu_mod.write32(&m.bus, boot_img + 12, encode.li(1, 1));
    cpu_mod.write32(&m.bus, boot_img + 16, encode.sw(0, @intCast(flag), 1));
    cpu_mod.write32(&m.bus, boot_img + 20, encode.ret());
    m.cpu.pc = jump_table + 4 * 25; // SYS_RESET, exactly as a caller would
    m.cpu.halted = false;
    runFrames(m, 2);
    checkEq(ramWord(m, flag), 1, "autoboot ran the FB program");
    checkEq(cellChar(m, 3, 0), 'R', "READY. after the program returned");
    check(!m.cpu.halted, "shell live after autoboot", 1, 0);

    // ------------------------------------------------------------------
    // 2. A present-but-invalid header (entry offset inside the header)
    //    earns the diagnostic and still reaches the shell (§6.9 / bs).
    // ------------------------------------------------------------------
    m.bus.write8(boot_img + 4, 4); // entry 4 < 12 — invalid
    m.cpu.pc = jump_table + 4 * 25;
    m.cpu.halted = false;
    runFrames(m, 2);
    checkEq(cellChar(m, 3, 0), '?', "?BAD BOOT HEADER diagnostic printed");
    checkEq(cellChar(m, 4, 0), 'R', "READY. after the diagnostic");

    // ------------------------------------------------------------------
    // 3. The published §8.3 hello (tests/asm/hello.asm, flas+fll built,
    //    argv[2]), run EXACTLY as a person would: boot to READY, type
    //    RUN 4100 on the keyboard, watch SYS_PUTSTR print, and let its
    //    SYS_GETKEY + HLT finish. The full Milestone-5 round trip.
    // ------------------------------------------------------------------
    var hi: u32 = 0;
    while (hi < hello_raw.len) : (hi += 1) {
        m.bus.write8(boot_img + hi, hello_raw[hi]); // first byte ≠ 'F': no autoboot
    }
    m.cpu.pc = jump_table + 4 * 25;
    m.cpu.halted = false;
    runFrames(m, 2); // a clean READY, hello parked at $04100
    for ([_]u16{ 0x15, 0x18, 0x11, 0x2C, 0x21, 0x1E, 0x27, 0x27, 0x28, 0x04 }) |code| {
        m.io.keyEvent(code); // r u n SPACE 4 1 0 0 ENTER — and the GETKEY press
    }
    runFrames(m, 2);
    check(m.cpu.halted, "hello HLTed as published", 0, 1);
    const hello_msg = "HELLO, FLOMMODORE!";
    var mi: u32 = 0;
    var msg_off: u32 = 0;
    while (mi < hello_msg.len) : (mi += 1) {
        if (cellChar(m, 5, @intCast(mi)) != hello_msg[mi]) msg_off += 1;
    }
    checkEq(msg_off, 0, "SYS_PUTSTR printed HELLO, FLOMMODORE! (cells off)");
    checkEq(cellChar(m, 4, 0), 'r', "the typed RUN line echoed");

    if (failures != 0) {
        std.debug.print("syscheck: {d} check(s) FAILED\n", .{failures});
        return error.SysCheckFailed;
    }
    std.debug.print(
        "syscheck: {s} all 29 syscalls + shell + autoboot hold — Block 12 verified through the ${X:0>5} ABI\n",
        .{ args[1], jump_table },
    );
}
