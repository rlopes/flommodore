//! fll emitter — .flapp, .flsym, and raw ROM images (Block 11, tasks
//! 11.6, 11.7, 11.8, and 11.10).
//!
//! Implementation decisions (continuing relocator.zig's ax–ay):
//!   (az) The .flapp payload spans from the code base (load address +
//!        12) to the end of the LAST initialized section; gaps between
//!        initialized sections (data placed with AT beyond code's end)
//!        are zero-filled, and bss beyond the last initialized byte
//!        costs no file bytes. The 12-byte header is written locally so
//!        the fll binary does not link the machine stack — its layout is
//!        cross-checked byte-for-byte against flapp.writeHeader in the
//!        tests. Emission validates what flapp.load would reject:
//!        entry inside the image, min RAM ≤ 512 KB, 20-bit load address.
//!   (ba) Raw mode (amendment §8.6) takes ABSOLUTE objects only: every
//!        non-empty section needs a nonzero load address (ORG $0 is not
//!        representable). Sections must fit [base, base+size) without
//!        overlapping each other, and the image must cover the vector
//!        slots $FFFC0–$FFFCF with at least one nonzero byte among the
//!        16 — an all-zero vector region is the spec's "empty" failure.

const std = @import("std");
const loader = @import("loader");
const resolver = @import("resolver");

pub const Error = error{ Emit, OutOfMemory };

const header_size: u32 = resolver.flapp_header_size; // 12

fn fail(arena: std.mem.Allocator, out: ?*[]const u8, comptime fmt: []const u8, args: anytype) Error {
    if (out) |dst| {
        dst.* = std.fmt.allocPrint(arena, fmt, args) catch "out of memory formatting diagnostic";
    }
    return Error.Emit;
}

/// Serialize the finished (relocated) link as a .flapp image (tasks
/// 11.6/11.7). Layout per §8.6, validated per decision az.
pub fn emitFlapp(arena: std.mem.Allocator, link: *const resolver.Link, err_msg_out: ?*[]const u8) Error![]u8 {
    if (link.load_addr > 0xFFFFF)
        return fail(arena, err_msg_out, "load address ${X} does not fit the 20-bit bus", .{link.load_addr});
    if (@as(u32, link.min_ram_kb) > 512)
        return fail(arena, err_msg_out, "MINRAM {d} KB exceeds the machine's 512 KB", .{link.min_ram_kb});

    // Payload extent (decision az): code base .. last initialized end.
    const payload_start = link.load_addr + header_size; // == out[0].base (decision at)
    var payload_end = payload_start;
    for (link.out) |o| {
        if (o.stype == .bss or o.size == 0) continue;
        payload_end = @max(payload_end, o.base + o.size);
    }
    const total: u32 = header_size + (payload_end - payload_start);

    const entry_rel = link.entry_addr -% link.load_addr;
    if (link.entry_addr < payload_start or entry_rel >= total)
        return fail(arena, err_msg_out, "entry point ${X:0>5} lies outside the initialized image (${X:0>5}..${X:0>5}) — is ENTRY a bss symbol?", .{ link.entry_addr, payload_start, payload_end });
    if (entry_rel > 0xFFFF)
        return fail(arena, err_msg_out, "entry offset {d} does not fit the 16-bit header field", .{entry_rel});

    const buf = try arena.alloc(u8, total);
    @memset(buf, 0);
    // 12-byte autoboot header (§8.6; cross-checked against
    // flapp.writeHeader in the tests — decision az).
    buf[0] = 'F';
    buf[1] = 'B';
    std.mem.writeInt(u16, buf[2..4], link.version, .little);
    std.mem.writeInt(u16, buf[4..6], @intCast(entry_rel), .little);
    std.mem.writeInt(u16, buf[6..8], link.min_ram_kb, .little);
    std.mem.writeInt(u32, buf[8..12], link.load_addr, .little);

    for (link.out) |o| {
        if (o.stype == .bss or o.size == 0) continue;
        @memcpy(buf[header_size + (o.base - payload_start) ..][0..o.data.len], o.data);
    }
    return buf;
}

