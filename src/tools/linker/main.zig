//! fll — the Flommodore linker CLI (Block 11, tasks 11.6–11.10).
//!
//! Usage (master spec §8.10 / amendment §8.6):
//!   fll main.flobj lib.flobj -s program.flld -o program.flapp
//!   fll *.flobj -s program.flld -o program.flapp -v
//!   fll --raw --base $FC000 --size 16K input.flobj -o flommodore.rom
//!
//! Pipeline: loader → resolver → relocator → emitter. The .flsym file
//! is emitted alongside every .flapp (§8.7), named after the output's
//! stem. `--version N` overrides the script's VERSION (decision ar).
//!
//! Implementation decisions (continuing emitter.zig's az–ba):
//!   (bb) --size accepts a K suffix (×1024, case-insensitive) or a
//!        plain decimal/$hex byte count. Default outputs: the first
//!        input's stem + ".flapp" (script mode) or ".rom" (raw mode);
//!        the .flsym replaces the output extension. Raw mode emits no
//!        .flsym — the symbol file is the .flapp debugger contract.

const std = @import("std");
const loader = @import("loader");
const script = @import("script");
const resolver = @import("resolver");
const relocator = @import("relocator");
const emitter = @import("emitter");

const usage =
    \\usage: fll inputs.flobj... -s script.flld [-o out.flapp] [-v] [--version N]
    \\       fll --raw --base $ADDR --size N[K] inputs.flobj... [-o out.rom] [-v]
    \\
;

const Options = struct {
    inputs: []const []const u8,
    script_path: ?[]const u8,
    output: []const u8,
    verbose: bool,
    version_override: ?u16,
    raw: bool,
    base: ?u32,
    size: ?u32,
};

fn parseNum(word: []const u8) ?u32 {
    if (word.len == 0) return null;
    if (word[0] == '$')
        return std.fmt.parseInt(u32, word[1..], 16) catch null;
    return std.fmt.parseInt(u32, word, 10) catch null;
}

/// --size argument: decimal/$hex bytes, or K-suffixed KiB (decision bb).
fn parseSize(word: []const u8) ?u32 {
    if (word.len == 0) return null;
    const last = word[word.len - 1];
    if (last == 'K' or last == 'k') {
        const n = parseNum(word[0 .. word.len - 1]) orelse return null;
        if (n > (1 << 20)) return null;
        return n * 1024;
    }
    return parseNum(word);
}

