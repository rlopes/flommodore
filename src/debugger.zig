//! Flommodore — `debugger.zig` (Block 9).
//!
//! Built-in monitor/debugger — console-first per audit P5 (Phase 7 §7.11:
//! "can also be driven from a text console"); the ImGui overlay (tasks
//! 9.12–9.14) is a documented second pass. This module is SDL-free and
//! host-I/O-free: it operates on the Machine and writes through a
//! `*std.Io.Writer`, so every feature runs under the headless
//! `zig build test`. main.zig owns stdin/SDL and drives it.
//!
//! Execution model: the debugger never runs the CPU from inside a command.
//! Commands only set state (paused/running, step budget, temporary
//! breakpoint); main.zig then drives `runSlice`, which advances the
//! machine through the SAME `Machine.stepFrameCycle` path as free
//! running — paused, stepped, and full-speed execution are bit-identical
//! in timing, and main keeps its frame-boundary duties (present, audio,
//! pacing) in exactly one place.
//!
//! Implementation decisions (continuing the f–l series):
//!   k. A trap (illegal word / privilege violation — the "BRK
//!      instruction" of Phase 7 §7.11) breaks into the debugger only when
//!      the debugger is ARMED (`--debug` or F12). Unarmed, traps vector
//!      architecturally (D35, v1.2 privilege matrix) — guest programs and
//!      the Block 3 test ROMs use them deliberately. The stop happens
//!      AFTER delivery: PC shown is the handler entry.
//!   l. (bus.zig) Watchpoints observe bus accesses: fetches count as
//!      reads; the D47 byte-write RMW counts as a write only.
//!   m. The memory viewer and disassembly read through a side-effect-free
//!      peek path (io.peek16 for KDATA) and never touch the bus — so
//!      inspecting memory can neither dequeue the keyboard queue nor
//!      trigger the user's own watchpoints.

const std = @import("std");
const util = @import("util");
const encode = @import("encode");
const cpu_mod = @import("cpu");
const bus_mod = @import("bus");
const io_mod = @import("io");
const machine_mod = @import("machine");
const disasm = @import("disasm");

const Machine = machine_mod.Machine;

pub const max_breakpoints = 16;

pub const StopReason = union(enum) {
    /// `--debug` startup pause, F12, or a scripted pause request.
    user,
    breakpoint: u32,
    /// Step-over's temporary breakpoint (return address).
    step_over: u32,
    watchpoint: bus_mod.WatchSet.Hit,
    /// Step budget exhausted (`s [n]`).
    step_done,
    /// CPU trapped (illegal word / privilege) — PC is the handler entry.
    trap,
};

pub const RunResult = struct {
    frame_done: bool,
    stopped: bool,
};

const Symbol = struct { addr: u32, name: []u8 };

