//! flas codegen — expanded AST → sections/symbols/relocations
//! (Block 10, tasks 10.4–10.8).
//!
//! Two passes over the macro-expanded AST:
//!   Pass 1 — mode rule (10.4), section layout, label collection, sizing.
//!   Pass 2 — emission (10.6): EVERY instruction word comes from
//!            encode.zig's per-mnemonic wrappers; this module contains NO
//!            encoding table (audit P1). Data directives (10.8) and
//!            relocation recording (10.7) happen here too.
//!
//! Mode rule (amendment v1.1 §8.5, task 10.4): the first ORG makes the file
//! ABSOLUTE, the first SECTION makes it RELOCATABLE; mixing is an error.
//! Absolute files fold every symbol at assembly time and emit no
//! relocations — that is how test ROMs are built.
//!
//! Implementation decisions (continuing macro.zig's w–z):
//!   (aa) Absolute mode: each ORG opens a new output section named
//!        "abs0".."absN" (fits the 8-byte name field), type code, with the
//!        ORG value as load address. Emitting anything before the first
//!        ORG/SECTION is an error (no location counter exists yet).
//!        Repeating `SECTION name` reopens (appends to) that section.
//!   (ab) ORG/DS/ALIGN/EQU argument expressions evaluate during pass 1 at
//!        their source position, so they may reference only symbols
//!        already defined (EQU constants and earlier labels). All other
//!        expressions (instruction operands, DB/DW/DD data) evaluate in
//!        pass 2 against the full symbol table — forward label references
//!        work there.
//!   (ac) Fit rule for signed fields: a u32 value fits either as an
//!        unsigned value in the field's positive range or as a
//!        two's-complement sign-extension of the field width (so the `-1`
//!        of parser decision t encodes in IMM18/DB/DW). Anything else is a
//!        range error naming the field.
//!   (ad) Relocatable-symbol expressions: the .flobj relocation entry has
//!        NO ADDEND FIELD (§8.4), so only patterns the six reloc types can
//!        express are representable: a BARE symbol (ABS16 in DW, ABS32 in
//!        DD, ABS26 in JMPA/CALLA, PCREL26 in branches), `(sym & $FFFF)`
//!        (LO16, I-format imm) and `(sym >> 16)` (HI4, I-format imm). A
//!        bare relocatable symbol in an I-format immediate is an error
//!        directing the user to the two patterns. Branches to a DEFINED
//!        symbol in the SAME section fold even in relocatable mode
//!        (PC-relative distance is link-invariant); everything else
//!        relocates. In absolute mode all of this folds to numbers.
//!   (ae) Undefined symbols: error in absolute mode; in relocatable mode
//!        they become external symbol entries (section index $FF,
//!        offset 0, global) referenced by relocations.
//!   (af) The MFSR/MTSR sreg operand accepts the encode.Sreg names
//!        (case-insensitive) or an expression evaluating to 0–5.
//!   (ag) bss sections accept only labels, DS, and ALIGN (no initialized
//!        data — their payload is empty and only `size` is recorded). DS
//!        zero-fills in code/data sections. ALIGN pads with zero bytes to
//!        the next multiple of its argument (which must be ≥ 1).
//!   (ah) INCBIN bytes come from a caller-provided loader map (path →
//!        bytes); codegen performs no file I/O. INCLUDE must be resolved
//!        by the driver before codegen and is an error here.
//!   (ai) Symbol table flags: labels are global (1) except macro-instance
//!        labels (containing ".@", macro decision z) which are local (0).
//!        EQU constants are assembler-internal and never emitted — the
//!        symbol entry format has no way to express a section-less
//!        absolute value.

const std = @import("std");
const parser = @import("parser");
const encode = @import("encode");

pub const Error = error{ Codegen, OutOfMemory };

const Item = parser.Item;
const Operand = parser.Operand;
const Expr = parser.Expr;

pub const Mode = enum { undecided, absolute, relocatable };

pub const SectionType = enum(u8) { code = 0, data = 1, bss = 2 };

pub const Section = struct {
    name: [8]u8, // null-padded (§8.4)
    stype: SectionType,
    load_addr: u32, // 0 = relocatable
    data: std.ArrayList(u8) = .empty, // empty for bss
    size: u32 = 0, // includes bss size
};

pub const Symbol = struct {
    name: []const u8,
    section: u8, // $FF = external/undefined (decision ae)
    offset: u32,
    flags: u8, // global=1, local=0
};

pub const external_section: u8 = 0xFF;

pub const RelocType = enum(u8) {
    abs16 = 0,
    abs32 = 1,
    abs26 = 2,
    pcrel26 = 3,
    lo16 = 4,
    hi4 = 5,
};

pub const Reloc = struct {
    section: u8, // section containing the patch site
    offset: u32, // offset within that section
    symbol: u16, // index into `symbols`
    rtype: RelocType,
};

/// One listing row source (task 10.10): recorded during pass 2 so the
/// .flst writer can render address/bytes/source without replaying layout.
pub const ListingKind = enum { instr, data, label };

pub const ListingEntry = struct {
    kind: ListingKind,
    line: u32, // 1-based source line
    section: u8,
    offset: u32,
    size: u32, // 4 for instructions, byte count for data, 0 for labels
    name: []const u8 = "", // label name (kind == .label)
};

pub const Object = struct {
    mode: Mode,
    sections: []Section,
    symbols: []Symbol,
    relocs: []Reloc,
    listing: []ListingEntry,
};

/// INCBIN resolution (decision ah): path → file bytes, provided by the
/// driver (or a literal map in tests).
pub const IncbinMap = std.StringHashMapUnmanaged([]const u8);

// ---------------------------------------------------------------------------
// Codegen.
// ---------------------------------------------------------------------------

const LabelInfo = struct { section: u8, offset: u32, sym_index: u16 };

