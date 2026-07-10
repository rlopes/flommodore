//! flas .flobj v1.1 writer (Block 10, task 10.9).
//!
//! Serializes a codegen.Object per Phase 8 §8.4 / amendment v1.1 §8.1:
//!
//!   Header (8 B):   'F','O' | version=1 (1 B) | section count (1 B) |
//!                   symbol count (2 B LE) | reloc count (2 B LE)
//!   Section entry (21 B): name 8 B null-padded | type 1 B |
//!                   payload offset 4 B | size 4 B | load address 4 B
//!   Symbol entry (38 B):  name 32 B null-padded | section 1 B |
//!                   offset 4 B | flags 1 B
//!   Reloc entry (7 B):    offset 4 B | symbol 2 B | type 1 B
//!   Binary payload: raw assembled bytes for each section, contiguous.
//!
//! All multi-byte fields little-endian; the magic is a byte SEQUENCE
//! ('F' then 'O'), not a u16 (§8.4).
//!
//! Implementation decisions (continuing codegen.zig's aa–ai):
//!   (aj) The §8.4 relocation entry has NO SECTION FIELD, yet its offset
//!        is described as "where in the section to patch" — ambiguous the
//!        moment a file has two sections. The only reading that fits the
//!        fixed 7-byte entry is a PAYLOAD-RELATIVE offset: we write
//!        `section.payload_offset + reloc.offset`, and a reader recovers
//!        the (section, offset) pair losslessly from the section table's
//!        own payload offsets. Corollaries: bss sections (type 2) record
//!        their size but occupy ZERO payload bytes — their offset field
//!        holds the current payload cursor so offsets stay monotonic —
//!        and relocations can never point into bss (it has no data).
//!   (ak) Count and name limits are hard errors, not truncations: more
//!        than 255 sections / 65535 symbols / 65535 relocations, or a
//!        symbol name longer than 32 bytes, refuses to serialize. A name
//!        of EXACTLY 32 or 8 bytes is legal and simply has no null
//!        terminator (the fields are fixed-width and count-delimited).

const std = @import("std");
const codegen = @import("codegen");

pub const Error = error{ ObjWrite, OutOfMemory };

pub const header_size: usize = 8;
pub const section_entry_size: usize = 21;
pub const symbol_entry_size: usize = 38;
pub const reloc_entry_size: usize = 7;

/// Serialize `obj` to .flobj v1.1 bytes. On Error.ObjWrite, `err_msg_out`
/// (if non-null) receives a diagnostic allocated in `arena`.
pub fn emit(arena: std.mem.Allocator, obj: *const codegen.Object, err_msg_out: ?*[]const u8) Error![]u8 {
    const fail = struct {
        fn f(a: std.mem.Allocator, out: ?*[]const u8, comptime fmt: []const u8, args: anytype) Error {
            if (out) |p| p.* = std.fmt.allocPrint(a, fmt, args) catch "out of memory formatting diagnostic";
            return Error.ObjWrite;
        }
    }.f;

    if (obj.sections.len > 255)
        return fail(arena, err_msg_out, "{d} sections exceed the 1-byte section count (decision ak)", .{obj.sections.len});
    if (obj.symbols.len > 65535)
        return fail(arena, err_msg_out, "{d} symbols exceed the 2-byte symbol count (decision ak)", .{obj.symbols.len});
    if (obj.relocs.len > 65535)
        return fail(arena, err_msg_out, "{d} relocations exceed the 2-byte reloc count (decision ak)", .{obj.relocs.len});
    for (obj.symbols) |sym| {
        if (sym.name.len > 32)
            return fail(arena, err_msg_out, "symbol name '{s}' exceeds 32 bytes (decision ak)", .{sym.name});
    }

    // Payload offsets: contiguous section data; bss contributes 0 bytes
    // but records the cursor (decision aj).
    const payload_offsets = try arena.alloc(u32, obj.sections.len);
    var payload_size: u32 = 0;
    for (obj.sections, 0..) |sec, i| {
        payload_offsets[i] = payload_size;
        payload_size += @intCast(sec.data.items.len);
    }

    const total = header_size +
        obj.sections.len * section_entry_size +
        obj.symbols.len * symbol_entry_size +
        obj.relocs.len * reloc_entry_size +
        payload_size;

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacityPrecise(arena, total);
    const w = struct {
        fn u8v(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u8) Error!void {
            try l.append(a, v);
        }
        fn u16v(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) Error!void {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, v, .little);
            try l.appendSlice(a, &b);
        }
        fn u32v(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) Error!void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .little);
            try l.appendSlice(a, &b);
        }
        fn padded(l: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, width: usize) Error!void {
            try l.appendSlice(a, name);
            try l.appendNTimes(a, 0, width - name.len);
        }
    };

    // Header.
    try out.appendSlice(arena, "FO"); // magic byte sequence 'F','O'
    try w.u8v(&out, arena, 1); // version
    try w.u8v(&out, arena, @intCast(obj.sections.len));
    try w.u16v(&out, arena, @intCast(obj.symbols.len));
    try w.u16v(&out, arena, @intCast(obj.relocs.len));

    // Section table.
    for (obj.sections, 0..) |sec, i| {
        try out.appendSlice(arena, &sec.name); // already 8 B null-padded
        try w.u8v(&out, arena, @intFromEnum(sec.stype));
        try w.u32v(&out, arena, payload_offsets[i]);
        try w.u32v(&out, arena, sec.size);
        try w.u32v(&out, arena, sec.load_addr);
    }

    // Symbol table.
    for (obj.symbols) |sym| {
        try w.padded(&out, arena, sym.name, 32);
        try w.u8v(&out, arena, sym.section);
        try w.u32v(&out, arena, sym.offset);
        try w.u8v(&out, arena, sym.flags);
    }

    // Relocation table — payload-relative offsets (decision aj).
    for (obj.relocs) |rel| {
        try w.u32v(&out, arena, payload_offsets[rel.section] + rel.offset);
        try w.u16v(&out, arena, rel.symbol);
        try w.u8v(&out, arena, @intFromEnum(rel.rtype));
    }

    // Payload — contiguous; bss writes nothing (decision aj).
    for (obj.sections) |sec| {
        try out.appendSlice(arena, sec.data.items);
    }

    std.debug.assert(out.items.len == total);
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Tests (task 10.9 acceptance: output validates against Phase 8 §8.4).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

