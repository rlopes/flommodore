//! fll resolver — section placement and cross-object symbol resolution
//! (Block 11, tasks 11.2 and 11.3).
//!
//! Consumes loaded objects plus the parsed linker script and produces the
//! final memory layout: merged output sections at resolved addresses,
//! per-input-piece placement (for the relocator), the global symbol
//! table with final addresses, and the resolved entry point. Undefined
//! and duplicate symbols are reported with file context (task 11.3) —
//! ALL undefined symbols are listed before failing, not just the first.
//!
//! Implementation decisions (continuing script.zig's ar–as):
//!   (at) The `code` rule must be the FIRST rule and must use AT: its
//!        value is the FILE load address (decision ap), so the code
//!        section's memory base is AT + 12 (the .flapp header size).
//!        Every other AT names a literal memory address; AFTER places a
//!        section at the previous one's end. Rule order must equal
//!        memory order — a placement that goes backward or overlaps is
//!        an error (the .flapp payload is one contiguous, forward image;
//!        gaps between initialized sections zero-fill at emission).
//!   (au) Same-named sections from multiple objects concatenate in input
//!        order. Contributions to CODE-type sections are padded to
//!        4-byte alignment with zeros (Gab-16 instructions are 4-byte);
//!        data and bss concatenate unpadded.
//!   (av) Every non-empty input section must match a script rule (error
//!        naming the object and section); an object may lack a scripted
//!        section. Absolute objects (any section with a load address)
//!        are rejected here — they are --raw mode's input (amendment
//!        §8.5).
//!   (aw) Relocations against symbols DEFINED in their own object
//!        resolve internally (local symbols stay object-private, so two
//!        objects' macro labels can never collide); only external
//!        ($FF-section) references consult the global table, which
//!        contains flag-1 globals exclusively. The .flsym list is those
//!        globals, sorted by final address.

const std = @import("std");
const loader = @import("loader");
const script = @import("script");

pub const Error = error{ Resolve, OutOfMemory };

/// Keep in sync with flapp.header_size — asserted in the tests below.
/// Hardcoded so the fll binary does not link the whole machine stack.
pub const flapp_header_size: u32 = 12;

pub const OutSection = struct {
    name: []const u8,
    stype: loader.SectionType,
    base: u32, // final memory address
    size: u32, // total, including inter-piece padding
    data: []u8, // initialized bytes; empty for bss
};

/// Where one input section landed: output section index + offset within.
pub const Piece = struct { out: u8, off: u32 };

pub const SymbolAddr = struct { name: []const u8, addr: u32 };

pub const Link = struct {
    load_addr: u32, // file load address (code AT — decisions ap/at)
    entry_addr: u32,
    version: u16,
    min_ram_kb: u16,
    out: []OutSection, // rule order == memory order (decision at)
    pieces: [][]Piece, // [object index][input section index]
    globals: std.StringHashMapUnmanaged(u32),
    symbols: []SymbolAddr, // globals sorted by address (for .flsym)

    /// Final memory address of `sym_index` in object `obj_index`
    /// (decision aw). Defined symbols resolve through their piece;
    /// externals through the global table. Only valid after resolve()
    /// succeeded, so externals are guaranteed present.
    pub fn symbolAddress(l: *const Link, objs: []const loader.Object, obj_index: usize, sym_index: u16) u32 {
        const sym = objs[obj_index].symbols[sym_index];
        if (sym.section == loader.external_section)
            return l.globals.get(sym.name).?; // checked during resolve
        const piece = l.pieces[obj_index][sym.section];
        return l.out[piece.out].base + piece.off + sym.offset;
    }
};