pub const Debugger = struct {
    gpa: std.mem.Allocator,
    m: *Machine,

    /// Armed = the user asked for a debugger (`--debug` or F12). Only an
    /// armed debugger intercepts traps (decision k) or costs any cycles.
    armed: bool = false,
    paused: bool = false,
    quit: bool = false,
    /// Set by main on F12/console pause; consumed at the next boundary.
    pause_requested: bool = false,

    breakpoints: [max_breakpoints]u32 = undefined,
    bp_count: usize = 0,
    watches: bus_mod.WatchSet = .{},

    /// Mid-frame position while paused; null between frames.
    frame: ?Machine.FrameState = null,
    /// Stop after this many machine steps (single-step / `s n`).
    step_budget: ?u32 = null,
    /// Step-over: one-shot stop at this address (not a user breakpoint).
    temp_bp: ?u32 = null,
    /// Suppress breakpoint matching for the first step after resuming
    /// from a stop, so `c` doesn't re-hit the same breakpoint.
    skip_bp_once: bool = false,

    last_stop: StopReason = .user,
    symbols: std.ArrayList(Symbol) = .empty,
    /// Scratch for symSuffix — one annotation is alive at a time.
    sym_buf: [80]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, m: *Machine) Debugger {
        return .{ .gpa = gpa, .m = m };
    }

    pub fn deinit(dbg: *Debugger) void {
        for (dbg.symbols.items) |s| dbg.gpa.free(s.name);
        dbg.symbols.deinit(dbg.gpa);
        if (dbg.m.bus.watch == &dbg.watches) dbg.m.bus.watch = null;
    }

    /// Point the bus at this debugger's watch set. `dbg` must therefore
    /// live at a stable address for the machine's lifetime.
    pub fn attach(dbg: *Debugger) void {
        dbg.m.bus.watch = &dbg.watches;
    }

    pub fn arm(dbg: *Debugger) void {
        dbg.armed = true;
    }

    pub fn requestPause(dbg: *Debugger) void {
        dbg.armed = true;
        dbg.pause_requested = true;
    }

    // ------------------------------------------------------------------
    // Execution driver (tasks 9.6/9.7/9.8/9.9/9.10). Called by main once
    // per host frame while running; returns at a frame boundary or a stop.
    // ------------------------------------------------------------------

    pub fn runSlice(dbg: *Debugger) RunResult {
        if (dbg.frame == null) dbg.frame = dbg.m.beginFrame();
        const fs = &dbg.frame.?;
        while (true) {
            // Boundary checks before the step executes.
            if (dbg.pause_requested) {
                dbg.pause_requested = false;
                return dbg.stop(.user, false);
            }
            if (!dbg.m.cpu.halted) {
                const pc = dbg.m.cpu.pc;
                if (dbg.temp_bp) |t| {
                    if (pc == t and !dbg.skip_bp_once) {
                        dbg.temp_bp = null;
                        return dbg.stop(.{ .step_over = t }, false);
                    }
                }
                if (!dbg.skip_bp_once) {
                    for (dbg.breakpoints[0..dbg.bp_count]) |bp| {
                        if (bp == pc) return dbg.stop(.{ .breakpoint = bp }, false);
                    }
                }
            }
            dbg.skip_bp_once = false;

            const r = dbg.m.stepFrameCycle(fs);
            if (r.frame_done) dbg.frame = null;

            // Post-step checks: the step that just ran may have tripped
            // a watchpoint, trapped, or exhausted the step budget.
            if (dbg.watches.hit) |hit| {
                dbg.watches.hit = null;
                return dbg.stop(.{ .watchpoint = hit }, r.frame_done);
            }
            if (r.event == .trapped) {
                return dbg.stop(.trap, r.frame_done); // decision k: armed-only path
            }
            if (dbg.step_budget) |budget| {
                if (budget <= 1) {
                    dbg.step_budget = null;
                    return dbg.stop(.step_done, r.frame_done);
                }
                dbg.step_budget = budget - 1;
            }
            if (r.frame_done) return .{ .frame_done = true, .stopped = false };
        }
    }

    fn stop(dbg: *Debugger, reason: StopReason, frame_done: bool) RunResult {
        dbg.paused = true;
        dbg.step_budget = null;
        dbg.last_stop = reason;
        return .{ .frame_done = frame_done, .stopped = true };
    }

    // ------------------------------------------------------------------
    // Console commands (task 9.2 prompt handling lives in main.zig).
    // ------------------------------------------------------------------

    pub fn execute(dbg: *Debugger, line: []const u8, out: *std.Io.Writer) void {
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const cmd = it.next() orelse return;
        if (eq(cmd, "h") or eq(cmd, "help") or eq(cmd, "?")) {
            dbg.cmdHelp(out);
        } else if (eq(cmd, "r") or eq(cmd, "regs")) {
            dbg.printRegs(out);
        } else if (eq(cmd, "d") or eq(cmd, "dis")) {
            const addr = dbg.parseAddrArg(&it) orelse dbg.m.cpu.pc;
            const count = parseCount(&it) orelse 8;
            dbg.printDisasm(out, addr, count);
        } else if (eq(cmd, "m") or eq(cmd, "mem")) {
            const addr = dbg.parseAddrArg(&it) orelse {
                p(out, "usage: m ADDR [LEN]\n", .{});
                return;
            };
            const len = parseCount(&it) orelse 64;
            dbg.printMem(out, addr, len);
        } else if (eq(cmd, "s") or eq(cmd, "step")) {
            const n = parseCount(&it) orelse 1;
            dbg.step_budget = @max(n, 1);
            dbg.resumeRun();
        } else if (eq(cmd, "n") or eq(cmd, "next")) {
            dbg.cmdStepOver(out);
        } else if (eq(cmd, "c") or eq(cmd, "cont")) {
            dbg.resumeRun();
        } else if (eq(cmd, "b") or eq(cmd, "break")) {
            dbg.cmdBreak(&it, out);
        } else if (eq(cmd, "bl")) {
            dbg.cmdBreakList(out);
        } else if (eq(cmd, "bc")) {
            dbg.cmdBreakClear(&it, out);
        } else if (eq(cmd, "w") or eq(cmd, "watch")) {
            dbg.cmdWatch(&it, out);
        } else if (eq(cmd, "wl")) {
            dbg.cmdWatchList(out);
        } else if (eq(cmd, "wc")) {
            dbg.cmdWatchClear(&it, out);
        } else if (eq(cmd, "sym")) {
            dbg.cmdSymList(out);
        } else if (eq(cmd, "q") or eq(cmd, "quit")) {
            dbg.quit = true;
        } else {
            p(out, "unknown command '{s}' — h for help\n", .{cmd});
        }
    }

    fn cmdHelp(dbg: *Debugger, out: *std.Io.Writer) void {
        _ = dbg;
        p(out,
            \\  r                registers        s [N]      step N instructions
            \\  d [ADDR] [N]     disassemble      n          step over CALL/CALLA
            \\  m ADDR [LEN]     memory dump      c          continue
            \\  b ADDR           set breakpoint   bl / bc N|all   list / clear
            \\  w ADDR [r|w|rw]  set watchpoint   wl / wc N|all   list / clear
            \\  sym              list symbols     q          quit emulator
            \\  ADDR = $hex, decimal, or a symbol name
            \\
        , .{});
    }

    /// Resume full-speed execution (`c`, or F12 from main.zig). Skips
    /// breakpoint matching for the first step so the stop that brought us
    /// here isn't immediately re-hit.
    pub fn resumeRun(dbg: *Debugger) void {
        dbg.paused = false;
        dbg.skip_bp_once = true;
    }

    /// Task 9.10: CALL/CALLA are stepped over via a one-shot stop at the
    /// return address; anything else degrades to a single step.
    fn cmdStepOver(dbg: *Debugger, out: *std.Io.Writer) void {
        const pc = dbg.m.cpu.pc;
        const word = dbg.peek32(pc);
        const call_like = if (cpu_mod.decode(word)) |d|
            d.op == .call or d.op == .calla
        else |_|
            false;
        if (call_like) {
            dbg.temp_bp = util.maskAddr(pc +% 4);
            dbg.resumeRun();
        } else {
            _ = out;
            dbg.step_budget = 1;
            dbg.resumeRun();
        }
    }

    fn cmdBreak(dbg: *Debugger, it: *Tokens, out: *std.Io.Writer) void {
        const addr = dbg.parseAddrArg(it) orelse {
            p(out, "usage: b ADDR\n", .{});
            return;
        };
        for (dbg.breakpoints[0..dbg.bp_count]) |bp| {
            if (bp == addr) {
                p(out, "breakpoint already set at ${X:0>5}\n", .{addr});
                return;
            }
        }
        if (dbg.bp_count == max_breakpoints) {
            p(out, "all {d} breakpoints in use (Phase 7 §7.11 limit)\n", .{max_breakpoints});
            return;
        }
        dbg.breakpoints[dbg.bp_count] = addr;
        dbg.bp_count += 1;
        p(out, "breakpoint {d} at ${X:0>5}{s}\n", .{ dbg.bp_count - 1, addr, dbg.symSuffix(addr) });
    }

    fn cmdBreakList(dbg: *Debugger, out: *std.Io.Writer) void {
        if (dbg.bp_count == 0) {
            p(out, "no breakpoints\n", .{});
            return;
        }
        for (dbg.breakpoints[0..dbg.bp_count], 0..) |bp, i| {
            p(out, "  {d}: ${X:0>5}{s}\n", .{ i, bp, dbg.symSuffix(bp) });
        }
    }

    fn cmdBreakClear(dbg: *Debugger, it: *Tokens, out: *std.Io.Writer) void {
        const arg = it.next() orelse {
            p(out, "usage: bc INDEX|all\n", .{});
            return;
        };
        if (eq(arg, "all")) {
            dbg.bp_count = 0;
            p(out, "all breakpoints cleared\n", .{});
            return;
        }
        const idx = std.fmt.parseInt(usize, arg, 10) catch {
            p(out, "bad index '{s}'\n", .{arg});
            return;
        };
        if (idx >= dbg.bp_count) {
            p(out, "no breakpoint {d}\n", .{idx});
            return;
        }
        // Order-preserving removal keeps listed indices stable-ish.
        std.mem.copyForwards(u32, dbg.breakpoints[idx .. dbg.bp_count - 1], dbg.breakpoints[idx + 1 .. dbg.bp_count]);
        dbg.bp_count -= 1;
        p(out, "breakpoint {d} cleared\n", .{idx});
    }

    fn cmdWatch(dbg: *Debugger, it: *Tokens, out: *std.Io.Writer) void {
        const addr = dbg.parseAddrArg(it) orelse {
            p(out, "usage: w ADDR [r|w|rw]\n", .{});
            return;
        };
        const kind = it.next() orelse "rw";
        const on_read = std.mem.indexOfScalar(u8, kind, 'r') != null;
        const on_write = std.mem.indexOfScalar(u8, kind, 'w') != null;
        if (!on_read and !on_write) {
            p(out, "kind must be r, w, or rw\n", .{});
            return;
        }
        if (dbg.watches.count == bus_mod.WatchSet.max) {
            p(out, "all {d} watchpoints in use\n", .{bus_mod.WatchSet.max});
            return;
        }
        dbg.watches.entries[dbg.watches.count] = .{ .addr = addr, .on_read = on_read, .on_write = on_write };
        dbg.watches.count += 1;
        p(out, "watchpoint {d} at ${X:0>5} ({s}{s}){s}\n", .{
            dbg.watches.count - 1,
            addr,
            if (on_read) "r" else @as([]const u8, ""),
            if (on_write) "w" else @as([]const u8, ""),
            dbg.symSuffix(addr),
        });
    }

    fn cmdWatchList(dbg: *Debugger, out: *std.Io.Writer) void {
        if (dbg.watches.count == 0) {
            p(out, "no watchpoints\n", .{});
            return;
        }
        for (dbg.watches.entries[0..dbg.watches.count], 0..) |e, i| {
            p(out, "  {d}: ${X:0>5} ({s}{s}){s}\n", .{
                i,
                e.addr,
                if (e.on_read) "r" else @as([]const u8, ""),
                if (e.on_write) "w" else @as([]const u8, ""),
                dbg.symSuffix(e.addr),
            });
        }
    }

    fn cmdWatchClear(dbg: *Debugger, it: *Tokens, out: *std.Io.Writer) void {
        const arg = it.next() orelse {
            p(out, "usage: wc INDEX|all\n", .{});
            return;
        };
        if (eq(arg, "all")) {
            dbg.watches.count = 0;
            p(out, "all watchpoints cleared\n", .{});
            return;
        }
        const idx = std.fmt.parseInt(usize, arg, 10) catch {
            p(out, "bad index '{s}'\n", .{arg});
            return;
        };
        if (idx >= dbg.watches.count) {
            p(out, "no watchpoint {d}\n", .{idx});
            return;
        }
        std.mem.copyForwards(
            bus_mod.WatchSet.Entry,
            dbg.watches.entries[idx .. dbg.watches.count - 1],
            dbg.watches.entries[idx + 1 .. dbg.watches.count],
        );
        dbg.watches.count -= 1;
        p(out, "watchpoint {d} cleared\n", .{idx});
    }

    // ------------------------------------------------------------------
    // Views (tasks 9.3/9.4/9.5).
    // ------------------------------------------------------------------

    pub fn printRegs(dbg: *Debugger, out: *std.Io.Writer) void {
        const c = &dbg.m.cpu;
        var i: u32 = 0;
        while (i < 16) : (i += 4) {
            p(out, "  R{d: <2}=${X:0>5}  R{d: <2}=${X:0>5}  R{d: <2}=${X:0>5}  R{d: <2}=${X:0>5}\n", .{
                i,
                c.getReg(@intCast(i)),
                i + 1,
                c.getReg(@intCast(i + 1)),
                i + 2,
                c.getReg(@intCast(i + 2)),
                i + 3,
                c.getReg(@intCast(i + 3)),
            });
        }
        var fl: [6]u8 = undefined;
        fl[0] = if (c.flags & cpu_mod.flag_s != 0) 'S' else 's';
        fl[1] = if (c.flags & cpu_mod.flag_i != 0) 'I' else 'i';
        fl[2] = if (c.flags & cpu_mod.flag_v != 0) 'V' else 'v';
        fl[3] = if (c.flags & cpu_mod.flag_c != 0) 'C' else 'c';
        fl[4] = if (c.flags & cpu_mod.flag_n != 0) 'N' else 'n';
        fl[5] = if (c.flags & cpu_mod.flag_z != 0) 'Z' else 'z';
        p(out, "  PC=${X:0>5}  FLAGS={s}  SP=${X:0>5}  LR=${X:0>5}\n", .{
            c.pc,
            &fl,
            c.getReg(cpu_mod.Gab16.sp),
            c.getReg(cpu_mod.Gab16.lr),
        });
        p(out, "  SSP=${X:0>5} USP=${X:0>5} IVT=${X:0>5} CYC={d}{s}\n", .{
            c.ssp,
            c.usp,
            c.ivt,
            c.cyc,
            if (c.halted) " [halted]" else "",
        });
    }

    pub fn printDisasm(dbg: *Debugger, out: *std.Io.Writer, start: u32, count: u32) void {
        var addr = start;
        var n: u32 = 0;
        while (n < count) : (n += 1) {
            const word = dbg.peek32(addr);
            var buf: [48]u8 = undefined;
            const line = disasm.disassemble(word, addr, &buf);
            const marker: []const u8 = if (addr == dbg.m.cpu.pc) ">" else " ";
            // Label line when a symbol sits exactly here.
            if (dbg.symAt(addr)) |name| p(out, "{s}:\n", .{name});
            p(out, "{s} ${X:0>5}  {X:0>8}  {s}", .{ marker, addr, word, line.text });
            if (line.target) |t| p(out, "{s}", .{dbg.symSuffix(t)});
            p(out, "\n", .{});
            addr = util.maskAddr(addr +% 4);
        }
    }

    pub fn printMem(dbg: *Debugger, out: *std.Io.Writer, start: u32, len: u32) void {
        var addr = start & ~@as(u32, 0xF); // row-align like every monitor
        const end = start +% len;
        while (addr < end or addr < start) : (addr = util.maskAddr(addr +% 16)) {
            var bytes: [16]u8 = undefined;
            for (&bytes, 0..) |*b, i| b.* = dbg.peek8(addr +% @as(u32, @intCast(i)));
            p(out, "  ${X:0>5} ", .{addr});
            for (bytes, 0..) |b, i| {
                p(out, "{s}{X:0>2}", .{ if (i == 8) "  " else " ", b });
            }
            p(out, "  |", .{});
            for (bytes) |b| {
                p(out, "{c}", .{if (b >= 0x20 and b < 0x7F) b else '.'});
            }
            p(out, "|\n", .{});
            if (addr +% 16 >= end and addr +% 16 > addr) break;
        }
    }

    pub fn reportStop(dbg: *Debugger, out: *std.Io.Writer) void {
        switch (dbg.last_stop) {
            .user => p(out, "* paused\n", .{}),
            .breakpoint => |a| p(out, "* breakpoint at ${X:0>5}{s}\n", .{ a, dbg.symSuffix(a) }),
            .step_over => |a| p(out, "* stepped over to ${X:0>5}\n", .{a}),
            .watchpoint => |h| p(out, "* watchpoint ${X:0>5} ({s}){s}\n", .{
                h.watch_addr,
                @tagName(h.kind),
                dbg.symSuffix(h.watch_addr),
            }),
            .step_done => {},
            .trap => p(out, "* trap delivered (illegal word or privilege violation, D35)\n", .{}),
        }
        dbg.printDisasm(out, dbg.m.cpu.pc, 1);
    }

    // ------------------------------------------------------------------
    // Symbols (.flsym, task 9.11 / master spec §8.7).
    // ------------------------------------------------------------------

    /// Parse `.flsym` text: one `$address  name` per line. Blank lines and
    /// `;` comments tolerated. Returns the number of symbols loaded.
    pub fn loadSymbols(dbg: *Debugger, text: []const u8) !usize {
        var loaded: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            var it = std.mem.tokenizeAny(u8, raw, " \t\r");
            const addr_tok = it.next() orelse continue;
            if (addr_tok[0] == ';') continue;
            const name = it.next() orelse continue;
            const addr = parseNumber(addr_tok) orelse continue;
            const copy = try dbg.gpa.dupe(u8, name);
            errdefer dbg.gpa.free(copy);
            try dbg.symbols.append(dbg.gpa, .{ .addr = util.maskAddr(addr), .name = copy });
            loaded += 1;
        }
        // Sorted by address: nearest-below annotation is a bounded scan.
        std.mem.sort(Symbol, dbg.symbols.items, {}, struct {
            fn lt(_: void, a: Symbol, b: Symbol) bool {
                return a.addr < b.addr;
            }
        }.lt);
        return loaded;
    }

    fn cmdSymList(dbg: *Debugger, out: *std.Io.Writer) void {
        if (dbg.symbols.items.len == 0) {
            p(out, "no symbols loaded (--sym file.flsym, or a .flsym beside the .flapp)\n", .{});
            return;
        }
        for (dbg.symbols.items) |s| {
            p(out, "  ${X:0>5}  {s}\n", .{ s.addr, s.name });
        }
    }

    fn symAt(dbg: *const Debugger, addr: u32) ?[]const u8 {
        for (dbg.symbols.items) |s| {
            if (s.addr == addr) return s.name;
        }
        return null;
    }

    /// " <name>" or " <name+$off>" (nearest symbol at or below, within
    /// $400 bytes), or "" — appended after addresses in every view.
    fn symSuffix(dbg: *Debugger, addr: u32) []const u8 {
        var best: ?Symbol = null;
        for (dbg.symbols.items) |s| {
            if (s.addr <= addr) best = s else break; // sorted
        }
        const s = best orelse return "";
        const off = addr - s.addr;
        if (off >= 0x400) return "";
        if (off == 0) {
            return std.fmt.bufPrint(&dbg.sym_buf, " <{s}>", .{s.name}) catch "";
        }
        return std.fmt.bufPrint(&dbg.sym_buf, " <{s}+${X}>", .{ s.name, off }) catch "";
    }

    // ------------------------------------------------------------------
    // Side-effect-free memory access (decision m) — mirrors bus routing
    // without watch checks or the KDATA dequeue.
    // ------------------------------------------------------------------

    pub fn peek8(dbg: *const Debugger, addr_in: u32) u8 {
        const addr = util.maskAddr(addr_in);
        return switch (bus_mod.regionOf(addr)) {
            .ram => dbg.m.ram.readByte(addr),
            .io => @truncate(dbg.m.io.peek16(addr)),
            .open_bus => 0x00,
            .rom => if (dbg.m.bus.shadowEnabled())
                dbg.m.ram.readByte(bus_mod.shadow_base + (addr - bus_mod.rom_base))
            else
                dbg.m.rom.readByte(addr - bus_mod.rom_base),
        };
    }

    fn peek32(dbg: *const Debugger, addr: u32) u32 {
        var v: u32 = 0;
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            v |= @as(u32, dbg.peek8(addr +% i)) << @intCast(8 * i);
        }
        return v;
    }

    // ------------------------------------------------------------------
    // Parsing helpers.
    // ------------------------------------------------------------------

    const Tokens = std.mem.TokenIterator(u8, .any);

    fn parseAddrArg(dbg: *Debugger, it: *Tokens) ?u32 {
        const tok = it.next() orelse return null;
        // Symbol name first (exact), then numeric.
        for (dbg.symbols.items) |s| {
            if (std.mem.eql(u8, s.name, tok)) return s.addr;
        }
        return if (parseNumber(tok)) |n| util.maskAddr(n) else null;
    }
};

