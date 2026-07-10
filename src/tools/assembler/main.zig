//! flas — the Flommodore assembler CLI (Block 10, task 10.11).
//!
//! Usage (master spec §8.10):
//!   flas input.asm -o output.flobj
//!   flas input.asm --listing output.flst -o output.flobj
//!   flas input.asm -I include/dir ... -o output.flobj
//!
//! Pipeline (plan Block 10): INCLUDE splice → lexer → parser → macro →
//! codegen → objfile writer (+ optional listing writer). The driver owns
//! all file I/O: codegen receives INCBIN bytes through its loader map
//! (codegen decision ah) and never touches the filesystem.
//!
//! Implementation decisions (continuing listing.zig's al–am):
//!   (an) INCLUDE is spliced TEXTUALLY before lexing: a line whose first
//!        token is INCLUDE (case-insensitive, comment stripped) is
//!        replaced by the named file's contents, recursively, with a
//!        depth cap of 16 against cycles. Line numbers in diagnostics
//!        and listings therefore refer to the SPLICED source; a file
//!        that uses INCLUDE trades exact line attribution for the
//!        classic textual-include semantics. hello.asm and the test
//!        ROMs use no includes, so their listings are exact.
//!   (ao) File resolution order for INCLUDE and INCBIN paths: the input
//!        file's directory first, then each -I directory in command-line
//!        order, then the path as written (cwd-relative). The default
//!        output path is the input path with its extension replaced by
//!        .flobj.

const std = @import("std");
const parser = @import("parser");
const macro = @import("macro");
const codegen = @import("codegen");
const objfile = @import("objfile");
const listing = @import("listing");

const usage =
    \\usage: flas input.asm [-o output.flobj] [--listing output.flst] [-I dir]...
    \\
;

const Options = struct {
    input: []const u8,
    output: []const u8,
    listing_path: ?[]const u8,
    include_dirs: []const []const u8,
};

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) !Options {
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var listing_path: ?[]const u8 = null;
    var incdirs: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= args.len) return error.BadUsage;
            output = args[i];
        } else if (std.mem.eql(u8, a, "--listing")) {
            i += 1;
            if (i >= args.len) return error.BadUsage;
            listing_path = args[i];
        } else if (std.mem.eql(u8, a, "-I")) {
            i += 1;
            if (i >= args.len) return error.BadUsage;
            try incdirs.append(arena, args[i]);
        } else if (a.len > 0 and a[0] == '-') {
            return error.BadUsage;
        } else {
            if (input != null) return error.BadUsage;
            input = a;
        }
    }
    const in = input orelse return error.BadUsage;

    // Default output: input with extension replaced by .flobj (decision ao).
    const out = output orelse blk: {
        const stem = if (std.mem.lastIndexOfScalar(u8, std.fs.path.basename(in), '.')) |dot|
            in[0 .. in.len - (std.fs.path.basename(in).len - dot)]
        else
            in;
        break :blk try std.fmt.allocPrint(arena, "{s}.flobj", .{stem});
    };
    return .{
        .input = in,
        .output = out,
        .listing_path = listing_path,
        .include_dirs = try incdirs.toOwnedSlice(arena),
    };
}

/// Read `name`, searching the input directory, then -I dirs, then the
/// path as written (decision ao).
fn resolveRead(io: std.Io, arena: std.mem.Allocator, base_dir: []const u8, incdirs: []const []const u8, name: []const u8) ![]u8 {
    const limit: std.Io.Limit = .limited(16 << 20);
    if (!std.fs.path.isAbsolute(name)) {
        const first = try std.fs.path.join(arena, &.{ base_dir, name });
        if (std.Io.Dir.cwd().readFileAlloc(io, first, arena, limit)) |bytes| return bytes else |_| {}
        for (incdirs) |dir| {
            const p = try std.fs.path.join(arena, &.{ dir, name });
            if (std.Io.Dir.cwd().readFileAlloc(io, p, arena, limit)) |bytes| return bytes else |_| {}
        }
    }
    return std.Io.Dir.cwd().readFileAlloc(io, name, arena, limit);
}

/// Strip a quote-aware comment and trim (same rule as the listing's
/// statement column).
fn stripComment(l: []const u8) []const u8 {
    var in_str = false;
    var end = l.len;
    var i: usize = 0;
    while (i < l.len) : (i += 1) {
        const c = l[i];
        if (in_str) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_str = false;
            }
        } else if (c == '"') {
            in_str = true;
        } else if (c == ';') {
            end = i;
            break;
        }
    }
    return std.mem.trim(u8, l[0..end], " \t\r");
}