pub const Codegen = struct {
    arena: std.mem.Allocator,
    incbins: *const IncbinMap,

    mode: Mode = .undecided,
    sections: std.ArrayList(Section) = .empty,
    cur: ?u8 = null, // current section index
    org_count: u32 = 0,

    equs: std.StringHashMapUnmanaged(u32) = .empty,
    labels: std.StringHashMapUnmanaged(LabelInfo) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    externals: std.StringHashMapUnmanaged(u16) = .empty,
    relocs: std.ArrayList(Reloc) = .empty,
    listing: std.ArrayList(ListingEntry) = .empty,

    pass: u8 = 1,

    err_msg: []const u8 = "",
    err_line: u32 = 0,
    err_col: u32 = 0,

    pub fn init(arena: std.mem.Allocator, incbins: *const IncbinMap) Codegen {
        return .{ .arena = arena, .incbins = incbins };
    }

    fn fail(g: *Codegen, comptime fmt: []const u8, args: anytype, line: u32, col: u32) Error {
        g.err_msg = std.fmt.allocPrint(g.arena, fmt, args) catch "out of memory formatting diagnostic";
        g.err_line = line;
        g.err_col = col;
        return Error.Codegen;
    }

    pub fn run(g: *Codegen, items: []const Item) Error!Object {
        g.pass = 1;
        try g.walk(items);
        // Reset per-pass state; keep symbols/labels/equs from pass 1.
        for (g.sections.items) |*s| s.size = 0;
        g.cur = null;
        g.org_count = 0;
        g.pass = 2;
        try g.walk(items);
        return .{
            .mode = g.mode,
            .sections = try g.sections.toOwnedSlice(g.arena),
            .symbols = try g.symbols.toOwnedSlice(g.arena),
            .relocs = try g.relocs.toOwnedSlice(g.arena),
            .listing = try g.listing.toOwnedSlice(g.arena),
        };
    }

    fn section(g: *Codegen) Error!*Section {
        const idx = g.cur orelse
            return g.fail("code or data before the first ORG/SECTION — no location counter yet (decision aa)", .{}, 0, 0);
        return &g.sections.items[idx];
    }

    fn walk(g: *Codegen, items: []const Item) Error!void {
        for (items) |item| {
            switch (item.payload) {
                .label => |name| try g.defineLabel(name, item),
                .directive => |d| try g.directive(d.kind, d.args, item),
                .statement => |s| try g.instruction(s.head, s.operands, item),
                .macro_def => return g.fail("macro definition survived expansion — pipeline bug", .{}, item.line, item.col),
            }
        }
        if (g.pass == 1 and g.mode == .undecided)
            g.mode = .absolute; // empty/no-emission file; harmless default
    }

    // -- Sections and labels ----------------------------------------------

    fn sectionName(name: []const u8) [8]u8 {
        var buf: [8]u8 = @splat(0);
        @memcpy(buf[0..@min(name.len, 8)], name[0..@min(name.len, 8)]);
        return buf;
    }

    fn openAbsolute(g: *Codegen, load_addr: u32, item: Item) Error!void {
        switch (g.mode) {
            .relocatable => return g.fail("ORG in a relocatable (SECTION) file — mixing is an error (amendment §8.5)", .{}, item.line, item.col),
            .undecided => g.mode = .absolute,
            .absolute => {},
        }
        if (g.pass == 1) {
            var namebuf: [8]u8 = undefined;
            const n = std.fmt.bufPrint(&namebuf, "abs{d}", .{g.org_count}) catch unreachable;
            try g.sections.append(g.arena, .{
                .name = sectionName(n),
                .stype = .code,
                .load_addr = load_addr,
            });
        }
        g.cur = @intCast(g.org_count);
        g.org_count += 1;
    }

    fn openNamed(g: *Codegen, name: []const u8, item: Item) Error!void {
        switch (g.mode) {
            .absolute => return g.fail("SECTION in an absolute (ORG) file — mixing is an error (amendment §8.5)", .{}, item.line, item.col),
            .undecided => g.mode = .relocatable,
            .relocatable => {},
        }
        const stype: SectionType = if (std.mem.eql(u8, name, "code"))
            .code
        else if (std.mem.eql(u8, name, "data"))
            .data
        else if (std.mem.eql(u8, name, "bss"))
            .bss
        else
            return g.fail("unknown section '{s}' — §8.3 defines code, data, bss", .{name}, item.line, item.col);
        // Reopen if it exists (decision aa).
        for (g.sections.items, 0..) |s, i| {
            if (std.mem.eql(u8, std.mem.sliceTo(&s.name, 0), name)) {
                g.cur = @intCast(i);
                return;
            }
        }
        if (g.pass == 1) {
            try g.sections.append(g.arena, .{
                .name = sectionName(name),
                .stype = stype,
                .load_addr = 0,
            });
            g.cur = @intCast(g.sections.items.len - 1);
        } else unreachable; // pass 2 always finds the pass-1 section
    }

    fn defineLabel(g: *Codegen, name: []const u8, item: Item) Error!void {
        if (g.pass == 2) {
            // Section/offset were validated in pass 1; record the row.
            const sec_idx = g.cur.?;
            try g.listing.append(g.arena, .{
                .kind = .label,
                .line = item.line,
                .section = sec_idx,
                .offset = g.sections.items[sec_idx].size,
                .size = 0,
                .name = name,
            });
            return;
        }
        const sec_idx = g.cur orelse
            return g.fail("label '{s}' before the first ORG/SECTION (decision aa)", .{name}, item.line, item.col);
        if (g.labels.contains(name) or g.equs.contains(name))
            return g.fail("duplicate symbol '{s}'", .{name}, item.line, item.col);
        const sym_index: u16 = @intCast(g.symbols.items.len);
        const local = std.mem.indexOf(u8, name, ".@") != null; // decision ai
        try g.symbols.append(g.arena, .{
            .name = name,
            .section = sec_idx,
            .offset = g.sections.items[sec_idx].size,
            .flags = if (local) 0 else 1,
        });
        try g.labels.put(g.arena, name, .{
            .section = sec_idx,
            .offset = g.sections.items[sec_idx].size,
            .sym_index = sym_index,
        });
    }

    // -- Expression evaluation --------------------------------------------

    const Transform = enum { full, lo16, hi4 };
    const Value = union(enum) {
        num: u32,
        rel: struct { sym_index: u16, transform: Transform },
    };

    /// Pass-1 evaluation (decision ab): numbers, EQU constants, and
    /// already-defined labels only; result is always a number.
    fn evalConst(g: *Codegen, e: *const Expr) Error!u32 {
        return switch (try g.eval(e, true)) {
            .num => |n| n,
            .rel => unreachable, // eval(constant=true) never returns .rel
        };
    }

    fn symbolValue(g: *Codegen, sym: Expr.Sym, constant: bool) Error!Value {
        if (g.equs.get(sym.name)) |v| return .{ .num = v };
        if (g.labels.get(sym.name)) |info| {
            const sec = g.sections.items[info.section];
            if (g.mode == .absolute)
                return .{ .num = sec.load_addr +% info.offset };
            if (constant)
                return g.fail("'{s}' is section-relative and cannot be used here (decision ab)", .{sym.name}, sym.line, sym.col);
            return .{ .rel = .{ .sym_index = info.sym_index, .transform = .full } };
        }
        if (constant or g.mode == .absolute)
            return g.fail("undefined symbol '{s}'{s}", .{
                sym.name,
                if (constant) " (pass-1 expressions may only reference earlier symbols — decision ab)" else "",
            }, sym.line, sym.col);
        // Relocatable mode: external (decision ae).
        const gop = try g.externals.getOrPut(g.arena, sym.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(g.symbols.items.len);
            try g.symbols.append(g.arena, .{
                .name = sym.name,
                .section = external_section,
                .offset = 0,
                .flags = 1,
            });
        }
        return .{ .rel = .{ .sym_index = gop.value_ptr.*, .transform = .full } };
    }

    fn eval(g: *Codegen, e: *const Expr, constant: bool) Error!Value {
        switch (e.*) {
            .number => |n| return .{ .num = n },
            .symbol => |sym| return g.symbolValue(sym, constant),
            .macro_param => |sym| return g.fail("macro parameter '\\{s}' outside a macro body", .{sym.name}, sym.line, sym.col),
            .unary => |u| {
                const sub = try g.eval(u.sub, constant);
                switch (sub) {
                    .num => |n| return .{ .num = switch (u.op) {
                        .neg => 0 -% n,
                        .bit_not => ~n,
                    } },
                    .rel => return g.fail("unary operator on a relocatable symbol is not representable (decision ad)", .{}, 0, 0),
                }
            },
            .binary => |b| {
                const lhs = try g.eval(b.lhs, constant);
                const rhs = try g.eval(b.rhs, constant);
                if (lhs == .num and rhs == .num) {
                    const l = lhs.num;
                    const r = rhs.num;
                    return .{ .num = switch (b.op) {
                        .add => l +% r,
                        .sub => l -% r,
                        .mul => l *% r,
                        .div => if (r == 0) return g.fail("division by zero in expression", .{}, 0, 0) else l / r,
                        .mod => if (r == 0) return g.fail("modulo by zero in expression", .{}, 0, 0) else l % r,
                        .shl => if (r >= 32) 0 else l << @intCast(r),
                        .shr => if (r >= 32) 0 else l >> @intCast(r),
                        .band => l & r,
                        .bxor => l ^ r,
                        .bor => l | r,
                    } };
                }
                // Reloc-pattern recognition (decision ad).
                if (lhs == .rel and rhs == .num and lhs.rel.transform == .full) {
                    if (b.op == .band and rhs.num == 0xFFFF)
                        return .{ .rel = .{ .sym_index = lhs.rel.sym_index, .transform = .lo16 } };
                    if (b.op == .shr and rhs.num == 16)
                        return .{ .rel = .{ .sym_index = lhs.rel.sym_index, .transform = .hi4 } };
                }
                return g.fail("expression on a relocatable symbol — only (sym & $FFFF) and (sym >> 16) are representable (decision ad)", .{}, 0, 0);
            },
        }
    }

    // -- Fit checks (decision ac) ------------------------------------------

    /// Signed-field fit: unsigned within positive range, or a
    /// two's-complement sign-extension of `bits`.
    fn fitSigned(g: *Codegen, v: u32, comptime bits: u5, what: []const u8, op: Operand) Error!i32 {
        const max: u32 = (1 << (bits - 1)) - 1;
        if (v <= max) return @intCast(v);
        const min_bits: u32 = @as(u32, 0) -% (@as(u32, 1) << (bits - 1)); // sign-extended minimum
        if (v >= min_bits) return @bitCast(v);
        return g.fail("value ${X} out of range for {s} (signed {d}-bit)", .{ v, what, bits }, op.line, op.col);
    }

    /// Data-field fit: unsigned within `bits`, or a sign-extension.
    fn fitData(g: *Codegen, v: u32, comptime bits: u6, op: Operand) Error!u32 {
        if (bits == 32) return v;
        const max: u32 = (@as(u32, 1) << @intCast(bits)) - 1;
        if (v <= max) return v;
        const min_bits: u32 = @as(u32, 0) -% (@as(u32, 1) << @intCast(bits - 1));
        if (v >= min_bits) return v & max;
        return g.fail("value ${X} does not fit in {d} bits", .{ v, bits }, op.line, op.col);
    }

    // -- Emission helpers ---------------------------------------------------

    fn emitBytes(g: *Codegen, bytes: []const u8, item: Item) Error!void {
        const sec = try g.section();
        if (sec.stype == .bss and bytes.len > 0) {
            // Callers gate on this too; belt and braces (decision ag).
            return g.fail("initialized data in a bss section (decision ag)", .{}, item.line, item.col);
        }
        if (g.pass == 2 and sec.stype != .bss)
            try sec.data.appendSlice(g.arena, bytes);
        sec.size += @intCast(bytes.len);
    }

    fn emitZeros(g: *Codegen, n: u32) Error!void {
        const sec = try g.section();
        if (g.pass == 2 and sec.stype != .bss)
            try sec.data.appendNTimes(g.arena, 0, n);
        sec.size += n;
    }

    fn emitWord(g: *Codegen, w: u32, item: Item) Error!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, w, .little);
        try g.emitBytes(&buf, item);
    }

    fn addReloc(g: *Codegen, sym_index: u16, rtype: RelocType) Error!void {
        if (g.pass != 2) return;
        const sec_idx = g.cur.?;
        try g.relocs.append(g.arena, .{
            .section = sec_idx,
            .offset = g.sections.items[sec_idx].size,
            .symbol = sym_index,
            .rtype = rtype,
        });
    }

    /// Record a pass-2 listing row for data emitted since `start` (task
    /// 10.10). bss rows are skipped — there is no payload to render.
    fn recordData(g: *Codegen, start: u32, item: Item) Error!void {
        if (g.pass != 2) return;
        const sec_idx = g.cur.?;
        const sec = g.sections.items[sec_idx];
        if (sec.stype == .bss) return;
        if (sec.size == start) return; // nothing emitted (e.g. ALIGN no-op)
        try g.listing.append(g.arena, .{
            .kind = .data,
            .line = item.line,
            .section = sec_idx,
            .offset = start,
            .size = sec.size - start,
        });
    }

    // -- Directives (tasks 10.4, 10.8) --------------------------------------

    fn directive(g: *Codegen, kind: parser.Directive, args: []Operand, item: Item) Error!void {
        switch (kind) {
            .org => {
                if (args.len != 1 or args[0].payload != .expr)
                    return g.fail("ORG takes one address expression", .{}, item.line, item.col);
                const addr = try g.evalConst(args[0].payload.expr);
                try g.openAbsolute(addr, item);
            },
            .section => {
                if (args.len != 1 or args[0].payload != .expr or args[0].payload.expr.* != .symbol)
                    return g.fail("SECTION takes one name (code, data, or bss)", .{}, item.line, item.col);
                try g.openNamed(args[0].payload.expr.symbol.name, item);
            },
            .equ => {
                if (g.pass != 1) return;
                if (args.len != 2 or args[0].payload != .expr or args[0].payload.expr.* != .symbol)
                    return g.fail("EQU takes a name and a value expression", .{}, item.line, item.col);
                const name = args[0].payload.expr.symbol.name;
                if (args[1].payload != .expr)
                    return g.fail("EQU value must be an expression", .{}, item.line, item.col);
                if (g.labels.contains(name) or g.equs.contains(name))
                    return g.fail("duplicate symbol '{s}'", .{name}, item.line, item.col);
                const v = try g.evalConst(args[1].payload.expr);
                try g.equs.put(g.arena, name, v);
            },
            .db, .dw, .dd => |k| {
                const start = (try g.section()).size;
                switch (k) {
                    .db => try g.dataDirective(args, 1, item),
                    .dw => try g.dataDirective(args, 2, item),
                    else => try g.dataDirective(args, 4, item),
                }
                try g.recordData(start, item);
            },
            .ds => {
                if (args.len != 1 or args[0].payload != .expr)
                    return g.fail("DS takes one size expression", .{}, item.line, item.col);
                const n = try g.evalConst(args[0].payload.expr);
                const start = (try g.section()).size;
                try g.emitZeros(n);
                try g.recordData(start, item);
            },
            .@"align" => {
                if (args.len != 1 or args[0].payload != .expr)
                    return g.fail("ALIGN takes one alignment expression", .{}, item.line, item.col);
                const n = try g.evalConst(args[0].payload.expr);
                if (n == 0)
                    return g.fail("ALIGN 0 is invalid (decision ag)", .{}, item.line, item.col);
                const off = (try g.section()).size;
                try g.emitZeros((n - (off % n)) % n);
                try g.recordData(off, item);
            },
            .incbin => {
                if (args.len != 1 or args[0].payload != .string)
                    return g.fail("INCBIN takes one quoted path", .{}, item.line, item.col);
                const path = args[0].payload.string;
                const bytes = g.incbins.get(path) orelse
                    return g.fail("INCBIN '{s}': file not provided to the assembler (decision ah)", .{path}, item.line, item.col);
                const sec = try g.section();
                if (sec.stype == .bss)
                    return g.fail("initialized data in a bss section (decision ag)", .{}, item.line, item.col);
                const start = sec.size;
                try g.emitBytes(bytes, item);
                try g.recordData(start, item);
            },
            .include => return g.fail("INCLUDE must be resolved before codegen (decision ah) — driver bug", .{}, item.line, item.col),
        }
    }

    fn dataDirective(g: *Codegen, args: []Operand, comptime width: u3, item: Item) Error!void {
        const sec = try g.section();
        if (sec.stype == .bss)
            return g.fail("initialized data in a bss section (decision ag)", .{}, item.line, item.col);
        if (args.len == 0)
            return g.fail("data directive needs at least one value", .{}, item.line, item.col);
        for (args) |op| {
            switch (op.payload) {
                .string => |s| {
                    if (width != 1)
                        return g.fail("string literals are only valid in DB", .{}, op.line, op.col);
                    try g.emitBytes(s, item);
                },
                .expr => |e| {
                    if (g.pass == 1) {
                        try g.emitZeros(width);
                        continue;
                    }
                    switch (try g.eval(e, false)) {
                        .num => |v| {
                            const fitted = try g.fitData(v, @as(u6, width) * 8, op);
                            var buf: [4]u8 = undefined;
                            std.mem.writeInt(u32, &buf, fitted, .little);
                            try g.emitBytes(buf[0..width], item);
                        },
                        .rel => |r| {
                            if (r.transform != .full)
                                return g.fail("LO16/HI4 patterns are for I-format immediates, not data (decision ad)", .{}, op.line, op.col);
                            switch (width) {
                                2 => try g.addReloc(r.sym_index, .abs16),
                                4 => try g.addReloc(r.sym_index, .abs32),
                                else => return g.fail("no relocation type patches an 8-bit value (decision ad)", .{}, op.line, op.col),
                            }
                            const zeros = [_]u8{0} ** 4;
                            try g.emitBytes(zeros[0..width], item);
                        },
                    }
                },
                else => return g.fail("data directives take value expressions{s}", .{if (width == 1) " or strings" else ""}, op.line, op.col),
            }
        }
    }

    // -- Instructions (tasks 10.5/10.6) --------------------------------------

    fn wantReg(g: *Codegen, ops: []Operand, i: usize, item: Item) Error!u4 {
        if (i >= ops.len or ops[i].payload != .register)
            return g.fail("operand {d} must be a register", .{i + 1}, item.line, item.col);
        return ops[i].payload.register;
    }

    const Mem = struct { base: u4, imm: i32, reloc: ?struct { sym_index: u16, rtype: RelocType } };

    fn wantMem(g: *Codegen, ops: []Operand, i: usize, item: Item) Error!Mem {
        if (i >= ops.len or ops[i].payload != .memory)
            return g.fail("operand {d} must be a memory operand [reg + offset]", .{i + 1}, item.line, item.col);
        const m = ops[i].payload.memory;
        if (m.offset == null or g.pass == 1)
            return .{ .base = m.base, .imm = 0, .reloc = null };
        return switch (try g.eval(m.offset.?, false)) {
            .num => |v| .{ .base = m.base, .imm = try g.fitSigned(v, 18, "IMM18", ops[i]), .reloc = null },
            .rel => |r| switch (r.transform) {
                .lo16 => .{ .base = m.base, .imm = 0, .reloc = .{ .sym_index = r.sym_index, .rtype = .lo16 } },
                .hi4 => .{ .base = m.base, .imm = 0, .reloc = .{ .sym_index = r.sym_index, .rtype = .hi4 } },
                .full => g.fail("bare relocatable symbol in an immediate — use (sym & $FFFF) or (sym >> 16) (decision ad)", .{}, ops[i].line, ops[i].col),
            },
        };
    }

    /// I-format immediate operand: number (range-checked) or LO16/HI4
    /// relocation pattern (decision ad).
    fn wantImm(g: *Codegen, ops: []Operand, i: usize, item: Item) Error!Mem {
        if (i >= ops.len or ops[i].payload != .expr)
            return g.fail("operand {d} must be an immediate expression", .{i + 1}, item.line, item.col);
        if (g.pass == 1) return .{ .base = 0, .imm = 0, .reloc = null };
        return switch (try g.eval(ops[i].payload.expr, false)) {
            .num => |v| .{ .base = 0, .imm = try g.fitSigned(v, 18, "IMM18", ops[i]), .reloc = null },
            .rel => |r| switch (r.transform) {
                .lo16 => .{ .base = 0, .imm = 0, .reloc = .{ .sym_index = r.sym_index, .rtype = .lo16 } },
                .hi4 => .{ .base = 0, .imm = 0, .reloc = .{ .sym_index = r.sym_index, .rtype = .hi4 } },
                .full => g.fail("bare relocatable symbol in an immediate — use (sym & $FFFF) or (sym >> 16) (decision ad)", .{}, ops[i].line, ops[i].col),
            },
        };
    }

    fn wantSreg(g: *Codegen, ops: []Operand, i: usize, item: Item) Error!encode.Sreg {
        if (i >= ops.len or ops[i].payload != .expr)
            return g.fail("operand {d} must be a special register name or number 0–5", .{i + 1}, item.line, item.col);
        const e = ops[i].payload.expr;
        // Name form (decision af).
        if (e.* == .symbol) {
            inline for (@typeInfo(encode.Sreg).@"enum".fields) |f| {
                if (std.ascii.eqlIgnoreCase(e.symbol.name, f.name))
                    return @enumFromInt(f.value);
            }
        }
        if (g.pass == 1) return .flags;
        const v = switch (try g.eval(e, false)) {
            .num => |n| n,
            .rel => return g.fail("special register must be a name or constant 0–5 (decision af)", .{}, ops[i].line, ops[i].col),
        };
        if (v > 5)
            return g.fail("special register number {d} out of range 0–5", .{v}, ops[i].line, ops[i].col);
        return @enumFromInt(v);
    }

    fn wantCount(g: *Codegen, ops: []Operand, n: usize, item: Item) Error!void {
        if (ops.len != n)
            return g.fail("expected {d} operand(s), got {d}", .{ n, ops.len }, item.line, item.col);
    }

    fn instruction(g: *Codegen, head: []const u8, ops: []Operand, item: Item) Error!void {
        // Ensure a location counter exists and account 4 bytes in pass 1.
        _ = try g.section();

        const op: ?encode.Opcode = blk: {
            inline for (@typeInfo(encode.Opcode).@"enum".fields) |f| {
                if (std.ascii.eqlIgnoreCase(head, f.name))
                    break :blk @enumFromInt(f.value);
            }
            break :blk null;
        };
        const is_mov = std.ascii.eqlIgnoreCase(head, "mov");
        if (op == null and !is_mov)
            return g.fail("unknown instruction or macro '{s}'", .{head}, item.line, item.col);

        if (g.pass == 1) {
            // Sizing only — but validate operand COUNTS lazily in pass 2;
            // a fixed 4-byte size never depends on them.
            try g.emitZeros(4);
            // Pass-1 walk of operands is still needed where evaluation has
            // pass-2 semantics — nothing to do here.
            return;
        }

        {
            const sec_idx = g.cur.?;
            try g.listing.append(g.arena, .{
                .kind = .instr,
                .line = item.line,
                .section = sec_idx,
                .offset = g.sections.items[sec_idx].size,
                .size = 4,
            });
        }

        if (is_mov) {
            try g.wantCount(ops, 2, item);
            return g.emitWord(encode.mov(try g.wantReg(ops, 0, item), try g.wantReg(ops, 1, item)), item);
        }

        switch (op.?) {
            // Load/store (I-format; SW/SB carry the source in RD).
            .lw, .lb => |o| {
                try g.wantCount(ops, 2, item);
                const rd = try g.wantReg(ops, 0, item);
                const m = try g.wantMem(ops, 1, item);
                if (m.reloc) |r| try g.addReloc(r.sym_index, r.rtype);
                const w = if (o == .lw) encode.lw(rd, m.base, m.imm) else encode.lb(rd, m.base, m.imm);
                try g.emitWord(w, item);
            },
            .sw, .sb => |o| {
                try g.wantCount(ops, 2, item);
                const m = try g.wantMem(ops, 0, item);
                const rs = try g.wantReg(ops, 1, item);
                if (m.reloc) |r| try g.addReloc(r.sym_index, r.rtype);
                const w = if (o == .sw) encode.sw(m.base, m.imm, rs) else encode.sb(m.base, m.imm, rs);
                try g.emitWord(w, item);
            },
            .li, .lui => |o| {
                try g.wantCount(ops, 2, item);
                const rd = try g.wantReg(ops, 0, item);
                const m = try g.wantImm(ops, 1, item);
                if (m.reloc) |r| try g.addReloc(r.sym_index, r.rtype);
                const w = if (o == .li) encode.li(rd, m.imm) else encode.lui(rd, m.imm);
                try g.emitWord(w, item);
            },
            // ALU register-register.
            .add, .sub, .@"and", .@"or", .xor, .shl, .shr, .asr, .mul, .div, .mod => |o| {
                try g.wantCount(ops, 3, item);
                const rd = try g.wantReg(ops, 0, item);
                const ra = try g.wantReg(ops, 1, item);
                const rb = try g.wantReg(ops, 2, item);
                const w = switch (o) {
                    .add => encode.add(rd, ra, rb),
                    .sub => encode.sub(rd, ra, rb),
                    .@"and" => encode.@"and"(rd, ra, rb),
                    .@"or" => encode.@"or"(rd, ra, rb),
                    .xor => encode.xor(rd, ra, rb),
                    .shl => encode.shl(rd, ra, rb),
                    .shr => encode.shr(rd, ra, rb),
                    .asr => encode.asr(rd, ra, rb),
                    .mul => encode.mul(rd, ra, rb),
                    .div => encode.div(rd, ra, rb),
                    .mod => encode.mod(rd, ra, rb),
                    else => unreachable,
                };
                try g.emitWord(w, item);
            },
            .not => {
                try g.wantCount(ops, 2, item);
                try g.emitWord(encode.not(try g.wantReg(ops, 0, item), try g.wantReg(ops, 1, item)), item);
            },
            .cmp => {
                try g.wantCount(ops, 2, item);
                try g.emitWord(encode.cmp(try g.wantReg(ops, 0, item), try g.wantReg(ops, 1, item)), item);
            },
            // ALU immediate.
            .addi, .subi, .andi, .ori, .xori => |o| {
                try g.wantCount(ops, 3, item);
                const rd = try g.wantReg(ops, 0, item);
                const ra = try g.wantReg(ops, 1, item);
                const m = try g.wantImm(ops, 2, item);
                if (m.reloc) |r| try g.addReloc(r.sym_index, r.rtype);
                const w = switch (o) {
                    .addi => encode.addi(rd, ra, m.imm),
                    .subi => encode.subi(rd, ra, m.imm),
                    .andi => encode.andi(rd, ra, m.imm),
                    .ori => encode.ori(rd, ra, m.imm),
                    .xori => encode.xori(rd, ra, m.imm),
                    else => unreachable,
                };
                try g.emitWord(w, item);
            },
            .cmpi => {
                try g.wantCount(ops, 2, item);
                const ra = try g.wantReg(ops, 0, item);
                const m = try g.wantImm(ops, 1, item);
                if (m.reloc) |r| try g.addReloc(r.sym_index, r.rtype);
                try g.emitWord(encode.cmpi(ra, m.imm), item);
            },
            // Branches (PC-relative J-format).
            .beq, .bne, .blt, .bgt, .ble, .bge, .bcs, .bcc => |o| {
                try g.wantCount(ops, 1, item);
                const offset = try g.branchOffset(ops[0], item);
                const w = switch (o) {
                    .beq => encode.beq(offset),
                    .bne => encode.bne(offset),
                    .blt => encode.blt(offset),
                    .bgt => encode.bgt(offset),
                    .ble => encode.ble(offset),
                    .bge => encode.bge(offset),
                    .bcs => encode.bcs(offset),
                    .bcc => encode.bcc(offset),
                    else => unreachable,
                };
                try g.emitWord(w, item);
            },
            .jmp => {
                try g.wantCount(ops, 1, item);
                try g.emitWord(encode.jmp(try g.wantReg(ops, 0, item)), item);
            },
            .call => {
                try g.wantCount(ops, 1, item);
                try g.emitWord(encode.call(try g.wantReg(ops, 0, item)), item);
            },
            .jmpa, .calla => |o| {
                try g.wantCount(ops, 1, item);
                const addr = try g.absTarget(ops[0], item);
                try g.emitWord(if (o == .jmpa) encode.jmpa(addr) else encode.calla(addr), item);
            },
            .ret => {
                try g.wantCount(ops, 0, item);
                try g.emitWord(encode.ret(), item);
            },
            // Stack.
            .push => {
                try g.wantCount(ops, 1, item);
                try g.emitWord(encode.push(try g.wantReg(ops, 0, item)), item);
            },
            .pop => {
                try g.wantCount(ops, 1, item);
                try g.emitWord(encode.pop(try g.wantReg(ops, 0, item)), item);
            },
            .pusha => {
                try g.wantCount(ops, 0, item);
                try g.emitWord(encode.pusha(), item);
            },
            .popa => {
                try g.wantCount(ops, 0, item);
                try g.emitWord(encode.popa(), item);
            },
            // System.
            .nop => {
                try g.wantCount(ops, 0, item);
                try g.emitWord(encode.nop(), item);
            },
            .hlt => {
                try g.wantCount(ops, 0, item);
                try g.emitWord(encode.hlt(), item);
            },
            .rti => {
                try g.wantCount(ops, 0, item);
                try g.emitWord(encode.rti(), item);
            },
            .sei => {
                try g.wantCount(ops, 0, item);
                try g.emitWord(encode.sei(), item);
            },
            .cli => {
                try g.wantCount(ops, 0, item);
                try g.emitWord(encode.cli(), item);
            },
            .mfsr => {
                try g.wantCount(ops, 2, item);
                const rd = try g.wantReg(ops, 0, item);
                const sreg = try g.wantSreg(ops, 1, item);
                try g.emitWord(encode.mfsr(rd, sreg), item);
            },
            .mtsr => {
                try g.wantCount(ops, 2, item);
                const sreg = try g.wantSreg(ops, 0, item);
                const ra = try g.wantReg(ops, 1, item);
                try g.emitWord(encode.mtsr(sreg, ra), item);
            },
        }
    }

    /// Branch target → signed byte offset from the NEXT instruction
    /// (target − (instr_addr + 4), Phase 2 §2.4). Same-section defined
    /// symbols fold even in relocatable mode (decision ad).
    fn branchOffset(g: *Codegen, op: Operand, item: Item) Error!i32 {
        _ = item;
        if (op.payload != .expr)
            return g.fail("branch target must be an address expression", .{}, op.line, op.col);
        const sec_idx = g.cur.?;
        const sec = g.sections.items[sec_idx];
        const site_off = sec.size;
        switch (try g.eval(op.payload.expr, false)) {
            .num => |target| {
                const instr_addr = sec.load_addr +% site_off;
                const diff = @as(i64, target) - (@as(i64, instr_addr) + 4);
                if (diff < encode.pcrel26_min or diff > encode.pcrel26_max)
                    return g.fail("branch target out of PCREL26 range ({d} bytes)", .{diff}, op.line, op.col);
                return @intCast(diff);
            },
            .rel => |r| {
                if (r.transform != .full)
                    return g.fail("LO16/HI4 patterns are not branch targets (decision ad)", .{}, op.line, op.col);
                const sym = g.symbols.items[r.sym_index];
                if (sym.section == sec_idx) {
                    // Link-invariant same-section distance (decision ad).
                    const diff = @as(i64, sym.offset) - (@as(i64, site_off) + 4);
                    if (diff < encode.pcrel26_min or diff > encode.pcrel26_max)
                        return g.fail("branch target out of PCREL26 range ({d} bytes)", .{diff}, op.line, op.col);
                    return @intCast(diff);
                }
                try g.addReloc(r.sym_index, .pcrel26);
                return 0;
            },
        }
    }

    /// JMPA/CALLA target → raw ADDR26 field value or an ABS26 relocation.
    fn absTarget(g: *Codegen, op: Operand, item: Item) Error!u32 {
        _ = item;
        if (op.payload != .expr)
            return g.fail("jump target must be an address expression", .{}, op.line, op.col);
        switch (try g.eval(op.payload.expr, false)) {
            .num => |v| {
                if (v > 0x3FF_FFFF)
                    return g.fail("address ${X} does not fit the 26-bit ADDR field", .{v}, op.line, op.col);
                return v;
            },
            .rel => |r| {
                if (r.transform != .full)
                    return g.fail("LO16/HI4 patterns are not jump targets (decision ad)", .{}, op.line, op.col);
                try g.addReloc(r.sym_index, .abs26);
                return 0;
            },
        }
    }
};