fn parseNumber(tok: []const u8) ?u32 {
    if (tok.len == 0) return null;
    if (tok[0] == '$') return std.fmt.parseInt(u32, tok[1..], 16) catch null;
    if (std.mem.startsWith(u8, tok, "0x")) return std.fmt.parseInt(u32, tok[2..], 16) catch null;
    return std.fmt.parseInt(u32, tok, 10) catch null;
}

fn parseCount(it: *Debugger.Tokens) ?u32 {
    const tok = it.next() orelse return null;
    return parseNumber(tok);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Console output must never abort the debugger — swallow writer errors.
fn p(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    out.print(fmt, args) catch {};
}

// ---------------------------------------------------------------------------
// Tests — a small ROM built with encode.zig, driven entirely headlessly.
// ---------------------------------------------------------------------------

const testing = std.testing;
const rom_mod = @import("rom");

/// ROM under test:
///   $FC200 entry: LI R1,$11 / LI R2,$22 / CALLA $FC300 / LI R4,$44 /
///                 SW [R0+$90],R4 / LW R5,[R0+$90] / spin: JMPA spin
///   $FC300 sub:   LI R3,$33 / RET
fn testMachine() !*Machine {
    const m = try Machine.create(testing.allocator);
    errdefer m.destroy(testing.allocator);
    var image: [rom_mod.size]u8 = @splat(0);
    std.mem.writeInt(u32, image[rom_mod.vectors_offset..][0..4], 0xFC200, .little);
    const code = [_]u32{
        encode.li(1, 0x11), //      $FC200
        encode.li(2, 0x22), //      $FC204
        encode.calla(0xFC300), //   $FC208
        encode.li(4, 0x44), //      $FC20C  (step-over return address)
        encode.sw(0, 0x90, 4), //   $FC210
        encode.lw(5, 0, 0x90), //   $FC214
        encode.jmpa(0xFC218), //    $FC218  spin
    };
    for (code, 0..) |w, i| {
        std.mem.writeInt(u32, image[0x200 + 4 * i ..][0..4], w, .little);
    }
    const sub = [_]u32{ encode.li(3, 0x33), encode.ret() };
    for (sub, 0..) |w, i| {
        std.mem.writeInt(u32, image[0x300 + 4 * i ..][0..4], w, .little);
    }
    try m.rom.loadFromSlice(&image);
    m.cpu.reset(&m.bus);
    return m;
}

test "9.6/9.9 step budget and continue-over-breakpoint" {
    const m = try testMachine();
    defer m.destroy(testing.allocator);
    var dbg = Debugger.init(testing.allocator, m);
    defer dbg.deinit();
    dbg.attach();
    dbg.arm();

    // Two single steps execute exactly the two LIs.
    dbg.step_budget = 2;
    var r = dbg.runSlice();
    try testing.expect(r.stopped and !r.frame_done);
    try testing.expectEqual(StopReason.step_done, dbg.last_stop);
    try testing.expectEqual(@as(u32, 0xFC208), m.cpu.pc);
    try testing.expectEqual(@as(u32, 0x11), m.cpu.getReg(1));
    try testing.expectEqual(@as(u32, 0x22), m.cpu.getReg(2));

    // Breakpoint at the spin loop; continue reaches it once, and a second
    // continue must NOT re-hit it without executing (skip_bp_once)…
    dbg.breakpoints[0] = 0xFC218;
    dbg.bp_count = 1;
    dbg.resumeRun();
    r = dbg.runSlice();
    try testing.expect(r.stopped);
    try testing.expectEqual(StopReason{ .breakpoint = 0xFC218 }, dbg.last_stop);
    try testing.expectEqual(@as(u32, 0x33), m.cpu.getReg(3)); // subroutine ran
    // …it re-hits after the JMPA executes back to the same address.
    dbg.resumeRun();
    r = dbg.runSlice();
    try testing.expect(r.stopped);
    try testing.expectEqual(StopReason{ .breakpoint = 0xFC218 }, dbg.last_stop);
}

test "9.10 step over CALLA lands at the return address, subroutine completed" {
    const m = try testMachine();
    defer m.destroy(testing.allocator);
    var dbg = Debugger.init(testing.allocator, m);
    defer dbg.deinit();
    dbg.attach();
    dbg.arm();

    dbg.step_budget = 2; // stop AT the CALLA
    _ = dbg.runSlice();
    try testing.expectEqual(@as(u32, 0xFC208), m.cpu.pc);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    dbg.execute("n", &w);
    const r = dbg.runSlice();
    try testing.expect(r.stopped);
    try testing.expectEqual(StopReason{ .step_over = 0xFC20C }, dbg.last_stop);
    try testing.expectEqual(@as(u32, 0xFC20C), m.cpu.pc);
    try testing.expectEqual(@as(u32, 0x33), m.cpu.getReg(3));
}

test "9.8 watchpoint stops the run at the guilty access" {
    const m = try testMachine();
    defer m.destroy(testing.allocator);
    var dbg = Debugger.init(testing.allocator, m);
    defer dbg.deinit();
    dbg.attach();
    dbg.arm();

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    dbg.execute("w $90 w", &w); // write watch on $00090
    dbg.execute("c", &w);
    var r = dbg.runSlice();
    try testing.expect(r.stopped);
    try testing.expectEqual(bus_mod.WatchKind.write, dbg.last_stop.watchpoint.kind);
    try testing.expectEqual(@as(u32, 0x00090), dbg.last_stop.watchpoint.watch_addr);
    // The SW at $FC210 executed; PC is past it.
    try testing.expectEqual(@as(u32, 0xFC214), m.cpu.pc);

    // Watch reads too: the LW right after trips a fresh rw watch.
    dbg.execute("wc all", &w);
    dbg.execute("w $90 r", &w);
    dbg.execute("c", &w);
    r = dbg.runSlice();
    try testing.expect(r.stopped);
    try testing.expectEqual(bus_mod.WatchKind.read, dbg.last_stop.watchpoint.kind);
}

test "9.7 breakpoint limit and command management" {
    const m = try testMachine();
    defer m.destroy(testing.allocator);
    var dbg = Debugger.init(testing.allocator, m);
    defer dbg.deinit();

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var i: u32 = 0;
    while (i < max_breakpoints) : (i += 1) {
        var cmd_buf: [32]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "b ${X}", .{0xFC200 + 4 * i}) catch unreachable;
        dbg.execute(cmd, &w);
    }
    try testing.expectEqual(@as(usize, 16), dbg.bp_count);
    dbg.execute("b $FC300", &w); // 17th must be refused
    try testing.expectEqual(@as(usize, 16), dbg.bp_count);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "in use") != null);
    dbg.execute("bc 0", &w);
    try testing.expectEqual(@as(usize, 15), dbg.bp_count);
    dbg.execute("bc all", &w);
    try testing.expectEqual(@as(usize, 0), dbg.bp_count);
}