/// If `line` is an INCLUDE directive, return the quoted path.
fn includePath(line: []const u8) ?[]const u8 {
    const s = stripComment(line);
    if (s.len < 8 or !std.ascii.eqlIgnoreCase(s[0..7], "INCLUDE")) return null;
    if (s[7] != ' ' and s[7] != '\t' and s[7] != '"') return null;
    const open = std.mem.indexOfScalar(u8, s, '"') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, s, '"') orelse return null;
    if (close <= open) return null;
    return s[open + 1 .. close];
}

/// Textual INCLUDE splicing (decision an).
fn spliceIncludes(io: std.Io, arena: std.mem.Allocator, src: []const u8, base_dir: []const u8, incdirs: []const []const u8, depth: u32) ![]u8 {
    if (depth > 16) {
        std.debug.print("flas: error: INCLUDE nesting deeper than 16 — cycle? (decision an)\n", .{});
        return error.IncludeCycle;
    }
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (includePath(line)) |path| {
            const bytes = resolveRead(io, arena, base_dir, incdirs, path) catch |err| {
                std.debug.print("flas: error: INCLUDE \"{s}\": {t}\n", .{ path, err });
                return err;
            };
            const spliced = try spliceIncludes(io, arena, bytes, base_dir, incdirs, depth + 1);
            try out.appendSlice(arena, spliced);
            if (spliced.len == 0 or spliced[spliced.len - 1] != '\n')
                try out.append(arena, '\n');
        } else {
            try out.appendSlice(arena, line);
            try out.append(arena, '\n');
        }
    }
    // splitScalar yields a final empty piece for a trailing '\n'; drop the
    // extra newline it produced.
    if (std.mem.endsWith(u8, out.items, "\n") and !std.mem.endsWith(u8, src, "\n"))
        _ = out.pop();
    if (std.mem.endsWith(u8, src, "\n") and std.mem.endsWith(u8, out.items, "\n\n"))
        _ = out.pop();
    return out.toOwnedSlice(arena);
}

fn diag(path: []const u8, line: u32, col: u32, msg: []const u8) void {
    std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ path, line, col, msg });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(arena, args) catch {
        std.debug.print(usage, .{});
        return error.BadUsage;
    };

    const base_dir = std.fs.path.dirname(opts.input) orelse ".";
    const raw = std.Io.Dir.cwd().readFileAlloc(io, opts.input, arena, .limited(16 << 20)) catch |err| {
        std.debug.print("flas: error: cannot read {s}: {t}\n", .{ opts.input, err });
        return err;
    };
    const src = try spliceIncludes(io, arena, raw, base_dir, opts.include_dirs, 0);

    // Parse.
    var p = parser.Parser.init(arena, src) catch |err| {
        std.debug.print("flas: error: {t}\n", .{err});
        return err;
    };
    const items = p.parseProgram() catch |err| {
        diag(opts.input, p.err_line, p.err_col, p.err_msg);
        return err;
    };

    // Expand macros.
    var x = macro.Expander.init(arena);
    const expanded = x.expand(items) catch |err| {
        diag(opts.input, x.err_line, x.err_col, x.err_msg);
        return err;
    };

    // Load INCBIN payloads (codegen decision ah).
    var incbins = codegen.IncbinMap.empty;
    for (expanded) |item| {
        if (item.payload != .directive) continue;
        const d = item.payload.directive;
        if (d.kind != .incbin) continue;
        if (d.args.len != 1 or d.args[0].payload != .string) continue; // codegen reports it
        const path = d.args[0].payload.string;
        if (incbins.contains(path)) continue;
        const bytes = resolveRead(io, arena, base_dir, opts.include_dirs, path) catch |err| {
            std.debug.print("flas: error: INCBIN \"{s}\": {t}\n", .{ path, err });
            return err;
        };
        try incbins.put(arena, path, bytes);
    }

    // Generate.
    var g = codegen.Codegen.init(arena, &incbins);
    const obj = g.run(expanded) catch |err| {
        diag(opts.input, g.err_line, g.err_col, g.err_msg);
        return err;
    };

    // Serialize .flobj.
    var obj_err: []const u8 = "";
    const obj_bytes = objfile.emit(arena, &obj, &obj_err) catch |err| {
        std.debug.print("flas: error: {s}\n", .{obj_err});
        return err;
    };
    {
        var f = std.Io.Dir.cwd().createFile(io, opts.output, .{}) catch |err| {
            std.debug.print("flas: error: cannot write {s}: {t}\n", .{ opts.output, err });
            return err;
        };
        defer f.close(io);
        try f.writeStreamingAll(io, obj_bytes);
    }

    // Optional .flst listing (task 10.10).
    if (opts.listing_path) |lpath| {
        const flst = try listing.emit(arena, src, &obj);
        var f = std.Io.Dir.cwd().createFile(io, lpath, .{}) catch |err| {
            std.debug.print("flas: error: cannot write {s}: {t}\n", .{ lpath, err });
            return err;
        };
        defer f.close(io);
        try f.writeStreamingAll(io, flst);
    }
}
