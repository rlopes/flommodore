//! Flommodore — `tests/genroms.zig` (Block 2, task 2.7).
//!
//! Test-ROM builders: emit `tests/roms/*.rom` — full 16KB ROM images with
//! 4-byte system vectors at `$FFFC0` (amendment D3/§2.1) — using
//! `src/encode.zig` as the single source of encoding truth (audit P1).
//!
//! Invoked as `zig build genroms`; build.zig passes the output directory as
//! argv[1] so the emitted files land in `tests/roms/` regardless of cwd.
//! The Block 3 CPU test suite adds one builder per instruction group here.

const std = @import("std");
const encode = @import("encode");
const rom = @import("rom");
const util = @import("util");

/// A 16KB ROM image under construction, addressed in machine addresses
/// (`$FC000–$FFFFF`) so builders read like memory maps, not file offsets.
pub const RomImage = struct {
    bytes: [rom.size]u8 = @splat(0),

    pub fn init() RomImage {
        return .{};
    }

    fn offsetOf(addr: u32) u32 {
        std.debug.assert(addr >= 0xFC000 and addr <= 0xFFFFF);
        return addr - 0xFC000;
    }

    /// Write one 32-bit little-endian word (instruction or DD-style data)
    /// at a machine address inside the ROM.
    pub fn writeWord32(image: *RomImage, addr: u32, word: u32) void {
        const off = offsetOf(addr);
        std.debug.assert(off + 4 <= rom.size);
        std.mem.writeInt(u32, image.bytes[off..][0..4], word, .little);
    }

    /// A code cursor: emit consecutive instructions from a start address.
    pub const Cursor = struct {
        image: *RomImage,
        addr: u32,

        pub fn emit(cur: *Cursor, word: u32) void {
            cur.image.writeWord32(cur.addr, word);
            cur.addr += 4;
        }
    };

    pub fn codeAt(image: *RomImage, addr: u32) Cursor {
        return .{ .image = image, .addr = addr };
    }

    /// Set system vector `index` (0=RESET, 1=NMI, 2=IRQ, 3=BRK, 4–15
    /// reserved) at `$FFFC0 + 4×index` — a 32-bit LE value masked to 20 bits
    /// when loaded (amendment §1.5/§2.1).
    pub fn setVector(image: *RomImage, index: u4, target: u32) void {
        std.debug.assert(target <= util.addr_mask);
        image.writeWord32(0xFFFC0 + 4 * @as(u32, index), target);
    }
};

/// nop_loop.rom — the plan 2.7 acceptance ROM. RESET vectors to $FC200
/// (the BIOS-kernel-area address, §2.1); the code is four NOPs followed by
/// a JMPA back to the start: an infinite, side-effect-free loop the harness
/// can run under `--max-cycles`.
fn buildNopLoop() RomImage {
    var image = RomImage.init();
    const entry: u32 = 0xFC200;
    image.setVector(0, entry); // RESET
    var code = image.codeAt(entry);
    code.emit(encode.nop());
    code.emit(encode.nop());
    code.emit(encode.nop());
    code.emit(encode.nop());
    code.emit(encode.jmpa(entry));
    return image;
}

// ---------------------------------------------------------------------------
// Block 3 CPU test ROMs (plan tasks 3.5-3.15).
//
// Harness protocol: a test ROM writes $600D to RAM $00080 on success (or
// $0BAD, plus the failing check number at $00084) and HLTs. R11 carries the
// current check number throughout. The harness's --expect-pass flag enforces
// the protocol.
// ---------------------------------------------------------------------------

const result_addr: i32 = 0x00080;
const failnum_addr: i32 = 0x00084;
const entry_addr: u32 = 0xFC200;
const user_code_addr: u32 = 0xFC500; // irq ROM: user-mode code
const irq_handler_addr: u32 = 0xFC600;
const brk_handler_addr: u32 = 0xFC680;
const fail_addr: u32 = 0xFC800;

