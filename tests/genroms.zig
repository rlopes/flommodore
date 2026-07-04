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
const flapp = @import("flapp");

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

    /// Write one raw byte at a machine address inside the ROM (font data).
    pub fn writeByte(image: *RomImage, addr: u32, byte: u8) void {
        image.bytes[offsetOf(addr)] = byte;
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
const user_code_addr: u32 = 0xFC500; // irq ROM: user-mode code (its main stays short)
// Handlers and the FAIL stub live in high ROM so main code has room to
// grow: entry region = $FC200–$FCFFF (896 instructions). The Block 6
// sprite ROM overran the original $FC600 layout — a silent-corruption
// class of bug the generator can't detect, hence the guard in emitAll.
const fail_addr: u32 = 0xFD000;
const irq_handler_addr: u32 = 0xFD100;
const brk_handler_addr: u32 = 0xFD180;

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
        // Main code must never grow into the FAIL stub / handler region —
        // that failure mode is silent image corruption (found the hard way
        // by the Block 6 sprite ROM).
        std.debug.assert(kit.cur.addr < fail_addr);
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

/// test_io_timer.rom (Block 4, task 4.10): reload, repeat/one-shot, all
/// four divisors (timing measured against CYC), device IRQ gate, raw
/// IRQSTAT vs IRQMASK, IRQACK w1c, timer independence, CNT read-only —
/// and the ROM finishes via SYSPWR soft power-off instead of HLT (task 4.2).
///
/// Register conventions: R1 = timer A base ($80010; timer B at +8, keyboard
/// at +$10, IRQ controller at +$30 via offsets), R8 = IRQ controller base
/// (handler-owned), R11 = check number, R12 = scratch.
fn buildIoTimer() RomImage {
    var image = RomImage.init();
    image.setVector(2, irq_handler_addr);

    // IRQ handler: ack everything pending, count invocations in R2.
    var h = image.codeAt(irq_handler_addr);
    h.emit(encode.lw(9, 8, 0)); //   R9 = IRQSTAT   (R8 = $80040, set by main)
    h.emit(encode.sw(8, 2, 9)); //   IRQACK <- R9 (w1c per source, §5.5)
    h.emit(encode.addi(2, 2, 1));
    h.emit(encode.rti());

    var k = Kit.begin(&image);
    // Supervisor setup.
    k.emit(encode.li(15, 0x1100)); //  SP (D12)
    k.emit(encode.li(3, 0x20F0));
    k.emit(encode.mtsr(.ssp, 3));
    k.loadAddr(3, 0xFFFC0);
    k.emit(encode.mtsr(.ivt, 3));
    k.loadAddr(1, 0x80010); //         timer A base
    k.loadAddr(8, 0x80040); //         IRQ controller base

    // Checks 1-4: one-shot expiry timing at every divisor, measured with
    // CYC (D39/D41 make the machine fully cycle-deterministic). The poll
    // loop is 4 instructions, so the measured latency window is
    // [period, period + poll granularity + a few setup cycles].
    const timing = [_]struct { div: i32, reload: i32, period: i32 }{
        .{ .div = 0, .reload = 20, .period = 20 }, //   ÷1
        .{ .div = 1, .reload = 5, .period = 40 }, //    ÷8
        .{ .div = 2, .reload = 2, .period = 128 }, //   ÷64
        .{ .div = 3, .reload = 2, .period = 512 }, //   ÷256
    };
    for (timing, 1..) |t, n| {
        k.emit(encode.li(12, t.reload));
        k.emit(encode.sw(1, 0, 12)); //             TxLOADLO <- reload
        k.emit(encode.sw(1, 1, 0)); //              TxLOADHI <- 0 (via R0)
        k.emit(encode.li(12, t.div));
        k.emit(encode.sw(1, 5, 12)); //             TxDIV
        k.emit(encode.mfsr(5, .cyc)); //            start stamp
        k.emit(encode.li(12, 1));
        k.emit(encode.sw(1, 4, 12)); //             TxCTRL: enable, one-shot
        const poll_top = k.cur.addr;
        k.emit(encode.lw(6, 1, 6)); //              poll TxSTAT
        k.emit(encode.cmpi(6, 0));
        k.branchTo(.beq, poll_top);
        k.emit(encode.mfsr(6, .cyc)); //            end stamp
        k.emit(encode.sub(7, 6, 5)); //             elapsed cycles (low 16 compared)
        // Window: expiry can be visible to the poll no earlier than the
        // period (enable-write cycle counts as tick #1) and the loop adds
        // at most ~10 cycles of granularity + stamp overhead.
        k.num(@intCast(n));
        k.emit(encode.cmpi(7, t.period));
        k.assertTaken(.bcs); //                     elapsed >= period
        k.emit(encode.cmpi(7, t.period + 12));
        k.assertTaken(.bcc); //                     elapsed < period + 12
        // One-shot: TxCTRL bit 0 self-cleared; STAT w1c works.
        k.emit(encode.lw(6, 1, 4));
        k.emit(encode.andi(6, 6, 1));
        k.checkEqImm(@intCast(10 + n), 6, 0);
        k.emit(encode.li(12, 1));
        k.emit(encode.sw(1, 6, 12));
        k.emit(encode.lw(6, 1, 6));
        k.checkEqImm(@intCast(20 + n), 6, 0);
    }

    // Check 5: device gate + raw IRQSTAT vs mask. Timer A repeat+IRQ with
    // IRQMASK = 0: the bit sets raw, no CPU interrupt (I is 0 anyway).
    k.emit(encode.li(12, 200));
    k.emit(encode.sw(1, 0, 12)); //  reload 200
    k.emit(encode.sw(1, 5, 0)); //   ÷1
    k.emit(encode.li(12, 7));
    k.emit(encode.sw(1, 4, 12)); //  enable | repeat | IRQ
    const poll_stat = k.cur.addr;
    k.emit(encode.lw(6, 1, 6)); //   wait for first expiry via TxSTAT
    k.emit(encode.cmpi(6, 0));
    k.branchTo(.beq, poll_stat);
    k.emit(encode.lw(6, 8, 0)); //   IRQSTAT raw
    k.emit(encode.andi(6, 6, 1));
    k.checkEqImm(30, 6, 1); //       bit 0 pending though masked out
    k.checkEqImm(31, 2, 0); //       and no handler ran
    k.emit(encode.li(12, 1));
    k.emit(encode.sw(8, 2, 12)); //  IRQACK bit 0
    k.emit(encode.lw(6, 8, 0));
    k.emit(encode.andi(6, 6, 1));
    k.checkEqImm(32, 6, 0); //       w1c cleared it (next expiry is ~200 cycles off)

    // Check 6: masked in + SEI -> handler runs 3 periods, acking each.
    k.emit(encode.li(12, 1));
    k.emit(encode.sw(8, 1, 12)); //  IRQMASK bit 0
    k.emit(encode.sei());
    const wait_irqs = k.cur.addr;
    k.emit(encode.cmpi(2, 3));
    k.branchTo(.bne, wait_irqs);
    k.emit(encode.sw(1, 4, 0)); //   disable timer A
    k.emit(encode.cli());
    k.checkEqImm(33, 2, 3); //       exactly 3 (period 200 >> disable latency)

    // Check 7: timer B independent, its own IRQ bit; CNT is read-only.
    k.emit(encode.li(12, 30));
    k.emit(encode.sw(1, 8, 12)); //  TBLOADLO (base+8)
    k.emit(encode.sw(1, 13, 0)); //  TBDIV ÷1
    k.emit(encode.li(12, 1));
    k.emit(encode.sw(1, 12, 12)); // TBCTRL enable one-shot (no IRQ bit)
    const poll_b = k.cur.addr;
    k.emit(encode.lw(6, 1, 14)); //  TBSTAT
    k.emit(encode.cmpi(6, 0));
    k.branchTo(.beq, poll_b);
    k.emit(encode.lw(6, 8, 0)); //   IRQSTAT: TB gate off -> bit 1 never set
    k.emit(encode.andi(6, 6, 2));
    k.checkEqImm(34, 6, 0);
    k.emit(encode.li(12, 0x99));
    k.emit(encode.sw(1, 10, 12)); // TBCNTLO write attempt
    k.emit(encode.lw(6, 1, 10));
    k.checkEqImm(35, 6, 0); //       read-only: count froze at 0

    // Check 8: keyboard and joystick sane defaults (tasks 4.8/4.9).
    k.emit(encode.lw(6, 1, 0x10)); //  KSTAT ($80020)
    k.checkEqImm(36, 6, 0);
    k.emit(encode.lw(6, 1, 0x20)); //  JOY1 ($80030)
    k.checkEqImm(37, 6, 0);

    // Finish: write PASS, then SYSPWR soft power-off (task 4.2) - the
    // harness must exit cleanly WITHOUT a HLT.
    k.emit(encode.li(11, 0x600D));
    k.emit(encode.sw(0, result_addr, 11));
    k.loadAddr(3, 0x80003); //         SYSPWR
    k.emit(encode.li(12, 1));
    k.emit(encode.sw(3, 0, 12));
    k.emit(encode.jmpa(fail_addr)); // must never execute
    return image;
}

/// test_prog.flapp (Block 5, task 5.5): a standalone program image built
/// with encode.zig — loads at the canonical $04100 (D10), writes the PASS
/// marker, and exits via SYSPWR. Exercises the full .flapp path: header
/// parse, verbatim load, entry at load+12.
fn buildTestFlapp() [flapp.header_size + 8 * 4]u8 {
    var file: [flapp.header_size + 8 * 4]u8 = @splat(0);
    flapp.writeHeader(file[0..flapp.header_size], .{
        .version = 1,
        .entry_offset = flapp.header_size,
        .min_ram_kb = 1,
        .load_addr = 0x04100,
    });
    const code = [8]u32{
        encode.li(11, 0x600D),
        encode.sw(0, result_addr, 11), //  [$00080] <- $600D
        encode.li(3, 0x0003), //           LOAD_ADDR R3, $80003 (SYSPWR)
        encode.lui(3, 0x8),
        encode.li(12, 1),
        encode.sw(3, 0, 12), //            soft power-off (§5.1)
        encode.jmpa(0x0410C), //           must never execute
        encode.nop(),
    };
    for (code, 0..) |word, i| {
        std.mem.writeInt(u32, file[flapp.header_size + 4 * i ..][0..4], word, .little);
    }
    return file;
}

// ---------------------------------------------------------------------------
// Block 6 VIC-256 test ROMs (task 6.21). Verified by golden RGB24 hash via
// `harness --frames N --golden HEX`; each also self-checks device state and
// writes the $600D marker (--expect-pass works too).
// ---------------------------------------------------------------------------

const vic_base: u32 = 0x80200;

/// Emit a VIC register write: SB [R1 + reg-offset], value — R1 must hold
/// $80200. Uses R12 as scratch.
fn vicWrite(k: *Kit, reg_offset: i32, value: i32) void {
    k.emit(encode.li(12, value));
    k.emit(encode.sb(1, reg_offset, 12));
}

/// Emit the standard identity palette loop: entry i = (i, i, i) at $02100.
/// Clobbers R3, R4. ~1.8k cycles.
fn emitIdentityPalette(k: *Kit) void {
    k.loadAddr(3, 0x02100);
    k.emit(encode.li(4, 0));
    const top = k.cur.addr;
    k.emit(encode.sb(3, 0, 4));
    k.emit(encode.sb(3, 1, 4));
    k.emit(encode.sb(3, 2, 4));
    k.emit(encode.addi(3, 3, 3));
    k.emit(encode.addi(4, 4, 1));
    k.emit(encode.cmpi(4, 256));
    k.branchTo(.bne, top);
}

/// Common VIC setup: 320×180 @ 8bpp, palette at $02100, SAT $02400,
/// tile map $02600, VBUF $44000, VBUF2 $54000. Leaves R1 = $80200.
fn emitVicBases(k: *Kit) void {
    k.loadAddr(1, vic_base);
    vicWrite(k, 0x01, 3); //          VPALETTE = 8bpp
    vicWrite(k, 0x02, 0); //          VRESX = 320
    vicWrite(k, 0x03, 0); //          VRESY = 180
    vicWrite(k, 0x06, 0x00); //       VBUF = $44000/16 = $4400
    vicWrite(k, 0x07, 0x44);
    vicWrite(k, 0x08, 0x00); //       VBUF2 = $54000/16 = $5400
    vicWrite(k, 0x09, 0x54);
    vicWrite(k, 0x0B, 0x10); //       VPALBASE = $02100/16 = $0210
    vicWrite(k, 0x0C, 0x02);
    vicWrite(k, 0x0D, 0x40); //       VSATBASE = $02400/16 = $0240
    vicWrite(k, 0x0E, 0x02);
    vicWrite(k, 0x0F, 0x60); //       VTMAPBASE = $02600/16 = $0260
    vicWrite(k, 0x10, 0x02);
}

/// test_vic_bitmap.rom: 8bpp bitmap gradient in both buffers (buffer 2
/// inverted), then a VSWAP — the golden frame shows the *inverted* gradient,
/// proving tasks 6.7 (bitmap), 6.6 (palette), and 6.19 (double buffer).
fn buildVicBitmap() RomImage {
    var image = RomImage.init();
    var k = Kit.begin(&image);
    k.emit(encode.li(15, 0x1100));
    emitIdentityPalette(&k);
    emitVicBases(&k);
    // Fill both framebuffers: fb[y*320+x] = (x+y) & $FF; fb2 = ~fb.
    k.loadAddr(3, 0x44000);
    k.emit(encode.li(6, 0)); //         y
    const y_top = k.cur.addr;
    k.emit(encode.li(7, 0)); //         x
    const x_top = k.cur.addr;
    k.emit(encode.add(8, 6, 7)); //     value = x + y (low byte stored)
    k.emit(encode.sb(3, 0, 8));
    k.emit(encode.not(9, 8)); //        inverted for buffer 2
    k.emit(encode.sb(3, 65536, 9)); //  $54000 = $44000 + $10000
    k.emit(encode.addi(3, 3, 1));
    k.emit(encode.addi(7, 7, 1));
    k.emit(encode.cmpi(7, 320));
    k.branchTo(.bne, x_top);
    k.emit(encode.addi(6, 6, 1));
    k.emit(encode.cmpi(6, 180));
    k.branchTo(.bne, y_top);
    vicWrite(&k, 0x00, 0); //           VMODE = bitmap
    vicWrite(&k, 0x0A, 1); //           VSWAP: front becomes the inverted buffer
    k.emit(encode.li(11, 0x600D));
    k.emit(encode.sw(0, result_addr, 11));
    k.emit(encode.hlt()); //            VIC keeps rendering while halted
    return image;
}

/// Minimal 8×8 font glyphs for the text ROM.
const Glyph = struct { ch: u8, rows: [8]u8 };
const font_glyphs = [_]Glyph{
    .{ .ch = 'F', .rows = .{ 0xFC, 0x80, 0x80, 0xF8, 0x80, 0x80, 0x80, 0x00 } },
    .{ .ch = 'L', .rows = .{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0xFC, 0x00 } },
    .{ .ch = 'O', .rows = .{ 0x78, 0x84, 0x84, 0x84, 0x84, 0x84, 0x78, 0x00 } },
    .{ .ch = 'M', .rows = .{ 0x84, 0xCC, 0xB4, 0x84, 0x84, 0x84, 0x84, 0x00 } },
    .{ .ch = 'D', .rows = .{ 0xF8, 0x84, 0x84, 0x84, 0x84, 0x84, 0xF8, 0x00 } },
    .{ .ch = 'R', .rows = .{ 0xF8, 0x84, 0x84, 0xF8, 0x90, 0x88, 0x84, 0x00 } },
    .{ .ch = 'E', .rows = .{ 0xFC, 0x80, 0x80, 0xF8, 0x80, 0x80, 0xFC, 0x00 } },
    .{ .ch = '!', .rows = .{ 0x30, 0x30, 0x30, 0x30, 0x30, 0x00, 0x30, 0x00 } },
};

/// test_vic_text.rom: 640×360 text mode (80×45 cells), embedded ROM font at
/// $FE000 (Phase 6 §6.1), "FLOMMODORE!" in two attribute styles (task 6.20:
/// 2-byte cells, bit 7 = leftmost, fg = attr[3:0], bg = attr[7:4]).
fn buildVicText() RomImage {
    var image = RomImage.init();
    for (font_glyphs) |g| {
        for (g.rows, 0..) |row_byte, r| {
            image.writeByte(0xFE000 + 8 * @as(u32, g.ch) + @as(u32, @intCast(r)), row_byte);
        }
    }
    var k = Kit.begin(&image);
    k.emit(encode.li(15, 0x1100));
    emitIdentityPalette(&k);
    // Brighten entry 1 (fg) and colour entry 2 (inverse bg) for contrast.
    k.loadAddr(3, 0x02100);
    k.emit(encode.li(4, 255));
    k.emit(encode.sb(3, 3, 4)); //      palette[1] = (255, 255, 255)
    k.emit(encode.sb(3, 4, 4));
    k.emit(encode.sb(3, 5, 4));
    k.emit(encode.li(4, 96));
    k.emit(encode.sb(3, 6, 4)); //      palette[2] = (96, 0, 0)
    k.emit(encode.li(4, 0));
    k.emit(encode.sb(3, 7, 4));
    k.emit(encode.sb(3, 8, 4));
    emitVicBases(&k);
    vicWrite(&k, 0x02, 1); //           VRESX = 640
    vicWrite(&k, 0x03, 1); //           VRESY = 360
    vicWrite(&k, 0x00, 3); //           VMODE = text
    // "FLOMMODORE!" at cell row 2 col 4 (white on black) and row 4 col 4
    // (black on dark red — inverse video).
    const TextRow = struct { row: u32, attr: i32 };
    const text_rows = [_]TextRow{
        .{ .row = 2, .attr = 0x01 },
        .{ .row = 4, .attr = 0x20 },
    };
    const msg = "FLOMMODORE!";
    for (text_rows) |tr| {
        k.loadAddr(3, 0x02600 + 2 * (tr.row * 80 + 4));
        for (msg) |ch| {
            k.emit(encode.li(4, ch));
            k.emit(encode.sb(3, 0, 4));
            k.emit(encode.li(4, tr.attr));
            k.emit(encode.sb(3, 1, 4));
            k.emit(encode.addi(3, 3, 2));
        }
    }
    k.emit(encode.li(11, 0x600D));
    k.emit(encode.sw(0, result_addr, 11));
    k.emit(encode.hlt());
    return image;
}

/// Override one palette entry at $02100 (after emitIdentityPalette).
/// Clobbers R3, R4.
fn emitPaletteEntry(k: *Kit, index: u32, r: i32, g: i32, b: i32) void {
    k.loadAddr(3, 0x02100 + 3 * index);
    k.emit(encode.li(4, r));
    k.emit(encode.sb(3, 0, 4));
    k.emit(encode.li(4, g));
    k.emit(encode.sb(3, 1, 4));
    k.emit(encode.li(4, b));
    k.emit(encode.sb(3, 2, 4));
}

/// test_vic_sprite.rom: mode 1 (tile) at 320×180 @ 8bpp with a tile band,
/// fine scroll, sprites (front / behind / flip-X / 16×16 / palette offset),
/// the 8-per-scanline limit, a collision self-check, and a raster copper
/// chain splitting VBGCOL at line 90 — the task 6.18 acceptance.
fn buildVicSprite() RomImage {
    var image = RomImage.init();
    image.setVector(2, irq_handler_addr);

    // Raster handler: ack IRQ bit 5; toggle between (VBGCOL 60, VSCAN 0)
    // and (VBGCOL 20, VSCAN 90) — the classic two-point copper chain.
    // R7 = phase, R8 = IRQ controller base, R1 = VIC base (main-owned).
    var h = image.codeAt(irq_handler_addr);
    h.emit(encode.li(12, 0x20)); //     IRQACK <- raster bit
    h.emit(encode.sw(8, 2, 12));
    h.emit(encode.xori(7, 7, 1));
    h.emit(encode.cmpi(7, 1));
    const phase1_at = h.addr;
    h.emit(0); //                       BNE phase0 (patched below)
    h.emit(encode.li(12, 60)); //       phase 1 (fired at 90): bottom colour,
    h.emit(encode.sb(1, 0x04, 12)); //  retrigger at line 0
    h.emit(encode.li(12, 0));
    h.emit(encode.sb(1, 0x14, 12));
    h.emit(encode.rti());
    const phase0_at = h.addr;
    h.emit(encode.li(12, 20)); //       phase 0 (fired at 0): top colour,
    h.emit(encode.sb(1, 0x04, 12)); //  retrigger at line 90
    h.emit(encode.li(12, 90));
    h.emit(encode.sb(1, 0x14, 12));
    h.emit(encode.rti());
    {
        const off: i64 = @as(i64, phase0_at) - (@as(i64, phase1_at) + 4);
        image.writeWord32(phase1_at, encode.formatJ(.bne, @as(u32, @bitCast(@as(i32, @intCast(off)))) & 0x3FF_FFFF));
    }

    var k = Kit.begin(&image);
    k.emit(encode.li(15, 0x1100));
    k.emit(encode.li(3, 0x20F0));
    k.emit(encode.mtsr(.ssp, 3));
    k.loadAddr(3, 0xFFFC0);
    k.emit(encode.mtsr(.ivt, 3));
    emitIdentityPalette(&k);
    // Vivid entries so the golden frame is visually legible:
    emitPaletteEntry(&k, 20, 0, 0, 130); //    top background: deep blue
    emitPaletteEntry(&k, 60, 0, 110, 110); //  bottom background: teal
    emitPaletteEntry(&k, 5, 0, 200, 0); //     tile band: green
    emitPaletteEntry(&k, 7, 255, 80, 0); //    8×8 sprites: orange
    emitPaletteEntry(&k, 17, 255, 220, 0); //  sprite 3 (7 + offset 10): yellow
    emitPaletteEntry(&k, 9, 255, 0, 255); //   16×16 sprite: magenta
    emitVicBases(&k);

    // Tile 1 graphic: solid colour 5 (64 bytes at $40040).
    k.loadAddr(3, 0x40040);
    k.emit(encode.li(4, 0));
    const t1_top = k.cur.addr;
    k.emit(encode.li(12, 5));
    k.emit(encode.sb(3, 0, 12));
    k.emit(encode.addi(3, 3, 1));
    k.emit(encode.addi(4, 4, 1));
    k.emit(encode.cmpi(4, 64));
    k.branchTo(.bne, t1_top);
    // Sprite graphic tile 2 ($40080): left 4 columns colour 7, rest 0
    // (transparent) — makes flip-X visibly different.
    k.loadAddr(3, 0x40080);
    k.emit(encode.li(4, 0)); //         row counter
    const s2_row = k.cur.addr;
    k.emit(encode.li(12, 7));
    k.emit(encode.sb(3, 0, 12));
    k.emit(encode.sb(3, 1, 12));
    k.emit(encode.sb(3, 2, 12));
    k.emit(encode.sb(3, 3, 12));
    k.emit(encode.addi(3, 3, 8));
    k.emit(encode.addi(4, 4, 1));
    k.emit(encode.cmpi(4, 8));
    k.branchTo(.bne, s2_row);
    // 16×16 sprite graphic index 1 ($40100): solid colour 9 (256 bytes).
    k.loadAddr(3, 0x40100);
    k.emit(encode.li(4, 0));
    const s16_top = k.cur.addr;
    k.emit(encode.li(12, 9));
    k.emit(encode.sb(3, 0, 12));
    k.emit(encode.addi(3, 3, 1));
    k.emit(encode.addi(4, 4, 1));
    k.emit(encode.cmpi(4, 256));
    k.branchTo(.bne, s16_top);
    // Tile map: row 10 (y 80–87) columns 0–39 = tile 1 → a horizontal band.
    k.loadAddr(3, 0x02600 + 40 * 10);
    k.emit(encode.li(4, 0));
    const map_top = k.cur.addr;
    k.emit(encode.li(12, 1));
    k.emit(encode.sb(3, 0, 12));
    k.emit(encode.addi(3, 3, 1));
    k.emit(encode.addi(4, 4, 1));
    k.emit(encode.cmpi(4, 40));
    k.branchTo(.bne, map_top);

    // SAT: sprite 0 front (30,50); 1 behind the band (60,82) — its middle
    // rows hide under the tiles; 2 flip-X (100,50); 3 overlaps 0 →
    // collision, palette offset +10; 10–19 all on line 140 → only the
    // first 8 hardware units render (task 6.15).
    const SatSpec = struct { n: u32, x: i32, y: i32, tile: i32, flags: i32, pal: i32 };
    var sats: [14]SatSpec = undefined;
    sats[0] = .{ .n = 0, .x = 30, .y = 50, .tile = 2, .flags = 0x80, .pal = 0 };
    sats[1] = .{ .n = 1, .x = 60, .y = 82, .tile = 2, .flags = 0x84, .pal = 0 };
    sats[2] = .{ .n = 2, .x = 100, .y = 50, .tile = 2, .flags = 0xC0, .pal = 0 };
    // x=32: opaque columns 32–35 overlap sprite 0's opaque 30–33 → collision.
    sats[3] = .{ .n = 3, .x = 32, .y = 50, .tile = 2, .flags = 0x80, .pal = 10 };
    for (0..10) |i| {
        sats[4 + i] = .{
            .n = @intCast(10 + i),
            .x = @intCast(10 + 12 * i),
            .y = 140,
            .tile = 2,
            .flags = 0x80,
            .pal = 0,
        };
    }
    for (sats) |sp| {
        k.loadAddr(3, 0x02400 + 8 * sp.n);
        k.emit(encode.li(4, sp.x & 0xFF));
        k.emit(encode.sb(3, 0, 4));
        k.emit(encode.li(4, (sp.x >> 8) & 0xFF));
        k.emit(encode.sb(3, 1, 4));
        k.emit(encode.li(4, sp.y & 0xFF));
        k.emit(encode.sb(3, 2, 4));
        k.emit(encode.li(4, (sp.y >> 8) & 0xFF));
        k.emit(encode.sb(3, 3, 4));
        k.emit(encode.li(4, sp.tile));
        k.emit(encode.sb(3, 4, 4));
        k.emit(encode.li(4, sp.flags));
        k.emit(encode.sb(3, 5, 4));
        k.emit(encode.li(4, sp.pal));
        k.emit(encode.sb(3, 6, 4));
    }
    // One 16×16 sprite (index 20, group 2) at (200, 60).
    k.loadAddr(3, 0x02400 + 8 * 20);
    k.emit(encode.li(4, 200));
    k.emit(encode.sb(3, 0, 4));
    k.emit(encode.li(4, 60));
    k.emit(encode.sb(3, 2, 4));
    k.emit(encode.li(4, 1));
    k.emit(encode.sb(3, 4, 4));
    k.emit(encode.li(4, 0x88)); //      enable | size 16×16
    k.emit(encode.sb(3, 5, 4));

    // Live VIC config: tile mode, fine scroll x=3, sprite groups 0–2,
    // raster chain armed — phase 0 → first fire at line 90.
    vicWrite(&k, 0x00, 1); //           VMODE = tile
    vicWrite(&k, 0x11, 3); //           VSCROLLX
    vicWrite(&k, 0x13, 0x07); //        VSPRENA groups 0–2
    vicWrite(&k, 0x04, 20); //          VBGCOL (top colour)
    vicWrite(&k, 0x14, 90); //          VSCANLO = 90
    vicWrite(&k, 0x15, 0); //           VSCANHI = 0
    vicWrite(&k, 0x16, 0x02); //        VIRQEN: raster enable
    k.loadAddr(8, 0x80040); //          IRQ controller (handler-owned R8)
    k.emit(encode.li(12, 0x20));
    k.emit(encode.sw(8, 1, 12)); //     IRQMASK = raster bit
    k.emit(encode.sei());

    // Wait two VBLANK edges (VSTAT bit 0: 0→1 twice) so at least one full
    // frame has rendered, then self-check the collision flag (task 6.16).
    for (0..2) |_| {
        const wait_clear = k.cur.addr;
        k.emit(encode.lw(5, 1, 0x17));
        k.emit(encode.andi(5, 5, 1));
        k.emit(encode.cmpi(5, 0));
        k.branchTo(.bne, wait_clear);
        const wait_set = k.cur.addr;
        k.emit(encode.lw(5, 1, 0x17));
        k.emit(encode.andi(5, 5, 1));
        k.emit(encode.cmpi(5, 0));
        k.branchTo(.beq, wait_set);
    }
    k.num(1);
    k.emit(encode.lw(5, 1, 0x17)); //   VSTAT
    k.emit(encode.andi(5, 5, 0x04));
    k.emit(encode.cmpi(5, 0x04));
    k.assertTaken(.beq); //             sprites 0/3 must have collided
    k.emit(encode.li(11, 0x600D));
    k.emit(encode.sw(0, result_addr, 11));
    // Halt loop: raster IRQs wake HLT twice per frame; the handler RTIs to
    // the JMPA, which re-halts. The copper chain runs forever.
    const halt_top = k.cur.addr;
    k.emit(encode.hlt());
    k.emit(encode.jmpa(halt_top));
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
    .{ .name = "test_io_timer.rom", .build = buildIoTimer },
    .{ .name = "test_vic_bitmap.rom", .build = buildVicBitmap },
    .{ .name = "test_vic_text.rom", .build = buildVicText },
    .{ .name = "test_vic_sprite.rom", .build = buildVicSprite },
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

    const flapp_image = buildTestFlapp();
    var f = try out_dir.createFile(io, "test_prog.flapp", .{});
    defer f.close(io);
    try f.writeStreamingAll(io, &flapp_image);
    std.log.info("wrote {s}/test_prog.flapp ({d} bytes)", .{ out_dir_path, flapp_image.len });
}

// ---------------------------------------------------------------------------
// Tests — the image builder itself is unit-tested; file emission is
// exercised by `zig build genroms` in CI.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "genroms: test_prog.flapp parses and enters at load+12" {
    const file = buildTestFlapp();
    const h = try flapp.parseHeader(&file);
    try testing.expectEqual(@as(u32, 0x04100), h.load_addr);
    try testing.expectEqual(@as(u16, flapp.header_size), h.entry_offset);
    const first = std.mem.readInt(u32, file[flapp.header_size..][0..4], .little);
    try testing.expectEqual(encode.li(11, 0x600D), first);
}

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