/// Convenience: parse + expand + generate (tests, driver).
pub fn assemble(arena: std.mem.Allocator, src: []const u8, incbins: *const IncbinMap) !Object {
    const macro = @import("macro");
    const items = try macro.expandSource(arena, src);
    var g = Codegen.init(arena, incbins);
    return g.run(items);
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const testing = std.testing;
const no_incbins = IncbinMap.empty;

fn word(data: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
}

test "task 10.6 acceptance: all 49 opcodes + MOV match encode.zig vectors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\    ORG $04100
        \\top:
        \\    LW  R1, [R2 + 4]
        \\    LB  R3, [R4 - 2]
        \\    SW  [R5 + 6], R7
        \\    SB  [R8], R9
        \\    LI  R1, -5
        \\    LUI R2, $F
        \\    ADD R1, R2, R3
        \\    SUB R4, R5, R6
        \\    AND R7, R8, R9
        \\    OR  R10, R11, R12
        \\    XOR R1, R2, R3
        \\    NOT R4, R5
        \\    SHL R1, R2, R3
        \\    SHR R4, R5, R6
        \\    ASR R7, R8, R9
        \\    MUL R1, R2, R3
        \\    DIV R4, R5, R6
        \\    MOD R7, R8, R9
        \\    CMP R1, R2
        \\    ADDI R1, R2, 100
        \\    SUBI R3, R4, 50
        \\    ANDI R5, R6, $FF
        \\    ORI  R7, R8, $10
        \\    XORI R9, R10, 3
        \\    CMPI R1, 5
        \\    BEQ top
        \\    BNE top
        \\    BLT top
        \\    BGT top
        \\    BLE top
        \\    BGE top
        \\    BCS top
        \\    BCC top
        \\    JMP  R1
        \\    JMPA $1234
        \\    CALL R2
        \\    CALLA $4100
        \\    RET
        \\    PUSH R1
        \\    POP  R2
        \\    PUSHA
        \\    POPA
        \\    NOP
        \\    HLT
        \\    RTI
        \\    SEI
        \\    CLI
        \\    MFSR R1, FLAGS
        \\    MFSR R2, 5
        \\    MTSR IVT, R3
        \\    MOV R1, R2
        \\
    ;
    const obj = try assemble(arena, src, &no_incbins);
    try testing.expectEqual(Mode.absolute, obj.mode);
    try testing.expectEqual(@as(usize, 1), obj.sections.len);
    try testing.expectEqual(@as(usize, 0), obj.relocs.len);
    const data = obj.sections[0].data.items;

    // Branch offsets: top = instruction 0; branch i sits at byte i*4.
    const bo = struct {
        fn f(instr_index: u32) i32 {
            return -@as(i32, @intCast((instr_index + 1) * 4));
        }
    }.f;

    const expect = [_]u32{
        encode.lw(1, 2, 4),
        encode.lb(3, 4, -2),
        encode.sw(5, 6, 7),
        encode.sb(8, 0, 9),
        encode.li(1, -5),
        encode.lui(2, 0xF),
        encode.add(1, 2, 3),
        encode.sub(4, 5, 6),
        encode.@"and"(7, 8, 9),
        encode.@"or"(10, 11, 12),
        encode.xor(1, 2, 3),
        encode.not(4, 5),
        encode.shl(1, 2, 3),
        encode.shr(4, 5, 6),
        encode.asr(7, 8, 9),
        encode.mul(1, 2, 3),
        encode.div(4, 5, 6),
        encode.mod(7, 8, 9),
        encode.cmp(1, 2),
        encode.addi(1, 2, 100),
        encode.subi(3, 4, 50),
        encode.andi(5, 6, 0xFF),
        encode.ori(7, 8, 0x10),
        encode.xori(9, 10, 3),
        encode.cmpi(1, 5),
        encode.beq(bo(25)),
        encode.bne(bo(26)),
        encode.blt(bo(27)),
        encode.bgt(bo(28)),
        encode.ble(bo(29)),
        encode.bge(bo(30)),
        encode.bcs(bo(31)),
        encode.bcc(bo(32)),
        encode.jmp(1),
        encode.jmpa(0x1234),
        encode.call(2),
        encode.calla(0x4100),
        encode.ret(),
        encode.push(1),
        encode.pop(2),
        encode.pusha(),
        encode.popa(),
        encode.nop(),
        encode.hlt(),
        encode.rti(),
        encode.sei(),
        encode.cli(),
        encode.mfsr(1, .flags),
        encode.mfsr(2, .cyc),
        encode.mtsr(.ivt, 3),
        encode.mov(1, 2),
    };
    try testing.expectEqual(expect.len * 4, data.len);
    for (expect, 0..) |want, i| {
        try testing.expectEqual(want, word(data, i));
    }
}