/// Small assembly kit over the cursor. Register conventions inside test
/// ROMs: R11 = current check number, R12 = scratch.
const Kit = struct {
    cur: RomImage.Cursor,

    fn begin(image: *RomImage) Kit {
        image.setVector(0, entry_addr); // RESET
        // The shared FAIL stub: record R11, mark $0BAD, halt.
        var f = image.codeAt(fail_addr);
        f.emit(encode.sw(0, failnum_addr, 11));
        f.emit(encode.li(11, 0x0BAD));
        f.emit(encode.sw(0, result_addr, 11));
        f.emit(encode.hlt());
        return .{ .cur = image.codeAt(entry_addr) };
    }

    fn emit(kit: *Kit, word: u32) void {
        kit.cur.emit(word);
    }

    /// Branch (any J-format conditional) to an absolute target: the offset
    /// is computed from the next instruction (§1.3).
    fn branchTo(kit: *Kit, op: encode.Opcode, target: u32) void {
        const offset: i64 = @as(i64, target) - (@as(i64, kit.cur.addr) + 4);
        kit.emit(encode.formatJ(op, @as(u32, @bitCast(@as(i32, @intCast(offset)))) & 0x3FF_FFFF));
    }

    /// The branch that follows MUST be taken, else fail: `op +4` skips the
    /// JMPA FAIL that this helper plants.
    fn assertTaken(kit: *Kit, op: encode.Opcode) void {
        kit.emit(encode.formatJ(op, 4));
        kit.emit(encode.jmpa(fail_addr));
    }

    /// The branch MUST NOT be taken: it targets FAIL directly.
    fn assertNotTaken(kit: *Kit, op: encode.Opcode) void {
        kit.branchTo(op, fail_addr);
    }

    /// Number the next check (lands in $00084 on failure).
    fn num(kit: *Kit, n: i32) void {
        kit.emit(encode.li(11, n));
    }

    /// Check register low-16 against an immediate.
    fn checkEqImm(kit: *Kit, n: i32, ra: u4, imm: i32) void {
        kit.num(n);
        kit.emit(encode.cmpi(ra, imm));
        kit.assertTaken(.beq);
    }

    /// LOAD_ADDR macro (amendment §1.2): LI low half, LUI high nibble.
    fn loadAddr(kit: *Kit, rd: u4, addr: u32) void {
        kit.emit(encode.li(rd, @intCast(addr & 0xFFFF)));
        kit.emit(encode.lui(rd, @intCast(addr >> 16)));
    }

    /// Success: write $600D and halt.
    fn pass(kit: *Kit) void {
        kit.emit(encode.li(11, 0x600D));
        kit.emit(encode.sw(0, result_addr, 11));
        kit.emit(encode.hlt());
    }
};

/// test_cpu_load_store.rom (task 3.5) - includes the LOAD_ADDR LI+LUI
/// sequence reaching $40000.
fn buildLoadStore() RomImage {
    var image = RomImage.init();
    var k = Kit.begin(&image);
    // 1: SW/LW round-trip in zero page.
    k.emit(encode.li(1, 0x1234));
    k.emit(encode.sw(0, 0x90, 1));
    k.emit(encode.lw(2, 0, 0x90));
    k.num(1);
    k.emit(encode.cmp(1, 2));
    k.assertTaken(.beq);
    // 2: SB stores the low byte; LB zero-extends.
    k.emit(encode.sb(0, 0x94, 1));
    k.checkEqImm(2, 1, 0x1234); // R1 intact
    k.emit(encode.lb(3, 0, 0x94));
    k.checkEqImm(3, 3, 0x34);
    // 3: LOAD_ADDR to VRAM $40000 and back.
    k.loadAddr(4, 0x40000);
    k.emit(encode.sw(4, 0, 1));
    k.emit(encode.lw(5, 4, 0));
    k.checkEqImm(4, 5, 0x1234);
    // 4: LI sign-extends to 20 bits: -1 -> $FFFFF (low16 $FFFF).
    k.emit(encode.li(6, -1));
    k.checkEqImm(5, 6, -1);
    // ...and the high nibble is $F: shift down 8+8 and compare.
    k.emit(encode.li(12, 8));
    k.emit(encode.shr(7, 6, 12));
    k.emit(encode.shr(7, 7, 12));
    k.checkEqImm(6, 7, 0xF);
    // 5: LUI preserves the low 16 bits.
    k.emit(encode.li(8, 0x2BCD));
    k.emit(encode.lui(8, 0x3));
    k.checkEqImm(7, 8, 0x2BCD);
    // 6: negative base+offset addressing.
    k.emit(encode.li(1, 0xA0));
    k.emit(encode.sw(1, -4, 1));
    k.emit(encode.lw(2, 1, -4));
    k.checkEqImm(8, 2, 0xA0);
    k.pass();
    return image;
}