pub fn resolve(
    arena: std.mem.Allocator,
    objs: []const loader.Object,
    scr: script.Script,
    err_msg_out: ?*[]const u8,
) Error!Link {
    const fail = struct {
        fn f(a: std.mem.Allocator, out: ?*[]const u8, comptime fmt: []const u8, args: anytype) Error {
            if (out) |dst| {
                dst.* = std.fmt.allocPrint(a, fmt, args) catch "out of memory formatting diagnostic";
            }
            return Error.Resolve;
        }
    }.f;

    if (objs.len == 0)
        return fail(arena, err_msg_out, "no input objects", .{});

    // Absolute objects are --raw's input, not the script linker's
    // (decision av / amendment §8.5).
    for (objs) |obj| {
        for (obj.sections) |sec| {
            if (sec.load_addr != 0)
                return fail(arena, err_msg_out, "{s}: absolute object (section '{s}' at ${X:0>5}) — use --raw mode", .{ obj.path, sec.name, sec.load_addr });
        }
    }

    // The code rule anchors the file (decision at).
    if (scr.rules.len == 0 or !std.mem.eql(u8, scr.rules[0].name, "code") or scr.rules[0].placement != .at)
        return fail(arena, err_msg_out, "the first script rule must be 'SECTION code AT $addr' (decision at)", .{});
    const load_addr = scr.rules[0].placement.at;

    // Every non-empty input section needs a rule (decision av).
    for (objs) |obj| {
        next_section: for (obj.sections) |sec| {
            if (sec.size == 0) continue;
            for (scr.rules) |r| {
                if (std.mem.eql(u8, r.name, sec.name)) continue :next_section;
            }
            return fail(arena, err_msg_out, "{s}: section '{s}' has no placement rule in the linker script", .{ obj.path, sec.name });
        }
    }

    // Placement + piece assignment, one rule at a time (decision au).
    const out = try arena.alloc(OutSection, scr.rules.len);
    const pieces = try arena.alloc([]Piece, objs.len);
    for (pieces, 0..) |*pp, i| {
        pp.* = try arena.alloc(Piece, objs[i].sections.len);
        @memset(pp.*, .{ .out = 0, .off = 0 });
    }

    var prev_end: u32 = 0;
    for (scr.rules, 0..) |rule, ri| {
        var stype: ?loader.SectionType = null;
        var size: u32 = 0;
        for (objs, 0..) |obj, oi| {
            for (obj.sections, 0..) |sec, si| {
                if (!std.mem.eql(u8, sec.name, rule.name)) continue;
                if (stype == null) stype = sec.stype;
                if (stype.? != sec.stype)
                    return fail(arena, err_msg_out, "{s}: section '{s}' type conflicts with an earlier object", .{ obj.path, sec.name });
                if (stype.? == .code) size = std.mem.alignForward(u32, size, 4); // decision au
                pieces[oi][si] = .{ .out = @intCast(ri), .off = size };
                size += sec.size;
            }
        }

        const base: u32 = switch (rule.placement) {
            .at => |at| if (ri == 0) at + flapp_header_size else at, // decision at
            .after => |target| blk: {
                for (out[0..ri]) |o| {
                    if (std.mem.eql(u8, o.name, target))
                        break :blk o.base + o.size;
                }
                unreachable; // script.parse enforced define-before-use
            },
        };
        if (ri > 0 and base < prev_end)
            return fail(arena, err_msg_out, "section '{s}' at ${X:0>5} overlaps the previous section (ends ${X:0>5}) — rule order must be memory order (decision at)", .{ rule.name, base, prev_end });

        const data = if (stype orelse .code != .bss) try arena.alloc(u8, size) else &[_]u8{};
        @memset(@constCast(data), 0);
        out[ri] = .{
            .name = rule.name,
            .stype = stype orelse .code,
            .base = base,
            .size = size,
            .data = @constCast(data),
        };
        prev_end = base + size;
    }

    // Copy payloads into place (padding stays zero).
    for (objs, 0..) |obj, oi| {
        for (obj.sections, 0..) |sec, si| {
            if (sec.payload.len == 0) continue;
            const piece = pieces[oi][si];
            @memcpy(out[piece.out].data[piece.off..][0..sec.payload.len], sec.payload);
        }
    }

    // Global symbol table with duplicate detection (tasks 11.2/11.3).
    var globals: std.StringHashMapUnmanaged(u32) = .empty;
    var owners: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (objs, 0..) |obj, oi| {
        for (obj.symbols) |sym| {
            if (sym.flags != 1 or sym.section == loader.external_section) continue;
            const piece = pieces[oi][sym.section];
            const addr = out[piece.out].base + piece.off + sym.offset;
            const gop = try globals.getOrPut(arena, sym.name);
            if (gop.found_existing)
                return fail(arena, err_msg_out, "duplicate global symbol '{s}': defined in {s} and {s}", .{ sym.name, owners.get(sym.name).?, obj.path });
            gop.value_ptr.* = addr;
            try owners.put(arena, sym.name, obj.path);
        }
    }

    // Undefined-reference scan: report ALL of them (task 11.3).
    {
        var missing: std.ArrayList(u8) = .empty;
        var reported: std.StringHashMapUnmanaged(void) = .empty;
        for (objs) |obj| {
            for (obj.relocs) |rel| {
                const sym = obj.symbols[rel.symbol];
                if (sym.section != loader.external_section) continue;
                if (globals.contains(sym.name)) continue;
                const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ sym.name, obj.path });
                if ((try reported.getOrPut(arena, key)).found_existing) continue;
                try missing.appendSlice(arena, try std.fmt.allocPrint(arena, "\n  undefined symbol '{s}' referenced from {s}", .{ sym.name, obj.path }));
            }
        }
        if (missing.items.len > 0)
            return fail(arena, err_msg_out, "unresolved references:{s}", .{missing.items});
    }

    // Entry point.
    const entry_name = scr.entry orelse
        return fail(arena, err_msg_out, "linker script has no ENTRY statement", .{});
    const entry_addr = globals.get(entry_name) orelse
        return fail(arena, err_msg_out, "ENTRY symbol '{s}' is not defined by any input object", .{entry_name});

    // Sorted global list for .flsym (decision aw).
    var syms: std.ArrayList(SymbolAddr) = .empty;
    var it = globals.iterator();
    while (it.next()) |kv| {
        try syms.append(arena, .{ .name = kv.key_ptr.*, .addr = kv.value_ptr.* });
    }
    const sorted = try syms.toOwnedSlice(arena);
    std.mem.sort(SymbolAddr, sorted, {}, struct {
        fn lt(_: void, a: SymbolAddr, b: SymbolAddr) bool {
            if (a.addr != b.addr) return a.addr < b.addr;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    return .{
        .load_addr = load_addr,
        .entry_addr = entry_addr,
        .version = scr.version,
        .min_ram_kb = scr.min_ram_kb,
        .out = out,
        .pieces = pieces,
        .globals = globals,
        .symbols = sorted,
    };
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const testing = std.testing;
const codegen = @import("codegen");
const objfile = @import("objfile");
const flapp = @import("flapp");

test "flapp_header_size matches the loader's ground truth" {
    try testing.expectEqual(flapp.header_size, flapp_header_size);
}

fn makeObj(arena: std.mem.Allocator, path: []const u8, src: []const u8) !loader.Object {
    const incbins = codegen.IncbinMap.empty;
    const o = try codegen.assemble(arena, src, &incbins);
    const bytes = try objfile.emit(arena, &o, null);
    return loader.load(arena, path, bytes, null);
}

const example_script =
    \\ENTRY start
    \\SECTION code AT $04100
    \\SECTION data AFTER code
    \\SECTION bss  AFTER data
    \\
;

test "two-object link: placement, merge padding, symbols, entry (tasks 11.2/11.3)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // a: 2 instructions + 1 stray byte of code (tests decision au padding),
    //    4 bytes of data, 8 bytes of bss.
    const a = try makeObj(arena, "a.flobj",
        \\    SECTION code
        \\start:
        \\    CALLA helper
        \\    HLT
        \\    DB 1
        \\    SECTION data
        \\msg:
        \\    DD msg
        \\    SECTION bss
        \\buf_a:
        \\    DS 8
        \\
    );
    // b: helper + its own data and bss.
    const b = try makeObj(arena, "b.flobj",
        \\    SECTION code
        \\helper:
        \\    RET
        \\    SECTION data
        \\tab:
        \\    DW tab
        \\    SECTION bss
        \\buf_b:
        \\    DS 4
        \\
    );

    var msg: []const u8 = "";
    const scr = try script.parse(arena, "t.flld", example_script, &msg);
    const objs = [_]loader.Object{ a, b };
    const link = try resolve(arena, &objs, scr, &msg);

    // Layout (decision at): file at $04100, code base $0410C.
    try testing.expectEqual(@as(u32, 0x04100), link.load_addr);
    try testing.expectEqual(@as(u32, 0x0410C), link.out[0].base);
    // a.code = 9 bytes, padded to 12 for b's piece (decision au); +4 = 16.
    try testing.expectEqual(@as(u32, 16), link.out[0].size);
    try testing.expectEqual(Piece{ .out = 0, .off = 12 }, link.pieces[1][0]);
    // data AFTER code: base $0410C + 16 = $0411C, size 6 (unpadded).
    try testing.expectEqual(@as(u32, 0x0411C), link.out[1].base);
    try testing.expectEqual(@as(u32, 6), link.out[1].size);
    // bss AFTER data: $04122, size 12, no data.
    try testing.expectEqual(@as(u32, 0x04122), link.out[2].base);
    try testing.expectEqual(@as(u32, 12), link.out[2].size);
    try testing.expectEqual(@as(usize, 0), link.out[2].data.len);

    // Symbols (sorted by address): start, helper, msg, tab, buf_a, buf_b.
    try testing.expectEqual(@as(usize, 6), link.symbols.len);
    try testing.expectEqualStrings("start", link.symbols[0].name);
    try testing.expectEqual(@as(u32, 0x0410C), link.symbols[0].addr);
    try testing.expectEqualStrings("helper", link.symbols[1].name);
    try testing.expectEqual(@as(u32, 0x0410C + 12), link.symbols[1].addr);
    try testing.expectEqualStrings("msg", link.symbols[2].name);
    try testing.expectEqual(@as(u32, 0x0411C), link.symbols[2].addr);
    try testing.expectEqualStrings("tab", link.symbols[3].name);
    try testing.expectEqual(@as(u32, 0x0411C + 4), link.symbols[3].addr);
    try testing.expectEqualStrings("buf_a", link.symbols[4].name);
    try testing.expectEqual(@as(u32, 0x04122), link.symbols[4].addr);
    try testing.expectEqualStrings("buf_b", link.symbols[5].name);
    try testing.expectEqual(@as(u32, 0x04122 + 8), link.symbols[5].addr);

    try testing.expectEqual(@as(u32, 0x0410C), link.entry_addr);

    // symbolAddress resolves a's external 'helper' through the globals
    // and b's own defined symbols directly (decision aw).
    for (a.symbols, 0..) |s, i| {
        if (std.mem.eql(u8, s.name, "helper"))
            try testing.expectEqual(@as(u32, 0x04118), link.symbolAddress(&objs, 0, @intCast(i)));
    }

    // Payload copied with padding intact: a's DB 1 at code offset 8,
    // b's RET at offset 12; padding bytes 9..11 are zero. RET encodes as
    // $B0000000, so its LE bytes are 00 00 00 B0 — check the high byte.
    try testing.expectEqual(@as(u8, 1), link.out[0].data[8]);
    try testing.expectEqual(@as(u8, 0), link.out[0].data[9]);
    try testing.expectEqual(@as(u8, 0xB0), link.out[0].data[15]);
}

test "resolver errors: undefined (all listed), duplicates, coverage, absolute input" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msg: []const u8 = "";
    const scr = try script.parse(arena, "t.flld", example_script, &msg);

    // ALL undefined symbols reported, with file context (task 11.3).
    {
        const a = try makeObj(arena, "a.flobj",
            \\    SECTION code
            \\start:
            \\    CALLA missing_one
            \\    JMPA  missing_two
            \\
        );
        const objs = [_]loader.Object{a};
        try testing.expectError(Error.Resolve, resolve(arena, &objs, scr, &msg));
        try testing.expect(std.mem.indexOf(u8, msg, "'missing_one' referenced from a.flobj") != null);
        try testing.expect(std.mem.indexOf(u8, msg, "'missing_two' referenced from a.flobj") != null);
    }

    // Duplicate globals name both files.
    {
        const a = try makeObj(arena, "a.flobj", "    SECTION code\ndup:\n    NOP\n");
        const b = try makeObj(arena, "b.flobj", "    SECTION code\ndup:\n    NOP\n");
        const objs = [_]loader.Object{ a, b };
        try testing.expectError(Error.Resolve, resolve(arena, &objs, scr, &msg));
        try testing.expect(std.mem.indexOf(u8, msg, "duplicate global symbol 'dup'") != null);
        try testing.expect(std.mem.indexOf(u8, msg, "a.flobj") != null);
        try testing.expect(std.mem.indexOf(u8, msg, "b.flobj") != null);
    }

    // ENTRY symbol absent.
    {
        const a = try makeObj(arena, "a.flobj", "    SECTION code\nmain:\n    NOP\n");
        const objs = [_]loader.Object{a};
        try testing.expectError(Error.Resolve, resolve(arena, &objs, scr, &msg));
        try testing.expect(std.mem.indexOf(u8, msg, "ENTRY symbol 'start'") != null);
    }

    // Absolute object rejected (decision av).
    {
        const a = try makeObj(arena, "rom.flobj", "    ORG $FC200\n    NOP\n");
        const objs = [_]loader.Object{a};
        try testing.expectError(Error.Resolve, resolve(arena, &objs, scr, &msg));
        try testing.expect(std.mem.indexOf(u8, msg, "use --raw") != null);
    }

    // First rule must be code AT (decision at).
    {
        const bad = try script.parse(arena, "b.flld", "ENTRY s\nSECTION data AT $100\n", &msg);
        const a = try makeObj(arena, "a.flobj", "    SECTION code\ns:\n    NOP\n");
        const objs = [_]loader.Object{a};
        try testing.expectError(Error.Resolve, resolve(arena, &objs, bad, &msg));
        try testing.expect(std.mem.indexOf(u8, msg, "SECTION code AT") != null);
    }
}