test "hello.asm end to end: forward reference, EQU, DB" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const obj = try assemble(arena,
        \\    ORG $04100
        \\    EQU SYS_PUTSTR, $FC104
        \\start:
        \\    LI    R1, msg
        \\    CALLA SYS_PUTSTR
        \\    HLT
        \\msg:
        \\    DB "HELLO", 0
        \\
    , &no_incbins);
    const sec = obj.sections[0];
    try testing.expectEqual(@as(u32, 0x04100), sec.load_addr);
    // msg = $04100 + 3 instructions = $0410C (forward reference resolved).
    try testing.expectEqual(encode.li(1, 0x410C), word(sec.data.items, 0));
    try testing.expectEqual(encode.calla(0xFC104), word(sec.data.items, 1));
    try testing.expectEqual(encode.hlt(), word(sec.data.items, 2));
    try testing.expectEqualStrings("HELLO\x00", sec.data.items[12..18]);
    // Symbols: start and msg, both global; EQU not emitted (decision ai).
    try testing.expectEqual(@as(usize, 2), obj.symbols.len);
    try testing.expectEqualStrings("start", obj.symbols[0].name);
    try testing.expectEqual(@as(u32, 0), obj.symbols[0].offset);
    try testing.expectEqualStrings("msg", obj.symbols[1].name);
    try testing.expectEqual(@as(u32, 12), obj.symbols[1].offset);
}

