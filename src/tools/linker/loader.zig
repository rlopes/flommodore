//! fll loader — read and validate .flobj v1.1 files (Block 11, task 11.1).
//!
//! Parses the format written by the assembler's objfile.zig (Phase 8 §8.4
//! / amendment §8.1) back into structured form, enforcing every layout
//! invariant so later stages can trust their inputs. Mirrors the writer's
//! decisions: reloc offsets are PAYLOAD-RELATIVE (objfile decision aj) and
//! are mapped back to (section, offset) pairs here; bss sections occupy
//! zero payload bytes; 8/32-byte names may lack a null terminator
//! (decision ak).
//!
//! Implementation decisions (continuing the assembler's al–ao):
//!   (ap) `SECTION code AT $X` in a linker script names the FILE load
//!        address: flapp.load copies the whole image (header included)
//!        verbatim to X, so the code section physically lands at X + 12
//!        and symbols resolve against X + 12. Ground truth: genroms'
//!        test_prog.flapp ("entry at load+12", JMPA $0410C for a $04100
//!        file). Recorded here because it shapes every later stage.
//!   (aq) Loader validation is exhaustive and eager: a reloc must land
//!        inside a non-bss section with room for its patch width (2 bytes
//!        for ABS16, 4 for the rest); symbol section indices must be
//!        valid or the $FF external sentinel; payload extents must lie
//!        inside the file. Diagnostics carry the file path (task 11.3
//!        groundwork).

const std = @import("std");

pub const Error = error{ ObjLoad, OutOfMemory };

pub const SectionType = enum(u8) { code = 0, data = 1, bss = 2 };

pub const external_section: u8 = 0xFF;

pub const RelocType = enum(u8) {
    abs16 = 0,
    abs32 = 1,
    abs26 = 2,
    pcrel26 = 3,
    lo16 = 4,
    hi4 = 5,

    /// Bytes rewritten at the patch site (decision aq).
    pub fn patchWidth(t: RelocType) u32 {
        return switch (t) {
            .abs16 => 2,
            else => 4,
        };
    }
};

pub const Section = struct {
    name: []const u8,
    stype: SectionType,
    load_addr: u32, // 0 = relocatable
    size: u32, // includes bss size
    payload: []const u8, // empty for bss
};

pub const Symbol = struct {
    name: []const u8,
    section: u8, // $FF = external/undefined
    offset: u32,
    flags: u8, // global=1, local=0
};

pub const Reloc = struct {
    section: u8, // patch-site section (recovered from payload offsets)
    offset: u32, // offset within that section
    symbol: u16,
    rtype: RelocType,
};

pub const Object = struct {
    path: []const u8, // diagnostics (task 11.3)
    sections: []Section,
    symbols: []Symbol,
    relocs: []Reloc,
};

const header_size: usize = 8;
const section_entry_size: usize = 21;
const symbol_entry_size: usize = 38;
const reloc_entry_size: usize = 7;

/// Fixed-width name field: null-terminated unless it fills the field
/// exactly (objfile decision ak).
fn nameOf(field: []const u8) []const u8 {
    return std.mem.sliceTo(field, 0);
}