/// test_cpu_alu.rom (tasks 3.6-3.8) - includes divide-by-zero and the SUB
/// borrow cases.
fn buildAlu() RomImage {
    var image = RomImage.init();
    var k = Kit.begin(&image);
    // 1: ADD.
    k.emit(encode.li(1, 2));
    k.emit(encode.li(2, 3));
    k.emit(encode.add(3, 1, 2));
    k.checkEqImm(1, 3, 5);
    // 2: ADD carry keeps bit 16 in the 20-bit register.
    k.emit(encode.li(1, 0xFFFF));
    k.emit(encode.add(3, 1, 1)); // $1FFFE, C=1
    k.num(2);
    k.assertTaken(.bcs);
    k.checkEqImm(3, 3, -2); // low16 $FFFE
    k.emit(encode.li(12, 8));
    k.emit(encode.shr(4, 3, 12));
    k.emit(encode.shr(4, 4, 12));
    k.checkEqImm(4, 4, 1); // bit 16 survived
    // 3: SUB borrow (1-2): C=0, result low16 $FFFF.
    k.emit(encode.li(1, 1));
    k.emit(encode.subi(3, 1, 2));
    k.num(5);
    k.assertNotTaken(.bcs);
    k.checkEqImm(6, 3, -1);
    // 4: logic + NOT.
    k.emit(encode.li(1, 0x0F0F));
    k.emit(encode.li(2, 0x00FF));
    k.emit(encode.@"and"(3, 1, 2));
    k.checkEqImm(7, 3, 0x000F);
    k.emit(encode.@"or"(3, 1, 2));
    k.checkEqImm(8, 3, 0x0FFF);
    k.emit(encode.xor(3, 1, 1));
    k.num(9);
    k.assertTaken(.beq); // Z set
    k.emit(encode.li(1, 0));
    k.emit(encode.not(3, 1));
    k.checkEqImm(10, 3, -1); // low16 $FFFF (full value $FFFFF)
    // 5: MUL low 16: $100 * $300 -> 0, Z=1.
    k.emit(encode.li(1, 0x100));
    k.emit(encode.li(2, 0x300));
    k.emit(encode.mul(3, 1, 2));
    k.num(11);
    k.assertTaken(.beq);
    // 6: DIV/MOD.
    k.emit(encode.li(1, 100));
    k.emit(encode.li(2, 7));
    k.emit(encode.div(3, 1, 2));
    k.checkEqImm(12, 3, 14);
    k.emit(encode.mod(3, 1, 2));
    k.checkEqImm(13, 3, 2);
    // 7: divide by zero -> $FFFF, V=1 (BLT after: N=1,V=1 -> N=V -> BGE taken).
    k.emit(encode.div(3, 1, 0));
    k.checkEqImm(14, 3, -1);
    // 8: shifts - SHL carry, ASR sign behaviour.
    k.emit(encode.li(1, 0x8000));
    k.emit(encode.li(2, 1));
    k.emit(encode.shl(3, 1, 2)); // $10000: C=1, low16 0 -> Z=1
    k.num(15);
    k.assertTaken(.bcs);
    k.num(16);
    k.assertTaken(.beq);
    k.emit(encode.li(1, -4)); // $FFFFC
    k.emit(encode.asr(3, 1, 2)); // 16-bit signed: $FFFC asr 1 = $FFFE
    k.checkEqImm(17, 3, -2);
    k.pass();
    return image;
}