test "mode rule (task 10.4): mixing ORG and SECTION errors both ways" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    inline for (.{
        "ORG $100\nSECTION code\n",
        "SECTION code\nORG $100\n",
    }) |src| {
        const macro = @import("macro");
        const items = try macro.expandSource(arena, src);
        var g = Codegen.init(arena, &no_incbins);
        try testing.expectError(Error.Codegen, g.run(items));
        try testing.expect(std.mem.indexOf(u8, g.err_msg, "mixing is an error") != null);
    }
    // Emission before any ORG/SECTION.
    {
        const macro = @import("macro");
        const items = try macro.expandSource(arena, "NOP\n");
        var g = Codegen.init(arena, &no_incbins);
        try testing.expectError(Error.Codegen, g.run(items));
        try testing.expect(std.mem.indexOf(u8, g.err_msg, "before the first ORG/SECTION") != null);
    }
}

test "directives (task 10.8): DW/DD/DS/ALIGN/INCBIN and multiple ORG sections" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var incbins = IncbinMap.empty;
    try incbins.put(arena, "blob.bin", &.{ 0xDE, 0xAD, 0xBE, 0xEF });

    const obj = try assemble(arena,
        \\    ORG $FC000
        \\    DW $1234, -1
        \\    DB 1
        \\    ALIGN 4
        \\    DD $DEADBEEF, vec
        \\vec:
        \\    DS 3
        \\    INCBIN "blob.bin"
        \\    ORG $FFFC0
        \\    DD vec
        \\
    , &incbins);
    try testing.expectEqual(@as(usize, 2), obj.sections.len);
    const s0 = obj.sections[0].data.items;
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xFF, 0xFF, 0x01, 0, 0, 0 }, s0[0..8]);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), std.mem.readInt(u32, s0[8..12], .little));
    // vec = $FC000 + 16 = $FC010.
    try testing.expectEqual(@as(u32, 0xFC010), std.mem.readInt(u32, s0[12..16], .little));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0xDE, 0xAD, 0xBE, 0xEF }, s0[16..23]);
    // Second ORG section: cross-section symbol folds in absolute mode.
    const s1 = obj.sections[1];
    try testing.expectEqual(@as(u32, 0xFFFC0), s1.load_addr);
    try testing.expectEqual(@as(u32, 0xFC010), std.mem.readInt(u32, s1.data.items[0..4], .little));
    try testing.expectEqualStrings("abs0", std.mem.sliceTo(&obj.sections[0].name, 0));
    try testing.expectEqualStrings("abs1", std.mem.sliceTo(&s1.name, 0));
}