/// Parse `bytes` (the full file) into an Object. All returned slices are
/// arena-owned copies; `bytes` may be freed afterwards. On Error.ObjLoad,
/// `err_msg_out` (if non-null) receives an arena-allocated diagnostic
/// beginning with `path`.
pub fn load(arena: std.mem.Allocator, path: []const u8, bytes: []const u8, err_msg_out: ?*[]const u8) Error!Object {
    const fail = struct {
        fn f(a: std.mem.Allocator, out: ?*[]const u8, p: []const u8, comptime fmt: []const u8, args: anytype) Error {
            if (out) |dst| {
                dst.* = std.fmt.allocPrint(a, "{s}: " ++ fmt, .{p} ++ args) catch "out of memory formatting diagnostic";
            }
            return Error.ObjLoad;
        }
    }.f;

    if (bytes.len < header_size)
        return fail(arena, err_msg_out, path, "file too short for a .flobj header ({d} bytes)", .{bytes.len});
    if (bytes[0] != 'F' or bytes[1] != 'O')
        return fail(arena, err_msg_out, path, "bad magic — not a .flobj file", .{});
    if (bytes[2] != 1)
        return fail(arena, err_msg_out, path, "unsupported .flobj version {d} (this linker reads v1)", .{bytes[2]});

    const nsec: usize = bytes[3];
    const nsym: usize = std.mem.readInt(u16, bytes[4..6], .little);
    const nrel: usize = std.mem.readInt(u16, bytes[6..8], .little);
    const payload_base = header_size + nsec * section_entry_size + nsym * symbol_entry_size + nrel * reloc_entry_size;
    if (bytes.len < payload_base)
        return fail(arena, err_msg_out, path, "file truncated: tables need {d} bytes, file has {d}", .{ payload_base, bytes.len });
    const payload = bytes[payload_base..];

    // Section table. Payload extents are tracked to (a) validate them and
    // (b) map payload-relative reloc offsets back to sections (aj/aq).
    const sections = try arena.alloc(Section, nsec);
    const payload_starts = try arena.alloc(u32, nsec); // per-section payload cursor
    var cursor: u32 = 0;
    for (sections, 0..) |*sec, i| {
        const e = bytes[header_size + i * section_entry_size ..][0..section_entry_size];
        const stype_raw = e[8];
        if (stype_raw > 2)
            return fail(arena, err_msg_out, path, "section {d} has invalid type {d}", .{ i, stype_raw });
        const stype: SectionType = @enumFromInt(stype_raw);
        const poff = std.mem.readInt(u32, e[9..13], .little);
        const size = std.mem.readInt(u32, e[13..17], .little);
        const load_addr = std.mem.readInt(u32, e[17..21], .little);
        const payload_len: u32 = if (stype == .bss) 0 else size;
        if (poff != cursor)
            return fail(arena, err_msg_out, path, "section {d} payload offset {d} breaks the contiguous layout (expected {d})", .{ i, poff, cursor });
        if (@as(u64, poff) + payload_len > payload.len)
            return fail(arena, err_msg_out, path, "section {d} payload [{d}..{d}] exceeds the file", .{ i, poff, poff + payload_len });
        sec.* = .{
            .name = try arena.dupe(u8, nameOf(e[0..8])),
            .stype = stype,
            .load_addr = load_addr,
            .size = size,
            .payload = try arena.dupe(u8, payload[poff..][0..payload_len]),
        };
        payload_starts[i] = cursor;
        cursor += payload_len;
    }

    // Symbol table.
    const symbols = try arena.alloc(Symbol, nsym);
    for (symbols, 0..) |*sym, i| {
        const e = bytes[header_size + nsec * section_entry_size + i * symbol_entry_size ..][0..symbol_entry_size];
        const section = e[32];
        if (section != external_section and section >= nsec)
            return fail(arena, err_msg_out, path, "symbol {d} references section {d} of {d}", .{ i, section, nsec });
        sym.* = .{
            .name = try arena.dupe(u8, nameOf(e[0..32])),
            .section = section,
            .offset = std.mem.readInt(u32, e[33..37], .little),
            .flags = e[37],
        };
    }

    // Relocation table: payload-relative offsets → (section, offset).
    const relocs = try arena.alloc(Reloc, nrel);
    const reloc_base = header_size + nsec * section_entry_size + nsym * symbol_entry_size;
    for (relocs, 0..) |*rel, i| {
        const e = bytes[reloc_base + i * reloc_entry_size ..][0..reloc_entry_size];
        const off = std.mem.readInt(u32, e[0..4], .little);
        const symbol = std.mem.readInt(u16, e[4..6], .little);
        const rtype_raw = e[6];
        if (rtype_raw > 5)
            return fail(arena, err_msg_out, path, "relocation {d} has invalid type {d}", .{ i, rtype_raw });
        const rtype: RelocType = @enumFromInt(rtype_raw);
        if (symbol >= nsym)
            return fail(arena, err_msg_out, path, "relocation {d} references symbol {d} of {d}", .{ i, symbol, nsym });
        // Find the (non-bss) section containing this payload offset with
        // room for the patch (decision aq).
        const found: ?usize = blk: {
            for (sections, 0..) |sec, s| {
                if (sec.stype == .bss) continue;
                const start = payload_starts[s];
                if (off >= start and off + rtype.patchWidth() <= start + sec.payload.len)
                    break :blk s;
            }
            break :blk null;
        };
        const s = found orelse
            return fail(arena, err_msg_out, path, "relocation {d} at payload offset {d} does not fall inside any initialized section", .{ i, off });
        rel.* = .{
            .section = @intCast(s),
            .offset = off - payload_starts[s],
            .symbol = symbol,
            .rtype = rtype,
        };
    }

    return .{
        .path = try arena.dupe(u8, path),
        .sections = sections,
        .symbols = symbols,
        .relocs = relocs,
    };
}

// ---------------------------------------------------------------------------
// Tests — round-trips through the assembler's writer (the two sides of
// §8.4 must agree byte for byte).
// ---------------------------------------------------------------------------

const testing = std.testing;
const codegen = @import("codegen");
const objfile = @import("objfile");

fn assembleToBytes(arena: std.mem.Allocator, src: []const u8) ![]u8 {
    const incbins = codegen.IncbinMap.empty;
    const obj = try codegen.assemble(arena, src, &incbins);
    return objfile.emit(arena, &obj, null);
}