/// test_cpu_branch.rom (task 3.9) - every condition taken and not taken,
/// plus a backward loop.
fn buildBranch() RomImage {
    var image = RomImage.init();
    var k = Kit.begin(&image);
    // Scenario: equal (5,5) -> Z=1,C=1,N=V=0.
    k.emit(encode.li(1, 5));
    k.emit(encode.li(2, 5));
    k.num(1);
    k.emit(encode.cmp(1, 2));
    for ([_]encode.Opcode{ .beq, .ble, .bge, .bcs }) |op| k.assertTaken(op);
    for ([_]encode.Opcode{ .bne, .blt, .bgt, .bcc }) |op| k.assertNotTaken(op);
    // Scenario: 1 vs 2 - signed and unsigned less.
    k.emit(encode.li(1, 1));
    k.emit(encode.li(2, 2));
    k.num(2);
    k.emit(encode.cmp(1, 2));
    for ([_]encode.Opcode{ .bne, .blt, .ble, .bcc }) |op| k.assertTaken(op);
    for ([_]encode.Opcode{ .beq, .bgt, .bge, .bcs }) |op| k.assertNotTaken(op);
    // Scenario: $7FFF vs $FFFF - signed greater (V=1 flips N=V), unsigned less.
    k.emit(encode.li(1, 0x7FFF));
    k.emit(encode.li(2, 0xFFFF));
    k.num(3);
    k.emit(encode.cmp(1, 2));
    for ([_]encode.Opcode{ .bne, .bgt, .bge, .bcc }) |op| k.assertTaken(op);
    for ([_]encode.Opcode{ .beq, .blt, .ble, .bcs }) |op| k.assertNotTaken(op);
    // Backward branch: loop 3 times, counting in R4.
    k.emit(encode.li(3, 3));
    k.emit(encode.li(4, 0));
    const loop_top = k.cur.addr;
    k.emit(encode.addi(4, 4, 1));
    k.emit(encode.subi(3, 3, 1));
    k.emit(encode.cmpi(3, 0));
    k.branchTo(.bne, loop_top);
    k.checkEqImm(4, 4, 3);
    k.pass();
    return image;
}

/// test_cpu_stack.rom (tasks 3.10-3.11) - includes pushing/popping a 20-bit
/// LR and a CALLA/RET chain.
fn buildStack() RomImage {
    var image = RomImage.init();
    // Subroutine at a fixed address: capture LR via the stack, bump R7, RET.
    var sub = image.codeAt(0xFC700);
    sub.emit(encode.push(14)); // PUSH LR
    sub.emit(encode.pop(9)); //  POP  -> R9 = 20-bit return address
    sub.emit(encode.addi(7, 7, 1));
    sub.emit(encode.ret());

    var k = Kit.begin(&image);
    k.emit(encode.li(15, 0x1100)); // SP = boot value (D12)
    // 1: 20-bit PUSH/POP round-trip.
    k.loadAddr(1, 0xFEDCB);
    k.emit(encode.push(1));
    k.emit(encode.pop(2));
    k.checkEqImm(1, 2, @as(i16, @bitCast(@as(u16, 0xEDCB)))); // low16
    k.emit(encode.li(12, 8));
    k.emit(encode.shr(3, 2, 12));
    k.emit(encode.shr(3, 3, 12));
    k.checkEqImm(2, 3, 0xF); // high nibble
    k.checkEqImm(3, 15, 0x1100); // SP balanced
    // 2: CALLA/RET with LR captured through the stack.
    const calla_at = k.cur.addr;
    k.emit(encode.calla(0xFC700));
    const return_addr = calla_at + 4;
    k.checkEqImm(4, 7, 1); // subroutine ran
    k.checkEqImm(5, 9, @as(i32, @intCast(return_addr & 0xFFFF))); // 20-bit LR low half...
    k.emit(encode.li(12, 8));
    k.emit(encode.shr(3, 9, 12));
    k.emit(encode.shr(3, 3, 12));
    k.checkEqImm(6, 3, @as(i32, @intCast(return_addr >> 16))); // ...and high nibble
    // 3: PUSHA/POPA - 13 slots, 52 bytes, everything restored.
    k.emit(encode.li(1, 0x111));
    k.emit(encode.li(12, 0xCCC));
    k.emit(encode.pusha());
    k.checkEqImm(7, 15, 0x1100 - 52);
    k.emit(encode.li(1, 0x0BAD));
    k.emit(encode.li(12, 0x0BAD));
    k.emit(encode.popa());
    k.checkEqImm(8, 1, 0x111);
    k.checkEqImm(9, 12, 0xCCC);
    k.checkEqImm(10, 15, 0x1100);
    k.pass();
    return image;
}

