//! fll relocator — patch resolved addresses into instruction fields and
//! data (Block 11, task 11.4).
//!
//! Applies the six .flobj relocation types (Phase 8 §8.4) against the
//! resolver's assembled output sections:
//!
//!   ABS16    u16 LE   ← target & $FFFF               (DW)
//!   ABS32    u32 LE   ← target                       (DD)
//!   ABS26    ADDR26   ← target                       (JMPA/CALLA)
//!   PCREL26  ADDR26   ← target − (site + 4), signed  (branches)
//!   LO16     IMM18    ← target & $FFFF               (LI/imm)
//!   HI4      IMM18    ← (target >> 16) & $F          (LUI/imm)
//!
//! Implementation decisions (continuing resolver.zig's at–aw):
//!   (ax) Field masks are DERIVED from encode.zig's own output at
//!        comptime — XORing a word whose field holds all-ones against a
//!        zero-field word isolates exactly the field bits. The bit
//!        layout therefore has one definition (audit P1) without this
//!        module restating positions or encode.zig exporting masks.
//!   (ay) PCREL26 verifies the ±(1<<25)-byte range defensively even
//!        though the Gab-16's 20-bit space can never exceed it, and
//!        ABS26 verifies target ≤ $3FF_FFFF likewise; both name the
//!        object and site address on failure.

const std = @import("std");
const loader = @import("loader");
const resolver = @import("resolver");
const encode = @import("encode");

pub const Error = error{ Relocate, OutOfMemory };

/// I-format IMM18 field (bits 17:0), derived per decision ax: imm −1
/// sign-extends to all-ones across exactly the field.
const imm18_mask: u32 = encode.li(0, -1) ^ encode.li(0, 0);

/// J-format ADDR26 field (bits 25:0), derived per decision ax: a branch
/// offset of −1 sign-extends across exactly the field (jmpa can't be
/// used here — it validates its argument as a 20-bit address).
const addr26_mask: u32 = encode.beq(-1) ^ encode.beq(0);

comptime {
    // The derivations must produce contiguous low-bit fields.
    std.debug.assert(imm18_mask == (1 << 18) - 1);
    std.debug.assert(addr26_mask == (1 << 26) - 1);
}