test "9.3/9.4/9.5 views: registers, disassembly with PC marker, memory dump" {
    const m = try testMachine();
    defer m.destroy(testing.allocator);
    var dbg = Debugger.init(testing.allocator, m);
    defer dbg.deinit();

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    dbg.execute("r", &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "PC=$FC200") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "FLAGS=Sivcnz") != null);

    w = std.Io.Writer.fixed(&buf);
    dbg.execute("d", &w); // defaults to PC
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "> $FC200") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "LI    R1, $0011") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "CALLA $FC300") != null);

    // Memory dump: write a recognisable string into RAM first.
    for ("FLOM", 0..) |ch, i| m.ram.writeByte(0x00100 + @as(u32, @intCast(i)), ch);
    w = std.Io.Writer.fixed(&buf);
    dbg.execute("m $100 16", &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "$00100  46 4C 4F 4D") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "|FLOM") != null);
}

test "9.11 symbols: .flsym parse, name resolution, annotation" {
    const m = try testMachine();
    defer m.destroy(testing.allocator);
    var dbg = Debugger.init(testing.allocator, m);
    defer dbg.deinit();

    const flsym =
        \\$FC200  start
        \\; comment line
        \\$FC300  sub_hello
        \\
    ;
    try testing.expectEqual(@as(usize, 2), try dbg.loadSymbols(flsym));

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    dbg.execute("d start 3", &w); // symbol resolves as an address argument
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "start:") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "CALLA $FC300 <sub_hello>") != null);

    w = std.Io.Writer.fixed(&buf);
    dbg.execute("b sub_hello", &w);
    try testing.expectEqual(@as(u32, 0xFC300), dbg.breakpoints[0]);

    // Nearest-below annotation with offset.
    w = std.Io.Writer.fixed(&buf);
    dbg.execute("d $FC204 1", &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "$FC204") != null);
}

test "9.2 trap breaks in when armed (decision k); memory viewer is side-effect-free" {
    const m = try testMachine();
    defer m.destroy(testing.allocator);
    var dbg = Debugger.init(testing.allocator, m);
    defer dbg.deinit();
    dbg.attach();
    dbg.arm();

    // Jump the CPU into zeroed ROM: the $00000000 word traps (D35).
    m.cpu.pc = 0xFC400;
    _ = dbg.runSlice();
    try testing.expectEqual(StopReason.trap, dbg.last_stop);

    // KDATA peek does not dequeue, and does not trip watchpoints.
    m.io.keyEvent(0x0004);
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    dbg.execute("w $80021 rw", &w);
    dbg.execute("m $80020 8", &w);
    try testing.expectEqual(@as(?bus_mod.WatchSet.Hit, null), dbg.watches.hit);
    try testing.expectEqual(@as(u16, 0x0004), m.io.peek16(io_mod.kdata_addr));
    try testing.expectEqual(@as(u16, 0x0004), m.io.read16(io_mod.kdata_addr)); // still queued
}