/// test_cpu_irq.rom (tasks 3.12-3.16 + amendment v1.2): BRK trap, IRQ with
/// nesting, the D46 supervisor->user RTI-frame transition, user-mode
/// privilege traps (MTSR and RTI, D42/D44), ignored user-mode CLI (D45),
/// and the user-mode stack switch. Run with:
///   --irq-at 30 --irq-at 60 --irq-at 200
/// (assert-until-delivered semantics make the exact cycles forgiving).
fn buildIrq() RomImage {
    var image = RomImage.init();
    image.setVector(2, irq_handler_addr); // IRQ
    image.setVector(3, brk_handler_addr); // BRK / illegal / privilege

    // IRQ handler: count in R2; re-enable I; the FIRST invocation then waits
    // for the nested second one before returning.
    var h = image.codeAt(irq_handler_addr);
    h.emit(encode.addi(2, 2, 1));
    h.emit(encode.sei());
    h.emit(encode.cmpi(2, 1));
    const skip_branch_at = h.addr;
    h.emit(0); // placeholder: BNE skip (patched below)
    const wait_top = h.addr;
    h.emit(encode.cmpi(2, 2));
    { // BNE wait_top
        const off: i64 = @as(i64, wait_top) - (@as(i64, h.addr) + 4);
        h.emit(encode.formatJ(.bne, @as(u32, @bitCast(@as(i32, @intCast(off)))) & 0x3FF_FFFF));
    }
    const skip_target = h.addr;
    h.emit(encode.rti());
    { // patch the forward BNE
        const off: i64 = @as(i64, skip_target) - (@as(i64, skip_branch_at) + 4);
        image.writeWord32(skip_branch_at, encode.formatJ(.bne, @as(u32, @bitCast(@as(i32, @intCast(off)))) & 0x3FF_FFFF));
    }

    // BRK handler: count in R10, resume after the trapping word.
    var bh = image.codeAt(brk_handler_addr);
    bh.emit(encode.addi(10, 10, 1));
    bh.emit(encode.rti());

    var k = Kit.begin(&image);
    // Supervisor setup: SP, SSP, USP, IVT -> ROM system vectors.
    k.emit(encode.li(15, 0x1100));
    k.emit(encode.li(1, 0x20F0));
    k.emit(encode.mtsr(.ssp, 1));
    k.emit(encode.li(1, 0x1100));
    k.emit(encode.mtsr(.usp, 1));
    k.loadAddr(1, 0xFFFC0);
    k.emit(encode.mtsr(.ivt, 1));
    // 1: BRK trap on a cleared-RAM word (D35); handler bumps R10 and resumes.
    k.num(1);
    k.emit(0x0000_0000);
    k.checkEqImm(1, 10, 1);
    // 2: two IRQ pulses; the second nests inside the first handler.
    k.emit(encode.sei());
    const wait2_top = k.cur.addr;
    k.emit(encode.cmpi(2, 2));
    k.branchTo(.bne, wait2_top);
    k.checkEqImm(2, 2, 2);
    // 3: drop to user mode via an RTI frame (S=0, I=1); pulse 3 is pending
    // by then and delivers at the first user instruction.
    k.emit(encode.cli());
    k.emit(encode.li(15, 0x20F0)); // build the frame on the supervisor stack
    k.loadAddr(3, user_code_addr);
    k.emit(encode.push(3)); //         resume PC
    k.emit(encode.li(4, 0x10)); //     FLAGS: S=0, I=1
    k.emit(encode.push(4));
    k.emit(encode.rti()); //           -> user mode; SP <- USP ($01100)

    // User-mode code.
    var u = Kit{ .cur = image.codeAt(user_code_addr) };
    const wait3_top = u.cur.addr;
    u.emit(encode.cmpi(2, 3)); //      pulse 3 arrives here (user-mode entry)
    u.branchTo(.bne, wait3_top);
    // 4: we are in user mode: FLAGS.S = 0.
    u.emit(encode.mfsr(5, .flags));
    u.emit(encode.andi(6, 5, 0x20));
    u.checkEqImm(4, 6, 0);
    // 5: MTSR FLAGS cannot escalate (I and S ignored in user mode) - but I
    // is currently 1 and must stay 1.
    u.emit(encode.li(7, 0x00)); //     attempt: clear everything incl. I
    u.emit(encode.mtsr(.flags, 7));
    u.emit(encode.mfsr(5, .flags));
    u.emit(encode.andi(6, 5, 0x10));
    u.checkEqImm(5, 6, 0x10); //       I unchanged
    u.emit(encode.andi(6, 5, 0x20));
    u.checkEqImm(6, 6, 0); //          S unchanged (still user)
    // 6: SP came back as the user stack after the round-trip.
    u.checkEqImm(7, 15, 0x1100);
    // 7: privileged MTSR traps to BRK from user mode (R10 -> 2) and resumes.
    u.emit(encode.mtsr(.ivt, 1));
    u.checkEqImm(8, 10, 2);
    // 8: SSP survived the user-mode IRQ round-trip (MFSR is never privileged).
    u.emit(encode.mfsr(5, .ssp));
    u.checkEqImm(9, 5, 0x20F0);
    // 9: CLI is silently ignored in user mode (D45): I stays 1.
    u.emit(encode.cli());
    u.emit(encode.mfsr(5, .flags));
    u.emit(encode.andi(6, 5, 0x10));
    u.checkEqImm(10, 6, 0x10);
    // 10: RTI is supervisor-only (D44): a user-mode RTI traps to BRK
    // (R10 -> 3) and resumes after the RTI word (D36).
    u.emit(encode.rti());
    u.checkEqImm(11, 10, 3);
    u.pass();
    return image;
}