test "round-trip: relocatable three-section object survives write/load" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try assembleToBytes(arena,
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
    );
    const obj = try load(arena, "three.flobj", bytes, null);

    try testing.expectEqual(@as(usize, 3), obj.sections.len);
    try testing.expectEqualStrings("code", obj.sections[0].name);
    try testing.expectEqual(SectionType.code, obj.sections[0].stype);
    try testing.expectEqual(@as(usize, 12), obj.sections[0].payload.len);
    try testing.expectEqualStrings("data", obj.sections[1].name);
    try testing.expectEqual(@as(usize, 2), obj.sections[1].payload.len);
    try testing.expectEqualStrings("bss", obj.sections[2].name);
    try testing.expectEqual(SectionType.bss, obj.sections[2].stype);
    try testing.expectEqual(@as(u32, 16), obj.sections[2].size);
    try testing.expectEqual(@as(usize, 0), obj.sections[2].payload.len);

    // Relocs mapped back to (section, offset): LO16@code+0, HI4@code+4,
    // ABS26@code+8, ABS16@data+0.
    try testing.expectEqual(@as(usize, 4), obj.relocs.len);
    try testing.expectEqual(RelocType.lo16, obj.relocs[0].rtype);
    try testing.expectEqual(@as(u8, 0), obj.relocs[0].section);
    try testing.expectEqual(@as(u32, 0), obj.relocs[0].offset);
    try testing.expectEqual(RelocType.hi4, obj.relocs[1].rtype);
    try testing.expectEqual(@as(u32, 4), obj.relocs[1].offset);
    try testing.expectEqual(RelocType.abs26, obj.relocs[2].rtype);
    try testing.expectEqual(@as(u32, 8), obj.relocs[2].offset);
    try testing.expectEqual(RelocType.abs16, obj.relocs[3].rtype);
    try testing.expectEqual(@as(u8, 1), obj.relocs[3].section);
    try testing.expectEqual(@as(u32, 0), obj.relocs[3].offset);

    // Symbols: msg is section-relative in data; ext_fn is external.
    var saw_msg = false;
    var saw_ext = false;
    for (obj.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "msg")) {
            try testing.expectEqual(@as(u8, 1), sym.section);
            saw_msg = true;
        }
        if (std.mem.eql(u8, sym.name, "ext_fn")) {
            try testing.expectEqual(external_section, sym.section);
            saw_ext = true;
        }
    }
    try testing.expect(saw_msg and saw_ext);
}

test "round-trip: absolute object (multiple ORG sections)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try assembleToBytes(arena,
        \\    ORG $FC200
        \\start:
        \\    NOP
        \\    HLT
        \\    ORG $FFFC0
        \\    DD start
        \\
    );
    const obj = try load(arena, "abs.flobj", bytes, null);
    try testing.expectEqual(@as(usize, 2), obj.sections.len);
    try testing.expectEqual(@as(u32, 0xFC200), obj.sections[0].load_addr);
    try testing.expectEqual(@as(u32, 0xFFFC0), obj.sections[1].load_addr);
    try testing.expectEqual(@as(usize, 0), obj.relocs.len);
    // Payload content survives: DD start = $FC200 LE.
    try testing.expectEqual(@as(u32, 0xFC200), std.mem.readInt(u32, obj.sections[1].payload[0..4], .little));
}

test "invalid files error clearly (task 11.1 acceptance)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msg: []const u8 = "";

    // Bad magic.
    try testing.expectError(Error.ObjLoad, load(arena, "x.flobj", "XX\x01\x00\x00\x00\x00\x00", &msg));
    try testing.expect(std.mem.indexOf(u8, msg, "x.flobj: bad magic") != null);

    // Truncated header.
    try testing.expectError(Error.ObjLoad, load(arena, "t.flobj", "FO", &msg));
    try testing.expect(std.mem.indexOf(u8, msg, "too short") != null);

    // Unsupported version.
    try testing.expectError(Error.ObjLoad, load(arena, "v.flobj", "FO\x02\x00\x00\x00\x00\x00", &msg));
    try testing.expect(std.mem.indexOf(u8, msg, "version 2") != null);

    // Header promises tables the file doesn't contain.
    try testing.expectError(Error.ObjLoad, load(arena, "s.flobj", "FO\x01\x05\x00\x00\x00\x00", &msg));
    try testing.expect(std.mem.indexOf(u8, msg, "truncated") != null);

    // Corrupt a valid object: point a reloc at a bogus payload offset.
    const bytes = try assembleToBytes(arena,
        \\    SECTION code
        \\    CALLA ext
        \\
    );
    const mutable = try arena.dupe(u8, bytes);
    const reloc_base = 8 + 1 * 21 + 1 * 38;
    std.mem.writeInt(u32, mutable[reloc_base..][0..4], 999, .little);
    try testing.expectError(Error.ObjLoad, load(arena, "r.flobj", mutable, &msg));
    try testing.expect(std.mem.indexOf(u8, msg, "does not fall inside") != null);

    // Corrupt the reloc type.
    const mutable2 = try arena.dupe(u8, bytes);
    mutable2[reloc_base + 6] = 9;
    try testing.expectError(Error.ObjLoad, load(arena, "r2.flobj", mutable2, &msg));
    try testing.expect(std.mem.indexOf(u8, msg, "invalid type 9") != null);
}