/// Patch every relocation of every object into `link`'s output sections.
pub fn relocate(
    arena: std.mem.Allocator,
    objs: []const loader.Object,
    link: *resolver.Link,
    err_msg_out: ?*[]const u8,
) Error!void {
    const fail = struct {
        fn f(a: std.mem.Allocator, out: ?*[]const u8, comptime fmt: []const u8, args: anytype) Error {
            if (out) |dst| {
                dst.* = std.fmt.allocPrint(a, fmt, args) catch "out of memory formatting diagnostic";
            }
            return Error.Relocate;
        }
    }.f;

    for (objs, 0..) |obj, oi| {
        for (obj.relocs) |rel| {
            const target = link.symbolAddress(objs, oi, rel.symbol);
            const piece = link.pieces[oi][rel.section];
            const out = &link.out[piece.out];
            const site_off = piece.off + rel.offset;
            const site_addr = out.base + site_off;

            switch (rel.rtype) {
                .abs16 => {
                    std.mem.writeInt(u16, out.data[site_off..][0..2], @truncate(target), .little);
                },
                .abs32 => {
                    std.mem.writeInt(u32, out.data[site_off..][0..4], target, .little);
                },
                .abs26 => {
                    if (target > addr26_mask)
                        return fail(arena, err_msg_out, "{s}: ABS26 target ${X} at ${X:0>5} does not fit 26 bits (decision ay)", .{ obj.path, target, site_addr });
                    const w = std.mem.readInt(u32, out.data[site_off..][0..4], .little);
                    std.mem.writeInt(u32, out.data[site_off..][0..4], (w & ~addr26_mask) | target, .little);
                },
                .pcrel26 => {
                    const diff = @as(i64, target) - (@as(i64, site_addr) + 4);
                    if (diff < encode.pcrel26_min or diff > encode.pcrel26_max)
                        return fail(arena, err_msg_out, "{s}: branch at ${X:0>5} to ${X:0>5} is out of PCREL26 range (decision ay)", .{ obj.path, site_addr, target });
                    const field = @as(u32, @bitCast(@as(i32, @intCast(diff)))) & addr26_mask;
                    const w = std.mem.readInt(u32, out.data[site_off..][0..4], .little);
                    std.mem.writeInt(u32, out.data[site_off..][0..4], (w & ~addr26_mask) | field, .little);
                },
                .lo16 => {
                    const w = std.mem.readInt(u32, out.data[site_off..][0..4], .little);
                    std.mem.writeInt(u32, out.data[site_off..][0..4], (w & ~imm18_mask) | (target & 0xFFFF), .little);
                },
                .hi4 => {
                    const w = std.mem.readInt(u32, out.data[site_off..][0..4], .little);
                    std.mem.writeInt(u32, out.data[site_off..][0..4], (w & ~imm18_mask) | ((target >> 16) & 0xF), .little);
                },
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests (task 11.4 acceptance: all six types patch correctly, verified
// per field against encode.zig-built expected words).
// ---------------------------------------------------------------------------

const testing = std.testing;
const codegen = @import("codegen");
const objfile = @import("objfile");
const script = @import("script");

fn makeObj(arena: std.mem.Allocator, path: []const u8, src: []const u8) !loader.Object {
    const incbins = codegen.IncbinMap.empty;
    const o = try codegen.assemble(arena, src, &incbins);
    const bytes = try objfile.emit(arena, &o, null);
    return loader.load(arena, path, bytes, null);
}

fn word(data: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
}

test "all six relocation types patch to encode.zig-exact words" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Code placed at $14100 so (msg >> 16) is nonzero and HI4 is a real
    // patch, not a zero no-op.
    const a = try makeObj(arena, "a.flobj",
        \\    SECTION code
        \\start:
        \\    LI   R1, (msg & $FFFF)
        \\    LUI  R2, (msg >> 16)
        \\    CALLA helper
        \\    BEQ  helper
        \\    HLT
        \\    SECTION data
        \\ptr16:
        \\    DW msg
        \\ptr32:
        \\    DD helper
        \\msg:
        \\    DB "X"
        \\
    );
    const b = try makeObj(arena, "b.flobj",
        \\    SECTION code
        \\helper:
        \\    RET
        \\
    );

    var msg_buf: []const u8 = "";
    const scr = try script.parse(arena, "t.flld",
        \\ENTRY start
        \\SECTION code AT $14100
        \\SECTION data AFTER code
        \\
    , &msg_buf);
    const objs = [_]loader.Object{ a, b };
    var link = try resolver.resolve(arena, &objs, scr, &msg_buf);
    try relocate(arena, &objs, &link, &msg_buf);

    // Layout: code base $1410C (file at $14100 + 12); a.code = 20 bytes,
    // b's piece at offset 20 → helper = $14120; code size 24; data base
    // $14124: ptr16 @+0, ptr32 @+2, msg @ $1412A.
    const helper: u32 = 0x14120;
    const msg_addr: u32 = 0x1412A;
    try testing.expectEqual(helper, link.globals.get("helper").?);
    try testing.expectEqual(msg_addr, link.globals.get("msg").?);

    const code = link.out[0].data;
    // LO16: the IMM18 field now holds msg & $FFFF — the word equals a
    // direct encoding of that immediate.
    try testing.expectEqual(encode.li(1, 0x412A), word(code, 0));
    // HI4: IMM18 ← (msg >> 16) & $F = 1.
    try testing.expectEqual(encode.lui(2, 0x1), word(code, 1));
    // ABS26: full 20-bit target in the ADDR26 field.
    try testing.expectEqual(encode.calla(helper), word(code, 2));
    // PCREL26: helper − (site $14118 + 4) = 4.
    try testing.expectEqual(encode.beq(4), word(code, 3));
    // Unrelocated neighbours are untouched.
    try testing.expectEqual(encode.hlt(), word(code, 4));
    try testing.expectEqual(encode.ret(), word(code, 5)); // b's piece at offset 20

    const data = link.out[1].data;
    // ABS16 and ABS32.
    try testing.expectEqual(@as(u16, 0x412A), std.mem.readInt(u16, data[0..2], .little));
    try testing.expectEqual(helper, std.mem.readInt(u32, data[2..6], .little));
    try testing.expectEqual(@as(u8, 'X'), data[6]);
}

test "own-object references relocate without a global lookup (decision aw)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // msg is defined in the SAME object that references it: the reloc's
    // symbol entry is section-relative, so symbolAddress never consults
    // the global table.
    const a = try makeObj(arena, "a.flobj",
        \\    SECTION code
        \\start:
        \\    LI R1, (msg & $FFFF)
        \\    HLT
        \\    SECTION data
        \\msg:
        \\    DB 0
        \\
    );
    var msg_buf: []const u8 = "";
    const scr = try script.parse(arena, "t.flld",
        \\ENTRY start
        \\SECTION code AT $04100
        \\SECTION data AFTER code
        \\
    , &msg_buf);
    const objs = [_]loader.Object{a};
    var link = try resolver.resolve(arena, &objs, scr, &msg_buf);
    try relocate(arena, &objs, &link, &msg_buf);

    // data base = $0410C + 8 = $04114.
    try testing.expectEqual(encode.li(1, 0x4114), word(link.out[0].data, 0));
}