test "hello.asm object: header, section entry, symbols, payload placement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const incbins = codegen.IncbinMap.empty;
    const obj = try codegen.assemble(arena,
        \\    ORG $04100
        \\    EQU SYS_PUTSTR, $FC104
        \\start:
        \\    LI    R1, msg
        \\    CALLA SYS_PUTSTR
        \\    HLT
        \\msg:
        \\    DB "HELLO", 0
        \\
    , &incbins);
    const bytes = try emit(arena, &obj, null);

    // Header: 'F','O', version 1, 1 section, 2 symbols, 0 relocs.
    try testing.expectEqualSlices(u8, &.{ 'F', 'O', 1, 1 }, bytes[0..4]);
    try testing.expectEqual(@as(u16, 2), rd16(bytes, 4));
    try testing.expectEqual(@as(u16, 0), rd16(bytes, 6));

    // Section entry at 8: name "abs0", type code=0, payload offset 0,
    // size 18, load $04100.
    try testing.expectEqualStrings("abs0", std.mem.sliceTo(bytes[8..16], 0));
    try testing.expectEqual(@as(u8, 0), bytes[16]);
    try testing.expectEqual(@as(u32, 0), rd32(bytes, 17));
    try testing.expectEqual(@as(u32, 18), rd32(bytes, 21));
    try testing.expectEqual(@as(u32, 0x04100), rd32(bytes, 25));

    // Symbol entries at 8 + 21 = 29: start@0 then msg@12, section 0,
    // flags global=1.
    const sym0 = 29;
    try testing.expectEqualStrings("start", std.mem.sliceTo(bytes[sym0 .. sym0 + 32], 0));
    try testing.expectEqual(@as(u8, 0), bytes[sym0 + 32]);
    try testing.expectEqual(@as(u32, 0), rd32(bytes, sym0 + 33));
    try testing.expectEqual(@as(u8, 1), bytes[sym0 + 37]);
    const sym1 = sym0 + symbol_entry_size;
    try testing.expectEqualStrings("msg", std.mem.sliceTo(bytes[sym1 .. sym1 + 32], 0));
    try testing.expectEqual(@as(u32, 12), rd32(bytes, sym1 + 33));

    // Payload directly after the tables: 8 + 21 + 76 + 0 = 105.
    const payload = sym1 + symbol_entry_size;
    try testing.expectEqual(@as(usize, 105), payload);
    try testing.expectEqual(bytes.len, payload + 18);
    try testing.expectEqualSlices(u8, obj.sections[0].data.items, bytes[payload..]);
    try testing.expectEqualStrings("HELLO\x00", bytes[payload + 12 ..]);
}

