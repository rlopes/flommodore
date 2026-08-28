//! fldisk — FLFS volume tool (Block 15 follow-up).
//!
//! Usage:
//!   fldisk create <image> [--sectors N] [--label TEXT]
//!   fldisk add    <image> <file> --name NAME [--type AP|DT|SN|TX] [-o out]
//!   fldisk list   <image>
//!
//! Formats and populates the FLFS v1 volumes of amendment v1.3 §3, so a
//! disk image can be built without a running machine. Nothing else can
//! make one: the BIOS allocates files but never formats, and `SAVE` on an
//! unformatted image reads a total-sector count of zero and fails.
//!
//! ONE ALLOCATOR, TWO IMPLEMENTATIONS — read this before changing either.
//! `allocate` below deliberately mirrors `sys_dskcreat` in
//! src/bios/storage.inc: first free or deleted directory slot for the
//! entry, and a bump allocation above the highest start+count in use, with
//! sector 2 as the floor. FLFS v1 never reclaims deleted space (D55), so
//! that is the whole algorithm — but it IS duplicated across the
//! Zig/Gab-16 boundary, which no amount of care removes. The round-trip
//! test in build.zig (fldisk formats, the guest writes, fldisk lists) is
//! what actually holds them together; if they ever disagree, that test is
//! the thing that will say so.
//!
//! Layout (v1.3 §3): sector 0 volume header, sector 1 the 16-entry
//! directory, sector 2 onward data.
//!
//! `add` writes back in place by default, which is what a person at a
//! prompt wants — and exactly what a build graph cannot express. A build
//! step's inputs are immutable and its outputs are cached, so a `create`
//! that does not re-run followed by an `add` that does means adding the
//! same file twice: DuplicateName, every build after the first. Passing
//! `-o` makes `add` a pure function of its inputs, so the populated volume
//! is a real build artifact rather than a mutation of one.
//!
//! SILENT ON SUCCESS, like flas and fll. Not a style preference: a Zig
//! build step that declares an output file captures the child's streams
//! and fails on unexpected stderr, so a chatty `create` breaks the very
//! build wiring that needs it. `list` prints, because printing is the
//! whole point of it, and it never runs as a build step.

const std = @import("std");

pub const sector_size: u32 = 512;
pub const dir_lba: u32 = 1;
pub const data_lba: u16 = 2;
pub const dir_entries: u32 = 16;
pub const entry_size: u32 = 32;
/// STO-b: the identify record reports the count in a 16-bit field, so
/// 65,535 is the last usable sector.
pub const max_sectors: u32 = 65535;

// Entry field offsets (v1.3 §3).
const e_name: u32 = 0x00; // 12 bytes, ASCII, space-padded, upper case
const e_type: u32 = 0x0C;
const e_start: u32 = 0x0E;
const e_count: u32 = 0x10;
const e_length: u32 = 0x12; // 4 bytes
const e_flags: u32 = 0x16;

const name_len: u32 = 12;

/// Directory name bytes with these leading values are not live entries.
const name_never_used: u8 = 0x00;
const name_deleted: u8 = 0xE5;

pub const Error = error{
    NotFlfs,
    BadImage,
    DirectoryFull,
    DiskFull,
    DuplicateName,
    NameTooLong,
    BadType,
};