/// input path with its extension replaced (decision bb; flas decision ao).
fn withExtension(arena: std.mem.Allocator, path: []const u8, ext: []const u8) ![]const u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, std.fs.path.basename(path), '.')) |dot|
        path[0 .. path.len - (std.fs.path.basename(path).len - dot)]
    else
        path;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ stem, ext });
}

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) !Options {
    var inputs: std.ArrayList([]const u8) = .empty;
    var script_path: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var verbose = false;
    var version_override: ?u16 = null;
    var raw = false;
    var base: ?u32 = null;
    var size: ?u32 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-s")) {
            i += 1;
            if (i >= args.len) return error.BadUsage;
            script_path = args[i];
        } else if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= args.len) return error.BadUsage;
            output = args[i];
        } else if (std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--version")) {
            i += 1;
            if (i >= args.len) return error.BadUsage;
            const n = parseNum(args[i]) orelse return error.BadUsage;
            if (n > 0xFFFF) return error.BadUsage;
            version_override = @intCast(n);
        } else if (std.mem.eql(u8, a, "--raw")) {
            raw = true;
        } else if (std.mem.eql(u8, a, "--base")) {
            i += 1;
            if (i >= args.len) return error.BadUsage;
            base = parseNum(args[i]) orelse return error.BadUsage;
        } else if (std.mem.eql(u8, a, "--size")) {
            i += 1;
            if (i >= args.len) return error.BadUsage;
            size = parseSize(args[i]) orelse return error.BadUsage;
        } else if (a.len > 0 and a[0] == '-') {
            return error.BadUsage;
        } else {
            try inputs.append(arena, a);
        }
    }
    if (inputs.items.len == 0) return error.BadUsage;
    if (raw) {
        if (base == null or size == null or script_path != null) return error.BadUsage;
    } else {
        if (script_path == null or base != null or size != null) return error.BadUsage;
    }
    const out = output orelse try withExtension(arena, inputs.items[0], if (raw) ".rom" else ".flapp");
    return .{
        .inputs = try inputs.toOwnedSlice(arena),
        .script_path = script_path,
        .output = out,
        .verbose = verbose,
        .version_override = version_override,
        .raw = raw,
        .base = base,
        .size = size,
    };
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var f = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        std.debug.print("fll: error: cannot write {s}: {t}\n", .{ path, err });
        return err;
    };
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(arena, args) catch {
        std.debug.print(usage, .{});
        return error.BadUsage;
    };

    // Load every input object.
    const objs = try arena.alloc(loader.Object, opts.inputs.len);
    for (opts.inputs, 0..) |path, i| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch |err| {
            std.debug.print("fll: error: cannot read {s}: {t}\n", .{ path, err });
            return err;
        };
        var err_msg: []const u8 = "";
        objs[i] = loader.load(arena, path, bytes, &err_msg) catch |err| {
            std.debug.print("fll: error: {s}\n", .{err_msg});
            return err;
        };
    }

    if (opts.raw) {
        var err_msg: []const u8 = "";
        const image = emitter.emitRaw(arena, objs, opts.base.?, opts.size.?, &err_msg) catch |err| {
            std.debug.print("fll: error: {s}\n", .{err_msg});
            return err;
        };
        try writeFile(io, opts.output, image);
        if (opts.verbose) {
            std.debug.print("fll: raw image map ({s})\n", .{opts.output});
            std.debug.print("  window  ${X:0>5}..${X:0>6}  {d} bytes\n", .{ opts.base.?, opts.base.? + opts.size.?, opts.size.? });
            for (objs) |obj| {
                for (obj.sections) |sec| {
                    if (sec.size == 0) continue;
                    std.debug.print("  {s: <7} ${X:0>5}..${X:0>5}  {d} bytes  ({s})\n", .{ sec.name, sec.load_addr, sec.load_addr + sec.size, sec.size, obj.path });
                }
            }
        }
        return;
    }

    // Script mode: parse → resolve → relocate → emit.
    var err_msg: []const u8 = "";
    const script_src = std.Io.Dir.cwd().readFileAlloc(io, opts.script_path.?, arena, .limited(1 << 20)) catch |err| {
        std.debug.print("fll: error: cannot read {s}: {t}\n", .{ opts.script_path.?, err });
        return err;
    };
    var scr = script.parse(arena, opts.script_path.?, script_src, &err_msg) catch |err| {
        std.debug.print("fll: error: {s}\n", .{err_msg});
        return err;
    };
    if (opts.version_override) |v| scr.version = v; // decision ar

    var link = resolver.resolve(arena, objs, scr, &err_msg) catch |err| {
        std.debug.print("fll: error: {s}\n", .{err_msg});
        return err;
    };
    relocator.relocate(arena, objs, &link, &err_msg) catch |err| {
        std.debug.print("fll: error: {s}\n", .{err_msg});
        return err;
    };
    const image = emitter.emitFlapp(arena, &link, &err_msg) catch |err| {
        std.debug.print("fll: error: {s}\n", .{err_msg});
        return err;
    };
    try writeFile(io, opts.output, image);

    // .flsym alongside (§8.7, decision bb).
    const flsym_path = try withExtension(arena, opts.output, ".flsym");
    try writeFile(io, flsym_path, try emitter.emitFlsym(arena, &link));

    // Verbose memory map (task 11.9).
    if (opts.verbose) {
        std.debug.print("fll: memory map ({s})\n", .{opts.output});
        std.debug.print("  load address  ${X:0>5}  (file image: header + payload, {d} bytes)\n", .{ link.load_addr, image.len });
        std.debug.print("  entry         ${X:0>5}  (offset {d})\n", .{ link.entry_addr, link.entry_addr - link.load_addr });
        for (link.out) |o| {
            std.debug.print("  {s: <7}       ${X:0>5}..${X:0>5}  {d} bytes{s}\n", .{
                o.name,
                o.base,
                o.base + o.size,
                o.size,
                if (o.stype == .bss) " (no file bytes)" else "",
            });
        }
        std.debug.print("  symbols       {d} \u{2192} {s}\n", .{ link.symbols.len, flsym_path });
    }
}