/// Serialize the symbol file (task 11.8): one `$AAAAA  name` line per
/// global, sorted by address (§8.7, resolver decision aw).
pub fn emitFlsym(arena: std.mem.Allocator, link: *const resolver.Link) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (link.symbols) |s| {
        var buf: [8]u8 = undefined;
        const a = std.fmt.bufPrint(&buf, "${X:0>5}", .{s.addr}) catch unreachable;
        try out.appendSlice(arena, a);
        try out.appendSlice(arena, "  ");
        try out.appendSlice(arena, s.name);
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

pub const vector_base: u32 = 0xFFFC0;
pub const vector_len: u32 = 16;

/// Raw padded image (task 11.10, amendment §8.6): absolute inputs
/// placed at (load − base), zero-padded to `size`, no header. Enforces
/// decision ba: bounds, overlap, and — for ROM images — non-empty
/// vector slots. `require_vectors=false` is the --overlay mode
/// (DECISION bt): a padded RAM image a host or test loads directly;
/// §8.6's vector requirement is a ROM-replacement rule and does not
/// apply to an overlay.
pub fn emitRaw(
    arena: std.mem.Allocator,
    objs: []const loader.Object,
    base: u32,
    size: u32,
    require_vectors: bool,
    err_msg_out: ?*[]const u8,
) Error![]u8 {
    if (objs.len == 0)
        return fail(arena, err_msg_out, "no input objects", .{});

    const Interval = struct { start: u32, end: u32, path: []const u8 };
    var intervals: std.ArrayList(Interval) = .empty;

    for (objs) |obj| {
        for (obj.sections) |sec| {
            if (sec.size == 0) continue;
            if (sec.load_addr == 0)
                return fail(arena, err_msg_out, "{s}: relocatable section '{s}' — raw mode takes absolute (ORG) objects; link with a script instead (decision ba)", .{ obj.path, sec.name });
            const start = sec.load_addr;
            const end = start + sec.size;
            if (start < base or end > base + size)
                return fail(arena, err_msg_out, "{s}: section '{s}' [${X:0>5}..${X:0>5}) falls outside the image window [${X:0>5}..${X:0>5})", .{ obj.path, sec.name, start, end, base, base + size });
            try intervals.append(arena, .{ .start = start, .end = end, .path = obj.path });
        }
    }

    // Pairwise overlap check (decision ba) — section counts are tiny.
    for (intervals.items, 0..) |a, i| {
        for (intervals.items[i + 1 ..]) |b| {
            if (a.start < b.end and b.start < a.end)
                return fail(arena, err_msg_out, "sections overlap: [${X:0>5}..${X:0>5}) from {s} and [${X:0>5}..${X:0>5}) from {s}", .{ a.start, a.end, a.path, b.start, b.end, b.path });
        }
    }

    const image = try arena.alloc(u8, size);
    @memset(image, 0);
    for (objs) |obj| {
        for (obj.sections) |sec| {
            if (sec.payload.len == 0) continue;
            @memcpy(image[sec.load_addr - base ..][0..sec.payload.len], sec.payload);
        }
    }

    // Vector-slot check (amendment §8.6 / decision ba; skipped for
    // overlays, decision bt).
    if (!require_vectors) return image;
    if (vector_base < base or vector_base + vector_len > base + size)
        return fail(arena, err_msg_out, "image window [${X:0>5}..${X:0>5}) does not cover the vector slots ${X:0>5}-${X:0>5}", .{ base, base + size, vector_base, vector_base + vector_len - 1 });
    const vecs = image[vector_base - base ..][0..vector_len];
    if (std.mem.allEqual(u8, vecs, 0))
        return fail(arena, err_msg_out, "the four vector slots at ${X:0>5}-${X:0>5} are empty — a raw image must define its vectors (amendment \u{a7}8.6)", .{ vector_base, vector_base + vector_len - 1 });

    return image;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const testing = std.testing;
const codegen = @import("codegen");
const objfile = @import("objfile");
const script = @import("script");
const relocator = @import("relocator");
const flapp = @import("flapp");
const encode = @import("encode");

fn makeObj(arena: std.mem.Allocator, path: []const u8, src: []const u8) !loader.Object {
    const incbins = codegen.IncbinMap.empty;
    const o = try codegen.assemble(arena, src, &incbins);
    const bytes = try objfile.emit(arena, &o, null);
    return loader.load(arena, path, bytes, null);
}

fn linkOne(arena: std.mem.Allocator, asm_src: []const u8, script_src: []const u8) !resolver.Link {
    const a = try makeObj(arena, "a.flobj", asm_src);
    var msg: []const u8 = "";
    const scr = try script.parse(arena, "t.flld", script_src, &msg);
    const objs = try arena.alloc(loader.Object, 1);
    objs[0] = a;
    var link = try resolver.resolve(arena, objs, scr, &msg);
    try relocator.relocate(arena, objs, &link, &msg);
    return link;
}

test "emitFlapp: header cross-checks flapp.writeHeader; parseHeader accepts; payload correct" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const link = try linkOne(arena,
        \\    SECTION code
        \\start:
        \\    LI R1, (msg & $FFFF)
        \\    HLT
        \\    SECTION data
        \\msg:
        \\    DB $AB
        \\    SECTION bss
        \\    DS 100
        \\
    ,
        \\ENTRY start
        \\VERSION 3
        \\MINRAM 64
        \\SECTION code AT $04100
        \\SECTION data AFTER code
        \\SECTION bss  AFTER data
        \\
    );
    var msg: []const u8 = "";
    const bytes = try emitFlapp(arena, &link, &msg);

    // 12-byte header + 8 code + 1 data; bss adds nothing (decision az).
    try testing.expectEqual(@as(usize, 21), bytes.len);

    // Byte-exact against the emulator's own writer (decision az).
    var expect_hdr: [flapp.header_size]u8 = undefined;
    flapp.writeHeader(&expect_hdr, .{
        .version = 3,
        .entry_offset = 12,
        .min_ram_kb = 64,
        .load_addr = 0x04100,
    });
    try testing.expectEqualSlices(u8, &expect_hdr, bytes[0..flapp.header_size]);

    // And the emulator's parser accepts the whole file.
    const h = try flapp.parseHeader(bytes);
    try testing.expectEqual(@as(u16, 12), h.entry_offset);
    try testing.expectEqual(@as(u32, 0x04100), h.load_addr);

    // Payload: relocated LI at +12, HLT at +16, data byte at +20.
    try testing.expectEqual(encode.li(1, 0x4114), std.mem.readInt(u32, bytes[12..16], .little));
    try testing.expectEqual(encode.hlt(), std.mem.readInt(u32, bytes[16..20], .little));
    try testing.expectEqual(@as(u8, 0xAB), bytes[20]);
}

test "emitFlapp: AT gap zero-fills; entry-in-bss and MINRAM errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var msg: []const u8 = "";

    // data placed 4 bytes past code's end: the gap is zero (decision az).
    {
        const link = try linkOne(arena,
            \\    SECTION code
            \\start:
            \\    HLT
            \\    SECTION data
            \\    DB $CD
            \\
        ,
            \\ENTRY start
            \\SECTION code AT $04100
            \\SECTION data AT $04114
            \\
        );
        const bytes = try emitFlapp(arena, &link, &msg);
        // header 12 + code 4 + gap 4 + data 1 = 21.
        try testing.expectEqual(@as(usize, 21), bytes.len);
        try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[16..20]);
        try testing.expectEqual(@as(u8, 0xCD), bytes[20]);
    }

    // ENTRY names a bss symbol → outside the initialized image.
    {
        const link = try linkOne(arena,
            \\    SECTION code
            \\    HLT
            \\    SECTION bss
            \\oops:
            \\    DS 4
            \\
        ,
            \\ENTRY oops
            \\SECTION code AT $04100
            \\SECTION bss AFTER code
            \\
        );
        try testing.expectError(Error.Emit, emitFlapp(arena, &link, &msg));
        try testing.expect(std.mem.indexOf(u8, msg, "outside the initialized image") != null);
    }

    // MINRAM beyond the machine.
    {
        const link = try linkOne(arena,
            \\    SECTION code
            \\start:
            \\    HLT
            \\
        ,
            \\ENTRY start
            \\MINRAM 1024
            \\SECTION code AT $04100
            \\
        );
        try testing.expectError(Error.Emit, emitFlapp(arena, &link, &msg));
        try testing.expect(std.mem.indexOf(u8, msg, "512") != null);
    }
}