/// A volume held in memory. The caller owns `bytes`.
pub const Volume = struct {
    bytes: []u8,

    pub fn sectorCount(v: Volume) u32 {
        return @intCast(v.bytes.len / sector_size);
    }

    fn sector(v: Volume, lba: u32) []u8 {
        return v.bytes[lba * sector_size ..][0..sector_size];
    }

    fn dir(v: Volume) []u8 {
        return v.sector(dir_lba);
    }

    fn entry(v: Volume, index: u32) []u8 {
        return v.dir()[index * entry_size ..][0..entry_size];
    }

    /// Total sectors as the volume header advertises it — the number
    /// SYS_DSKCREAT reads and checks allocations against.
    pub fn headerTotal(v: Volume) u16 {
        return std.mem.readInt(u16, v.bytes[6..8], .little);
    }

    pub fn check(v: Volume) Error!void {
        if (v.bytes.len < 2 * sector_size or v.bytes.len % sector_size != 0) return Error.BadImage;
        if (!std.mem.eql(u8, v.bytes[0..4], "FLFS")) return Error.NotFlfs;
    }

    /// Format in place: volume header, zeroed directory, zeroed data.
    pub fn format(bytes: []u8, label: []const u8) Error!Volume {
        if (bytes.len < 2 * sector_size or bytes.len % sector_size != 0) return Error.BadImage;
        @memset(bytes, 0);
        const v = Volume{ .bytes = bytes };
        @memcpy(bytes[0..4], "FLFS");
        std.mem.writeInt(u16, bytes[4..6], 1, .little); // version
        std.mem.writeInt(u16, bytes[6..8], @intCast(v.sectorCount()), .little);
        @memset(bytes[8..16], ' ');
        const n = @min(label.len, 8);
        for (label[0..n], 0..) |c, i| bytes[8 + i] = std.ascii.toUpper(c);
        return v;
    }

    fn nameMatches(stored: []const u8, wanted: []const u8) bool {
        var i: u32 = 0;
        while (i < name_len) : (i += 1) {
            const w: u8 = if (i < wanted.len) std.ascii.toUpper(wanted[i]) else ' ';
            if (stored[i] != w) return false;
        }
        return true;
    }

    pub fn find(v: Volume, wanted: []const u8) ?u32 {
        var i: u32 = 0;
        while (i < dir_entries) : (i += 1) {
            const e = v.entry(i);
            if (e[0] == name_never_used) return null; // $00 ends the directory
            if (e[0] == name_deleted) continue;
            if (nameMatches(e[0..name_len], wanted)) return i;
        }
        return null;
    }

    /// Allocate a file — the mirror of sys_dskcreat (see the header note).
    /// Returns the directory index; the caller writes the data sectors.
    pub fn allocate(v: Volume, wanted: []const u8, sectors: u16, kind: [2]u8) Error!u32 {
        if (wanted.len > name_len) return Error.NameTooLong;
        if (sectors == 0) return Error.BadImage;
        if (v.find(wanted) != null) return Error.DuplicateName;

        var slot: ?u32 = null;
        var next: u16 = data_lba;
        var i: u32 = 0;
        while (i < dir_entries) : (i += 1) {
            const e = v.entry(i);
            if (e[0] == name_never_used or e[0] == name_deleted) {
                if (slot == null) slot = i; // first free slot takes the entry…
                continue;
            }
            const start = std.mem.readInt(u16, e[e_start..][0..2], .little);
            const count = std.mem.readInt(u16, e[e_count..][0..2], .little);
            next = @max(next, start + count); // …but never its sectors (D55)
        }
        const index = slot orelse return Error.DirectoryFull;
        if (@as(u32, next) + sectors > v.headerTotal()) return Error.DiskFull;

        const e = v.entry(index);
        @memset(e, 0);
        @memset(e[0..name_len], ' ');
        for (wanted, 0..) |c, n| e[n] = std.ascii.toUpper(c);
        e[e_type] = kind[0];
        e[e_type + 1] = kind[1];
        std.mem.writeInt(u16, e[e_start..][0..2], next, .little);
        std.mem.writeInt(u16, e[e_count..][0..2], sectors, .little);
        return index;
    }

    /// Copy `data` into the run owned by directory entry `index`, padding
    /// the final sector with zeros, and record the exact byte length.
    pub fn writeData(v: Volume, index: u32, data: []const u8) void {
        const e = v.entry(index);
        const start = std.mem.readInt(u16, e[e_start..][0..2], .little);
        const count = std.mem.readInt(u16, e[e_count..][0..2], .little);
        const run = v.bytes[@as(u32, start) * sector_size ..][0 .. @as(u32, count) * sector_size];
        @memset(run, 0);
        @memcpy(run[0..data.len], data);
        std.mem.writeInt(u32, e[e_length..][0..4], @intCast(data.len), .little);
    }
};

fn parseType(text: []const u8) Error![2]u8 {
    if (text.len != 2) return Error.BadType;
    const up = [2]u8{ std.ascii.toUpper(text[0]), std.ascii.toUpper(text[1]) };
    inline for ([_][]const u8{ "AP", "DT", "SN", "TX" }) |ok| {
        if (std.mem.eql(u8, &up, ok)) return up;
    }
    return Error.BadType;
}

