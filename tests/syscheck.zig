//! syscheck — Block 12 syscall ABI verifier (tasks 12.5–12.6: the console).
//!
//! Usage: syscheck <flommodore.rom>
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
//! CALLA/RET contract from the caller's side without needing a guest test
//! program, keyboard input, or the (task 12.15) autoboot path — none of
//! which exist yet. Cursor state and the matrix are then read straight
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
const sys_reserved_29: u32 = 29; // first reserved slot (decision bj)

// --- Decision bi/bd BIOS RAM -------------------------------------------------
const cur_col: u32 = 0x01100;
const cur_row: u32 = 0x01102;
const cur_attr: u32 = 0x01104;
const textmat: u32 = 0x02600;
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
/// Returns R1 (the result register, decision be).
fn syscall(m: *M, id: u32, r1: u32, r2: u32, r3: u32) u32 {
    m.cpu.setReg(1, r1);
    m.cpu.setReg(2, r2);
    m.cpu.setReg(3, r3);
    m.cpu.setReg(cpu_mod.Gab16.lr, stub_addr);
    m.cpu.pc = jump_table + 4 * id;
    m.cpu.halted = false;
    var budget: u32 = 2_000_000; // SYS_SCROLL 43 needs ~1.5M cycles
    while (!m.cpu.halted and budget > 0) : (budget -= 1) _ = m.cycle();
    check(m.cpu.halted, "syscall returned to the HLT stub", 0, 1);
    return m.cpu.getReg(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: syscheck <flommodore.rom>\n", .{});
        return error.BadUsage;
    }
    const image = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 20));

    // Boot exactly like bootcheck: one frame parks the CPU in shell_entry.
    const gpa = init.gpa;
    const m = try M.create(gpa);
    defer m.destroy(gpa);
    try m.rom.loadFromSlice(image);
    m.cpu.reset(&m.bus);
    m.runFrame();
    check(m.cpu.halted, "BIOS booted to the shell HLT", 0, 1);

    // Plant the caller: one HLT word in free RAM (little-endian, like every
    // instruction fetch through cpu.read32).
    cpu_mod.write32(&m.bus, stub_addr, encode.hlt());

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
    // SYS_PUTCHAR (task 12.5): glyph + attribute at the boot cursor (0,0),
    // column advances.
    // ------------------------------------------------------------------
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

    if (failures != 0) {
        std.debug.print("syscheck: {d} check(s) FAILED\n", .{failures});
        return error.SysCheckFailed;
    }
    std.debug.print(
        "syscheck: {s} console syscalls hold — decisions be/bj/bl verified through the ${X:0>5} ABI\n",
        .{ args[1], jump_table },
    );
}