test "relocatable mode (task 10.7): LO16/HI4/ABS16/ABS32/ABS26/PCREL26" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const obj = try assemble(arena,
        \\    SECTION code
        \\start:
        \\    LI   R1, (msg & $FFFF)
        \\    LUI  R1, (msg >> 16)
        \\    CALLA ext_fn
        \\    BEQ  ext_fn
        \\    BNE  start
        \\    SECTION data
        \\msg:
        \\    DB "X", 0
        \\ptr16:
        \\    DW msg
        \\ptr32:
        \\    DD msg
        \\    SECTION bss
        \\buf:
        \\    DS 16
        \\    ALIGN 8
        \\
    , &no_incbins);
    try testing.expectEqual(Mode.relocatable, obj.mode);
    try testing.expectEqual(@as(usize, 3), obj.sections.len);
    try testing.expectEqual(@as(u32, 0), obj.sections[0].load_addr);

    // bss: size only, no payload (decision ag). DS 16 leaves the counter
    // at 16, which is already 8-aligned — ALIGN 8 adds nothing.
    try testing.expectEqual(@as(usize, 0), obj.sections[2].data.items.len);
    try testing.expectEqual(@as(u32, 16), obj.sections[2].size);

    // Relocations: LO16@0, HI4@4, ABS26@8, PCREL26@12 in code;
    // ABS16@2 and ABS32@4 in data. BNE start folded (same section).
    try testing.expectEqual(@as(usize, 6), obj.relocs.len);
    const r = obj.relocs;
    try testing.expectEqual(RelocType.lo16, r[0].rtype);
    try testing.expectEqual(@as(u32, 0), r[0].offset);
    try testing.expectEqual(RelocType.hi4, r[1].rtype);
    try testing.expectEqual(@as(u32, 4), r[1].offset);
    try testing.expectEqual(RelocType.abs26, r[2].rtype);
    try testing.expectEqual(@as(u32, 8), r[2].offset);
    try testing.expectEqual(RelocType.pcrel26, r[3].rtype);
    try testing.expectEqual(@as(u32, 12), r[3].offset);
    try testing.expectEqual(RelocType.abs16, r[4].rtype);
    try testing.expectEqual(@as(u8, 1), r[4].section);
    try testing.expectEqual(@as(u32, 2), r[4].offset);
    try testing.expectEqual(RelocType.abs32, r[5].rtype);
    try testing.expectEqual(@as(u32, 4), r[5].offset);

    // LO16/HI4/ABS26/PCREL26 both reference msg/ext_fn correctly.
    const msg_sym = obj.symbols[r[0].symbol];
    try testing.expectEqualStrings("msg", msg_sym.name);
    try testing.expectEqual(@as(u8, 1), msg_sym.section);
    const ext_sym = obj.symbols[r[2].symbol];
    try testing.expectEqualStrings("ext_fn", ext_sym.name);
    try testing.expectEqual(external_section, ext_sym.section); // decision ae

    // Same-section branch folded to a real offset: BNE start at instr 4,
    // offset = 0 - (16 + 4) = -20.
    try testing.expectEqual(encode.bne(-20), word(obj.sections[0].data.items, 4));
}