test "emitFlsym matches the §8.7 line format" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const link = try linkOne(arena,
        \\    SECTION code
        \\start:
        \\    HLT
        \\sub:
        \\    RET
        \\    SECTION data
        \\msg:
        \\    DB 0
        \\
    ,
        \\ENTRY start
        \\SECTION code AT $04100
        \\SECTION data AFTER code
        \\
    );
    const flsym = try emitFlsym(arena, &link);
    const expected =
        \\$0410C  start
        \\$04110  sub
        \\$04114  msg
        \\
    ;
    try testing.expectEqualStrings(expected, flsym);
}

test "emitRaw: reproduces an absolute image; vector and overlap rules (decision ba)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var msg: []const u8 = "";

    // Happy path: code + vectors, byte-checked.
    {
        const a = try makeObj(arena, "rom.flobj",
            \\    ORG $FC200
            \\start:
            \\    NOP
            \\    HLT
            \\    ORG $FFFC0
            \\    DD start
            \\
        );
        const objs = [_]loader.Object{a};
        const image = try emitRaw(arena, &objs, 0xFC000, 16384, true, &msg);
        try testing.expectEqual(@as(usize, 16384), image.len);
        try testing.expectEqual(encode.nop(), std.mem.readInt(u32, image[0x200..0x204], .little));
        try testing.expectEqual(encode.hlt(), std.mem.readInt(u32, image[0x204..0x208], .little));
        try testing.expectEqual(@as(u32, 0xFC200), std.mem.readInt(u32, image[0x3FC0..0x3FC4], .little));
        try testing.expectEqual(@as(u8, 0), image[0x100]); // padding
    }

    // Empty vector slots fail.
    {
        const a = try makeObj(arena, "rom.flobj", "    ORG $FC200\n    NOP\n");
        const objs = [_]loader.Object{a};
        try testing.expectError(Error.Emit, emitRaw(arena, &objs, 0xFC000, 16384, true, &msg));
        try testing.expect(std.mem.indexOf(u8, msg, "vector slots") != null);
        try testing.expect(std.mem.indexOf(u8, msg, "empty") != null);
    }

    // Window not covering the vectors fails.
    {
        const a = try makeObj(arena, "rom.flobj", "    ORG $10000\n    NOP\n");
        const objs = [_]loader.Object{a};
        try testing.expectError(Error.Emit, emitRaw(arena, &objs, 0x10000, 4096, true, &msg));
        try testing.expect(std.mem.indexOf(u8, msg, "does not cover the vector slots") != null);
    }

    // Overlap detection across objects.
    {
        const a = try makeObj(arena, "a.flobj", "    ORG $FC200\n    NOP\n    NOP\n");
        const b = try makeObj(arena, "b.flobj", "    ORG $FC204\n    NOP\n");
        const objs = [_]loader.Object{ a, b };
        try testing.expectError(Error.Emit, emitRaw(arena, &objs, 0xFC000, 16384, true, &msg));
        try testing.expect(std.mem.indexOf(u8, msg, "overlap") != null);
    }

    // Relocatable input is redirected to script linking.
    {
        const a = try makeObj(arena, "a.flobj", "    SECTION code\n    NOP\n");
        const objs = [_]loader.Object{a};
        try testing.expectError(Error.Emit, emitRaw(arena, &objs, 0xFC000, 16384, true, &msg));
        try testing.expect(std.mem.indexOf(u8, msg, "link with a script") != null);
    }

    // Overlay mode (decision bt): a RAM image far from the vector slots
    // emits fine without them — bounds and padding still enforced.
    {
        const a = try makeObj(arena, "ram.flobj", "    ORG $04100\n    NOP\n");
        const objs = [_]loader.Object{a};
        const image = try emitRaw(arena, &objs, 0x04100, 256, false, &msg);
        try testing.expectEqual(@as(usize, 256), image.len);
        try testing.expect(!std.mem.allEqual(u8, image[0..4], 0));
    }

    // Section outside the window.
    {
        const a = try makeObj(arena, "a.flobj", "    ORG $FB000\n    NOP\n    ORG $FFFC0\n    DD $FC200\n");
        const objs = [_]loader.Object{a};
        try testing.expectError(Error.Emit, emitRaw(arena, &objs, 0xFC000, 16384, true, &msg));
        try testing.expect(std.mem.indexOf(u8, msg, "outside the image window") != null);
    }
}
