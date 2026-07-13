//! fll linker script parser — .flld files (Block 11, task 11.5).
//!
//! Grammar (Phase 8 §8.5 / master spec §8.5), one statement per line,
//! `;` comments, blank lines ignored:
//!
//!   ENTRY <symbol>
//!   SECTION <name> AT $<addr>
//!   SECTION <name> AFTER <name>
//!   VERSION <n>          (optional)
//!   MINRAM  <kb>         (optional)
//!
//! Implementation decisions (continuing loader.zig's ap–aq):
//!   (ar) §8.5 says the .flapp header's version and min-RAM fields come
//!        "from the linker script" without naming the syntax; the
//!        keywords are VERSION and MINRAM, defaulting to 1 and 0. The
//!        --version command-line flag (spec'd alternative) overrides the
//!        script in the driver.
//!   (as) Keywords are case-insensitive (assembler decision r); section
//!        and symbol names are case-sensitive. AFTER must reference a
//!        section placed by an EARLIER rule (single forward pass);
//!        duplicate SECTION rules for one name and duplicate
//!        ENTRY/VERSION/MINRAM statements are errors. Numbers are
//!        decimal or $hex, the assembler's convention.

const std = @import("std");

pub const Error = error{ Script, OutOfMemory };

pub const Placement = union(enum) {
    at: u32,
    after: []const u8,
};

pub const SectionRule = struct {
    name: []const u8,
    placement: Placement,
    line: u32,
};

pub const Script = struct {
    entry: ?[]const u8 = null,
    version: u16 = 1, // decision ar
    min_ram_kb: u16 = 0, // decision ar
    rules: []SectionRule = &.{},
};

const Parser = struct {
    arena: std.mem.Allocator,
    path: []const u8,
    err_msg_out: ?*[]const u8,

    fn fail(p: *Parser, line: u32, comptime fmt: []const u8, args: anytype) Error {
        if (p.err_msg_out) |dst| {
            dst.* = std.fmt.allocPrint(p.arena, "{s}:{d}: " ++ fmt, .{ p.path, line } ++ args) catch
                "out of memory formatting diagnostic";
        }
        return Error.Script;
    }
};

fn stripComment(l: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, l, ';') orelse l.len;
    return std.mem.trim(u8, l[0..end], " \t\r");
}

fn number(word: []const u8) ?u32 {
    if (word.len == 0) return null;
    if (word[0] == '$')
        return std.fmt.parseInt(u32, word[1..], 16) catch null;
    return std.fmt.parseInt(u32, word, 10) catch null;
}