fn flagValue(args: []const []const u8, i: *usize, name: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, args[i.*], name)) return null;
    i.* += 1;
    if (i.* >= args.len) return null;
    return args[i.*];
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 3) {
        std.debug.print(
            \\usage:
            \\  fldisk create <image> [--sectors N] [--label TEXT]
            \\  fldisk add    <image> <file> --name NAME [--type AP|DT|SN|TX]
            \\  fldisk list   <image>
            \\
        , .{});
        return error.BadUsage;
    }
    const verb = args[1];
    const path = args[2];
    const cwd = std.Io.Dir.cwd();

    if (std.mem.eql(u8, verb, "create")) {
        var sectors: u32 = 64;
        var label: []const u8 = "FLOMMODR";
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (flagValue(args, &i, "--sectors")) |t| {
                sectors = try std.fmt.parseInt(u32, t, 10);
            } else if (flagValue(args, &i, "--label")) |t| {
                label = t;
            } else {
                std.debug.print("fldisk: unknown option {s}\n", .{args[i]});
                return error.BadUsage;
            }
        }
        if (sectors < 2 or sectors > max_sectors) {
            std.debug.print("fldisk: --sectors must be 2..{d}\n", .{max_sectors});
            return error.BadUsage;
        }
        const bytes = try arena.alloc(u8, sectors * sector_size);
        _ = try Volume.format(bytes, label);
        var file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        return;
    }

    if (std.mem.eql(u8, verb, "add")) {
        if (args.len < 4) return error.BadUsage;
        const src = args[3];
        var name: ?[]const u8 = null;
        var out: ?[]const u8 = null;
        var kind: [2]u8 = .{ 'D', 'T' };
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (flagValue(args, &i, "--name")) |t| {
                name = t;
            } else if (flagValue(args, &i, "--type")) |t| {
                kind = try parseType(t);
            } else if (flagValue(args, &i, "-o")) |t| {
                out = t;
            } else {
                std.debug.print("fldisk: unknown option {s}\n", .{args[i]});
                return error.BadUsage;
            }
        }
        const wanted = name orelse {
            std.debug.print("fldisk: add needs --name\n", .{});
            return error.BadUsage;
        };
        const bytes = try cwd.readFileAlloc(io, path, arena, .limited(max_sectors * sector_size));
        const v = Volume{ .bytes = bytes };
        try v.check();
        const data = try cwd.readFileAlloc(io, src, arena, .limited(max_sectors * sector_size));
        const sectors: u16 = @intCast((data.len + sector_size - 1) / sector_size);
        // An FB image is a program whatever the caller said, so LOAD will
        // take it — the same rule SAVE applies in storage.inc.
        if (data.len >= 2 and data[0] == 'F' and data[1] == 'B') kind = .{ 'A', 'P' };
        const index = try v.allocate(wanted, sectors, kind);
        v.writeData(index, data);
        // -o writes a new volume and leaves the input untouched; without
        // it the volume is updated in place.
        var file = try cwd.createFile(io, out orelse path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        return;
    }

    if (std.mem.eql(u8, verb, "list")) {
        const bytes = try cwd.readFileAlloc(io, path, arena, .limited(max_sectors * sector_size));
        const v = Volume{ .bytes = bytes };
        try v.check();
        std.debug.print("volume \"{s}\"  {d} sectors (header says {d})\n", .{
            bytes[8..16], v.sectorCount(), v.headerTotal(),
        });
        std.debug.print("  #  NAME          TYPE  LBA  SECTORS  BYTES\n", .{});
        var live: u32 = 0;
        var i: u32 = 0;
        while (i < dir_entries) : (i += 1) {
            const e = v.entry(i);
            if (e[0] == name_never_used) break;
            if (e[0] == name_deleted) continue;
            live += 1;
            std.debug.print("  {d:>2}  {s}  {c}{c}   {d:>4}  {d:>7}  {d}\n", .{
                i,
                e[0..name_len],
                e[e_type],
                e[e_type + 1],
                std.mem.readInt(u16, e[e_start..][0..2], .little),
                std.mem.readInt(u16, e[e_count..][0..2], .little),
                std.mem.readInt(u32, e[e_length..][0..4], .little),
            });
        }
        if (live == 0) std.debug.print("  (empty)\n", .{});
        return;
    }

    std.debug.print("fldisk: unknown command {s}\n", .{verb});
    return error.BadUsage;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn scratch(sectors: u32) ![]u8 {
    return testing.allocator.alloc(u8, sectors * sector_size);
}

test "fldisk: format writes the v1.3 §3 volume header" {
    const bytes = try scratch(64);
    defer testing.allocator.free(bytes);
    @memset(bytes, 0xAA); // format must clear, not just stamp
    const v = try Volume.format(bytes, "work");
    try v.check();
    try testing.expectEqualSlices(u8, "FLFS", bytes[0..4]);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[4..6], .little));
    try testing.expectEqual(@as(u16, 64), v.headerTotal());
    try testing.expectEqualSlices(u8, "WORK    ", bytes[8..16]); // upper, padded
    // Directory and data are zeroed, so entry 0 reads as end-of-directory.
    try testing.expectEqual(@as(u8, 0), bytes[sector_size]);
    try testing.expect(v.find("anything") == null);
}