test "codegen errors: ranges, duplicates, pass-1 rule, bss data" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const macro = @import("macro");

    const Case = struct { src: []const u8, needle: []const u8 };
    const cases = [_]Case{
        .{ .src = "ORG $100\nLI R1, $20000\n", .needle = "out of range for IMM18" },
        .{ .src = "ORG $100\nx:\nx:\n", .needle = "duplicate symbol" },
        .{ .src = "ORG $100\nEQU x, 1\nx:\n", .needle = "duplicate symbol" },
        .{ .src = "ORG $100\nJMPA nowhere\n", .needle = "undefined symbol" },
        .{ .src = "ORG $100\nDS later\nlater:\n", .needle = "undefined symbol" },
        .{ .src = "ORG base\nEQU base, $100\n", .needle = "undefined symbol" },
        .{ .src = "SECTION bss\nDB 1\n", .needle = "bss" },
        .{ .src = "SECTION code\nLI R1, msg\n", .needle = "bare relocatable symbol" },
        .{ .src = "SECTION code\nDW msg + 2\n", .needle = "only (sym & $FFFF)" },
        .{ .src = "SECTION text\n", .needle = "code, data, bss" },
        .{ .src = "ORG $100\nFROB R1\n", .needle = "unknown instruction or macro" },
        .{ .src = "ORG $100\nADD R1, R2\n", .needle = "expected 3 operand(s)" },
        .{ .src = "ORG $100\nMFSR R1, 9\n", .needle = "out of range 0" },
        .{ .src = "ORG $100\nALIGN 0\n", .needle = "ALIGN 0" },
        .{ .src = "ORG $100\nINCBIN \"nope.bin\"\n", .needle = "not provided" },
    };
    for (cases) |case| {
        const items = try macro.expandSource(arena, case.src);
        var g = Codegen.init(arena, &no_incbins);
        const r = g.run(items);
        try testing.expectError(Error.Codegen, r);
        if (std.mem.indexOf(u8, g.err_msg, case.needle) == null) {
            std.debug.print("src: {s}\nwanted needle: {s}\ngot: {s}\n", .{ case.src, case.needle, g.err_msg });
            return error.TestUnexpectedResult;
        }
    }
}