test "relocatable object: payload-relative reloc offsets, bss zero payload (decision aj)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const incbins = codegen.IncbinMap.empty;
    const obj = try codegen.assemble(arena,
        \\    SECTION code
        \\start:
        \\    LI   R1, (msg & $FFFF)
        \\    LUI  R1, (msg >> 16)
        \\    CALLA ext_fn
        \\    SECTION data
        \\msg:
        \\    DW msg
        \\    SECTION bss
        \\buf:
        \\    DS 16
        \\
    , &incbins);
    const bytes = try emit(arena, &obj, null);

    // Header: 3 sections, 3 symbols (start, msg, ext_fn... order: start,
    // msg defined; ext_fn external appended in pass 2) + buf = 4 symbols,
    // 4 relocs (LO16, HI4, ABS26, ABS16).
    try testing.expectEqual(@as(u8, 3), bytes[3]);
    try testing.expectEqual(@as(u16, 4), rd16(bytes, 4));
    try testing.expectEqual(@as(u16, 4), rd16(bytes, 6));

    // Section table: code (12 B payload @ 0), data (2 B payload @ 12),
    // bss (0 B payload, cursor offset 12+2=14, size 16, type 2).
    const st = header_size;
    try testing.expectEqual(@as(u32, 0), rd32(bytes, st + 9)); // code payload off
    try testing.expectEqual(@as(u32, 12), rd32(bytes, st + 13)); // code size
    try testing.expectEqual(@as(u32, 0), rd32(bytes, st + 17)); // code load (reloc)
    const st1 = st + section_entry_size;
    try testing.expectEqual(@as(u32, 12), rd32(bytes, st1 + 9)); // data payload off
    try testing.expectEqual(@as(u32, 2), rd32(bytes, st1 + 13));
    const st2 = st1 + section_entry_size;
    try testing.expectEqual(@as(u8, 2), bytes[st2 + 8]); // bss type
    try testing.expectEqual(@as(u32, 14), rd32(bytes, st2 + 9)); // cursor
    try testing.expectEqual(@as(u32, 16), rd32(bytes, st2 + 13)); // bss size

    // Reloc table after 4 symbols: payload-relative offsets.
    const rt = st + 3 * section_entry_size + 4 * symbol_entry_size;
    // LO16 @ code+0 = 0; HI4 @ code+4 = 4; ABS26 @ code+8 = 8;
    // ABS16 @ data+0 = 12 (payload-relative).
    try testing.expectEqual(@as(u32, 0), rd32(bytes, rt));
    try testing.expectEqual(@as(u8, 4), bytes[rt + 6]); // LO16
    try testing.expectEqual(@as(u32, 4), rd32(bytes, rt + reloc_entry_size));
    try testing.expectEqual(@as(u8, 5), bytes[rt + reloc_entry_size + 6]); // HI4
    try testing.expectEqual(@as(u32, 8), rd32(bytes, rt + 2 * reloc_entry_size));
    try testing.expectEqual(@as(u8, 2), bytes[rt + 2 * reloc_entry_size + 6]); // ABS26
    try testing.expectEqual(@as(u32, 12), rd32(bytes, rt + 3 * reloc_entry_size));
    try testing.expectEqual(@as(u8, 0), bytes[rt + 3 * reloc_entry_size + 6]); // ABS16

    // ext_fn symbol carries the external sentinel (decision ae).
    const ext_index = rd16(bytes, rt + 2 * reloc_entry_size + 4);
    const ext_entry = st + 3 * section_entry_size + @as(usize, ext_index) * symbol_entry_size;
    try testing.expectEqualStrings("ext_fn", std.mem.sliceTo(bytes[ext_entry .. ext_entry + 32], 0));
    try testing.expectEqual(codegen.external_section, bytes[ext_entry + 32]);

    // Total size: tables + 14 payload bytes (bss contributes none).
    try testing.expectEqual(rt + 4 * reloc_entry_size + 14, bytes.len);
}

test "limits: symbol name over 32 bytes refuses to serialize (decision ak)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const incbins = codegen.IncbinMap.empty;
    const obj = try codegen.assemble(arena,
        \\ORG $100
        \\a123456789012345678901234567890123:
        \\    NOP
        \\
    , &incbins);
    var msg: []const u8 = "";
    try testing.expectError(Error.ObjWrite, emit(arena, &obj, &msg));
    try testing.expect(std.mem.indexOf(u8, msg, "exceeds 32 bytes") != null);
}