const Builder = struct {
    name: []const u8,
    build: *const fn () RomImage,
};

const builders = [_]Builder{
    .{ .name = "nop_loop.rom", .build = buildNopLoop },
    .{ .name = "test_cpu_load_store.rom", .build = buildLoadStore },
    .{ .name = "test_cpu_alu.rom", .build = buildAlu },
    .{ .name = "test_cpu_branch.rom", .build = buildBranch },
    .{ .name = "test_cpu_stack.rom", .build = buildStack },
    .{ .name = "test_cpu_irq.rom", .build = buildIrq },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.log.err("usage: genroms <output-dir>", .{});
        return error.BadUsage;
    }
    const out_dir_path = args[1];

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, out_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var out_dir = try cwd.openDir(io, out_dir_path, .{});
    defer out_dir.close(io);

    for (builders) |b| {
        const image = b.build();
        var file = try out_dir.createFile(io, b.name, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, &image.bytes);
        std.log.info("wrote {s}/{s} ({d} bytes)", .{ out_dir_path, b.name, image.bytes.len });
    }
}

// ---------------------------------------------------------------------------
// Tests — the image builder itself is unit-tested; file emission is
// exercised by `zig build genroms` in CI.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "genroms: nop_loop image has vectors and code where the spec says" {
    const image = buildNopLoop();
    try testing.expectEqual(@as(usize, rom.size), image.bytes.len);
    // RESET vector at file offset $3FC0 (= $FFFC0 − $FC000), LE, → $FC200.
    const reset = std.mem.readInt(u32, image.bytes[rom.vectors_offset..][0..4], .little);
    try testing.expectEqual(@as(u32, 0xFC200), reset);
    // Remaining vectors are zero (reserved entries are defined zeros, §2.1).
    var i: u32 = 1;
    while (i < 16) : (i += 1) {
        const v = std.mem.readInt(u32, image.bytes[rom.vectors_offset + 4 * i ..][0..4], .little);
        try testing.expectEqual(@as(u32, 0), v);
    }
    // Code at $FC200 (file offset $0200): NOP ×4 then JMPA $FC200.
    const code_off = 0x0200;
    var n: u32 = 0;
    while (n < 4) : (n += 1) {
        const w = std.mem.readInt(u32, image.bytes[code_off + 4 * n ..][0..4], .little);
        try testing.expectEqual(encode.nop(), w);
    }
    const jump = std.mem.readInt(u32, image.bytes[code_off + 16 ..][0..4], .little);
    try testing.expectEqual(encode.jmpa(0xFC200), jump);
    // Everything before the entry point is zero → would trap to BRK (D35),
    // never execute silently.
    try testing.expectEqual(@as(u8, 0), image.bytes[0]);
}