pub fn parse(arena: std.mem.Allocator, path: []const u8, src: []const u8, err_msg_out: ?*[]const u8) Error!Script {
    var p = Parser{ .arena = arena, .path = path, .err_msg_out = err_msg_out };
    var script = Script{};
    var rules: std.ArrayList(SectionRule) = .empty;
    var saw_version = false;
    var saw_minram = false;

    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = stripComment(raw);
        if (line.len == 0) continue;

        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        while (it.next()) |w| try words.append(arena, w);
        const w = words.items;
        const kw = w[0];

        if (std.ascii.eqlIgnoreCase(kw, "ENTRY")) {
            if (w.len != 2)
                return p.fail(line_no, "ENTRY takes exactly one symbol name", .{});
            if (script.entry != null)
                return p.fail(line_no, "duplicate ENTRY statement (decision as)", .{});
            script.entry = try arena.dupe(u8, w[1]);
        } else if (std.ascii.eqlIgnoreCase(kw, "SECTION")) {
            if (w.len != 4)
                return p.fail(line_no, "expected 'SECTION <name> AT $addr' or 'SECTION <name> AFTER <name>'", .{});
            const name = w[1];
            for (rules.items) |r| {
                if (std.mem.eql(u8, r.name, name))
                    return p.fail(line_no, "duplicate placement rule for section '{s}' (first on line {d})", .{ name, r.line });
            }
            const placement: Placement = if (std.ascii.eqlIgnoreCase(w[2], "AT")) blk: {
                const n = number(w[3]) orelse
                    return p.fail(line_no, "'{s}' is not a valid address (use $hex or decimal)", .{w[3]});
                break :blk .{ .at = n };
            } else if (std.ascii.eqlIgnoreCase(w[2], "AFTER")) blk: {
                const target = w[3];
                const defined = for (rules.items) |r| {
                    if (std.mem.eql(u8, r.name, target)) break true;
                } else false;
                if (!defined)
                    return p.fail(line_no, "AFTER '{s}': no earlier rule places that section (decision as)", .{target});
                break :blk .{ .after = try arena.dupe(u8, target) };
            } else return p.fail(line_no, "expected AT or AFTER, got '{s}'", .{w[2]});
            try rules.append(arena, .{
                .name = try arena.dupe(u8, name),
                .placement = placement,
                .line = line_no,
            });
        } else if (std.ascii.eqlIgnoreCase(kw, "VERSION")) {
            if (w.len != 2 or number(w[1]) == null or number(w[1]).? > 0xFFFF)
                return p.fail(line_no, "VERSION takes one 16-bit number", .{});
            if (saw_version)
                return p.fail(line_no, "duplicate VERSION statement (decision as)", .{});
            script.version = @intCast(number(w[1]).?);
            saw_version = true;
        } else if (std.ascii.eqlIgnoreCase(kw, "MINRAM")) {
            if (w.len != 2 or number(w[1]) == null or number(w[1]).? > 0xFFFF)
                return p.fail(line_no, "MINRAM takes one 16-bit KB count", .{});
            if (saw_minram)
                return p.fail(line_no, "duplicate MINRAM statement (decision as)", .{});
            script.min_ram_kb = @intCast(number(w[1]).?);
            saw_minram = true;
        } else {
            return p.fail(line_no, "unknown statement '{s}' (ENTRY, SECTION, VERSION, MINRAM)", .{kw});
        }
    }

    script.rules = try rules.toOwnedSlice(arena);
    return script;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the Phase 8 example script parses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try parse(arena, "program.flld",
        \\; program.flld — Flommodore Linker Description
        \\
        \\ENTRY start             ; entry point symbol name
        \\
        \\SECTION code AT $04100  ; place code section at start of free RAM
        \\SECTION data AFTER code ; place data section immediately after code
        \\SECTION bss  AFTER data ; zero-initialised data after that
        \\
    , null);
    try testing.expectEqualStrings("start", s.entry.?);
    try testing.expectEqual(@as(u16, 1), s.version);
    try testing.expectEqual(@as(u16, 0), s.min_ram_kb);
    try testing.expectEqual(@as(usize, 3), s.rules.len);
    try testing.expectEqualStrings("code", s.rules[0].name);
    try testing.expectEqual(@as(u32, 0x04100), s.rules[0].placement.at);
    try testing.expectEqualStrings("data", s.rules[1].name);
    try testing.expectEqualStrings("code", s.rules[1].placement.after);
    try testing.expectEqualStrings("bss", s.rules[2].name);
    try testing.expectEqualStrings("data", s.rules[2].placement.after);
}

test "VERSION and MINRAM keywords (decision ar)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try parse(arena, "x.flld",
        \\ENTRY main
        \\VERSION 3
        \\MINRAM 64
        \\SECTION code AT $04100
        \\
    , null);
    try testing.expectEqual(@as(u16, 3), s.version);
    try testing.expectEqual(@as(u16, 64), s.min_ram_kb);
}

test "script errors carry file:line and reasons" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct { src: []const u8, needle: []const u8 };
    const cases = [_]Case{
        .{ .src = "SECTION data AFTER code\n", .needle = "no earlier rule" },
        .{ .src = "SECTION code AT $04100\nSECTION code AT $05000\n", .needle = "duplicate placement rule" },
        .{ .src = "ENTRY a\nENTRY b\n", .needle = "duplicate ENTRY" },
        .{ .src = "SECTION code AT zebra\n", .needle = "not a valid address" },
        .{ .src = "SECTION code NEAR $100\n", .needle = "expected AT or AFTER" },
        .{ .src = "FROBNICATE 3\n", .needle = "unknown statement" },
        .{ .src = "VERSION 70000\n", .needle = "16-bit" },
    };
    for (cases) |case| {
        var msg: []const u8 = "";
        try testing.expectError(Error.Script, parse(arena, "bad.flld", case.src, &msg));
        try testing.expect(std.mem.startsWith(u8, msg, "bad.flld:"));
        if (std.mem.indexOf(u8, msg, case.needle) == null) {
            std.debug.print("src: {s}\nwanted: {s}\ngot: {s}\n", .{ case.src, case.needle, msg });
            return error.TestUnexpectedResult;
        }
    }
}