test "fldisk: allocation bump-allocates above live files and reuses slots" {
    const bytes = try scratch(64);
    defer testing.allocator.free(bytes);
    const v = try Volume.format(bytes, "work");

    const a = try v.allocate("FIRST", 3, .{ 'D', 'T' });
    try testing.expectEqual(@as(u32, 0), a);
    try testing.expectEqual(@as(u16, data_lba), std.mem.readInt(u16, v.entry(a)[e_start..][0..2], .little));

    const b = try v.allocate("SECOND", 2, .{ 'D', 'T' });
    try testing.expectEqual(@as(u16, data_lba + 3), std.mem.readInt(u16, v.entry(b)[e_start..][0..2], .little));

    // Deleting frees the SLOT but never the sectors (D55): a third file
    // still lands above both runs, and takes the vacated entry.
    v.entry(a)[0] = name_deleted;
    const c = try v.allocate("THIRD", 1, .{ 'D', 'T' });
    try testing.expectEqual(@as(u32, 0), c); // reused slot
    try testing.expectEqual(@as(u16, data_lba + 5), std.mem.readInt(u16, v.entry(c)[e_start..][0..2], .little));

    try testing.expectError(Error.DuplicateName, v.allocate("third", 1, .{ 'D', 'T' }));
    try testing.expectError(Error.NameTooLong, v.allocate("THIRTEEN-CHAR", 1, .{ 'D', 'T' }));
}

test "fldisk: names are case-folded, padded, and matched to 12 bytes" {
    const bytes = try scratch(8);
    defer testing.allocator.free(bytes);
    const v = try Volume.format(bytes, "work");
    const i = try v.allocate("aured", 1, .{ 'A', 'P' });
    try testing.expectEqualSlices(u8, "AURED       ", v.entry(i)[0..name_len]);
    try testing.expectEqual(@as(?u32, i), v.find("AURED"));
    try testing.expectEqual(@as(?u32, i), v.find("aured")); // case-insensitive
    try testing.expect(v.find("AURE") == null); // not a prefix match
}

test "fldisk: out of space and out of directory slots are distinct failures" {
    const small = try scratch(4); // sectors 2 and 3 are the only data
    defer testing.allocator.free(small);
    const v = try Volume.format(small, "tiny");
    _ = try v.allocate("FITS", 2, .{ 'D', 'T' });
    try testing.expectError(Error.DiskFull, v.allocate("NOPE", 1, .{ 'D', 'T' }));

    const big = try scratch(64);
    defer testing.allocator.free(big);
    const w = try Volume.format(big, "full");
    var n: u32 = 0;
    while (n < dir_entries) : (n += 1) {
        var buf: [12]u8 = undefined;
        _ = try std.fmt.bufPrint(&buf, "F{d}", .{n});
        _ = try w.allocate(buf[0 .. if (n < 10) @as(usize, 2) else 3], 1, .{ 'D', 'T' });
    }
    try testing.expectError(Error.DirectoryFull, w.allocate("ONEMORE", 1, .{ 'D', 'T' }));
}

test "fldisk: data is zero-padded to the sector and the exact length recorded" {
    const bytes = try scratch(16);
    defer testing.allocator.free(bytes);
    const v = try Volume.format(bytes, "work");
    var payload: [600]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);
    const i = try v.allocate("BIG", 2, .{ 'D', 'T' });
    v.writeData(i, &payload);
    const start = std.mem.readInt(u16, v.entry(i)[e_start..][0..2], .little);
    const run = bytes[@as(u32, start) * sector_size ..][0 .. 2 * sector_size];
    try testing.expectEqualSlices(u8, &payload, run[0..600]);
    for (run[600..]) |b| try testing.expectEqual(@as(u8, 0), b); // tail padded
    try testing.expectEqual(@as(u32, 600), std.mem.readInt(u32, v.entry(i)[e_length..][0..4], .little));
}

test "fldisk: check rejects unformatted and malformed images" {
    const bytes = try scratch(8);
    defer testing.allocator.free(bytes);
    @memset(bytes, 0);
    try testing.expectError(Error.NotFlfs, (Volume{ .bytes = bytes }).check());
    try testing.expectError(Error.BadImage, Volume.format(bytes[0..100], "x"));
    try testing.expectError(Error.BadImage, Volume.format(bytes[0..sector_size], "x")); // no room for a directory
}

test "fldisk: type strings" {
    try testing.expectEqual([2]u8{ 'A', 'P' }, try parseType("ap"));
    try testing.expectEqual([2]u8{ 'S', 'N' }, try parseType("SN"));
    try testing.expectError(Error.BadType, parseType("ZZ"));
    try testing.expectError(Error.BadType, parseType("A"));
}
