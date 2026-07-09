//! flas macro expansion — expanded AST from parsed AST (Block 10, task 10.3).
//!
//! Implements the Phase 8 §8.3 macro system: `MACRO name params… /
//! ENDMACRO` definitions are collected and removed; every statement whose
//! head names a defined macro is replaced by its body with `\param`
//! occurrences substituted by the invocation's arguments. Expansion
//! recurses (macro bodies may invoke previously defined macros).
//!
//! Substitution semantics (decision w):
//!   - A `\param` standing as a WHOLE operand is replaced by the argument
//!     operand VERBATIM — register, memory operand, string, or expression
//!     all pass through (this is what lets `LI \reg, …` receive `R1`).
//!   - A `\param` leaf INSIDE a larger expression requires the argument to
//!     be an expression; its tree is spliced in (this is what makes
//!     `(\addr & $FFFF)` work). A register/memory/string argument used
//!     this way is an error at the invocation site.
//!
//! Implementation decisions (continuing parser.zig's r–v):
//!   (w) Substitution semantics as above.
//!   (x) A macro must be DEFINED BEFORE its first invocation (single
//!       forward pass — same rule as EQU constants in classic two-pass
//!       assemblers). Redefinition is an error. Expansion depth is capped
//!       at 64 to turn (mutual) recursion into a clear diagnostic.
//!   (y) Invocation arity must match the definition exactly; macro names
//!       and parameter names match case-sensitively (decision r). A
//!       definition whose name collides case-insensitively with an
//!       instruction mnemonic (from encode.Opcode + the MOV pseudo), a
//!       register name, or a directive is an error — silent shadowing of
//!       `ADD` would be a trap. The mnemonic NAMES come from encode.zig's
//!       Opcode enum via @typeInfo; no encoding knowledge lives here
//!       (audit P1).
//!   (z) Labels defined inside a macro body are LOCAL to each expansion:
//!       instance N of a body label `loop` becomes `loop.@N` (`.@` cannot
//!       appear in a user identifier — lexer decision n — so collisions
//!       are impossible), and symbol references to `loop` within that same
//!       expansion are renamed with it. Two invocations of a macro with an
//!       internal branch target therefore assemble instead of colliding.
//!       References to labels NOT defined in the body pass through and
//!       resolve globally as usual.

const std = @import("std");
const parser = @import("parser");
const encode = @import("encode");

pub const Error = error{ Macro, OutOfMemory };

const Item = parser.Item;
const Operand = parser.Operand;
const Expr = parser.Expr;

/// True if `name` collides (case-insensitively) with an instruction
/// mnemonic — the encode.Opcode field names plus the MOV pseudo (§2.4).
pub fn isMnemonicName(name: []const u8) bool {
    inline for (@typeInfo(encode.Opcode).@"enum".fields) |f| {
        if (std.ascii.eqlIgnoreCase(name, f.name)) return true;
    }
    return std.ascii.eqlIgnoreCase(name, "mov");
}

const Macro = struct {
    params: [][]const u8,
    body: []Item,
};

pub const Expander = struct {
    arena: std.mem.Allocator,
    macros: std.StringHashMapUnmanaged(Macro) = .empty,
    /// Monotonic counter across ALL expansions (decision z suffixes).
    instance: u32 = 0,
    /// Valid after Error.Macro.
    err_msg: []const u8 = "",
    err_line: u32 = 0,
    err_col: u32 = 0,

    pub fn init(arena: std.mem.Allocator) Expander {
        return .{ .arena = arena };
    }

    fn fail(x: *Expander, comptime fmt: []const u8, args: anytype, line: u32, col: u32) Error {
        x.err_msg = std.fmt.allocPrint(x.arena, fmt, args) catch "out of memory formatting diagnostic";
        x.err_line = line;
        x.err_col = col;
        return Error.Macro;
    }

    /// Expand all macros in `items`: definitions are collected and removed,
    /// invocations are replaced by substituted bodies.
    pub fn expand(x: *Expander, items: []const Item) Error![]Item {
        var out: std.ArrayList(Item) = .empty;
        try x.expandInto(&out, items, 0);
        return out.toOwnedSlice(x.arena);
    }

    fn expandInto(x: *Expander, out: *std.ArrayList(Item), items: []const Item, depth: u32) Error!void {
        if (depth > 64)
            return x.fail("macro expansion exceeds depth 64 — recursive macro? (decision x)", .{}, 0, 0);

        for (items) |item| {
            switch (item.payload) {
                .macro_def => |def| {
                    if (depth != 0)
                        return x.fail("MACRO definition inside a macro body", .{}, item.line, item.col);
                    if (isMnemonicName(def.name))
                        return x.fail("macro name '{s}' shadows an instruction mnemonic (decision y)", .{def.name}, item.line, item.col);
                    if (parser.registerFromName(def.name) != null)
                        return x.fail("macro name '{s}' shadows a register (decision y)", .{def.name}, item.line, item.col);
                    const gop = try x.macros.getOrPut(x.arena, def.name);
                    if (gop.found_existing)
                        return x.fail("macro '{s}' redefined (decision x)", .{def.name}, item.line, item.col);
                    gop.value_ptr.* = .{ .params = def.params, .body = def.body };
                },
                .statement => |s| {
                    if (x.macros.get(s.head)) |mac| {
                        try x.invoke(out, item, mac, s.operands, depth);
                    } else {
                        try out.append(x.arena, item);
                    }
                },
                else => try out.append(x.arena, item),
            }
        }
    }

    /// One invocation: bind arguments, uniquify body labels (decision z),
    /// substitute, then recursively expand the result.
    fn invoke(x: *Expander, out: *std.ArrayList(Item), site: Item, mac: Macro, args: []Operand, depth: u32) Error!void {
        if (args.len != mac.params.len)
            return x.fail("macro expects {d} argument(s), got {d} (decision y)", .{ mac.params.len, args.len }, site.line, site.col);

        x.instance += 1;
        var ctx = Ctx{
            .x = x,
            .params = mac.params,
            .args = args,
            .site = site,
            .instance = x.instance,
        };

        // Pass A: collect body-defined labels for local renaming.
        for (mac.body) |item| {
            switch (item.payload) {
                .label => |name| try ctx.local_labels.put(x.arena, name, {}),
                else => {},
            }
        }

        // Pass B: clone body with substitution and renaming.
        var expanded: std.ArrayList(Item) = .empty;
        for (mac.body) |item| {
            try expanded.append(x.arena, try ctx.cloneItem(item));
        }

        // Pass C: bodies may invoke other (earlier-defined) macros.
        try x.expandInto(out, expanded.items, depth + 1);
    }

    /// Per-invocation cloning context.
    const Ctx = struct {
        x: *Expander,
        params: [][]const u8,
        args: []Operand,
        site: Item,
        instance: u32,
        local_labels: std.StringHashMapUnmanaged(void) = .empty,

        fn paramIndex(c: *Ctx, name: []const u8) ?usize {
            for (c.params, 0..) |p, i| {
                if (std.mem.eql(u8, p, name)) return i;
            }
            return null;
        }

        fn localName(c: *Ctx, name: []const u8) Error![]const u8 {
            return std.fmt.allocPrint(c.x.arena, "{s}.@{d}", .{ name, c.instance });
        }

        fn cloneItem(c: *Ctx, item: Item) Error!Item {
            switch (item.payload) {
                .label => |name| {
                    // Body labels are per-expansion (decision z).
                    return .{ .line = item.line, .col = item.col, .payload = .{
                        .label = try c.localName(name),
                    } };
                },
                .statement => |s| {
                    var ops: std.ArrayList(Operand) = .empty;
                    for (s.operands) |op| try ops.append(c.x.arena, try c.cloneOperand(op));
                    return .{ .line = item.line, .col = item.col, .payload = .{ .statement = .{
                        .head = s.head,
                        .operands = try ops.toOwnedSlice(c.x.arena),
                    } } };
                },
                .directive => |d| {
                    var ops: std.ArrayList(Operand) = .empty;
                    for (d.args) |op| try ops.append(c.x.arena, try c.cloneOperand(op));
                    return .{ .line = item.line, .col = item.col, .payload = .{ .directive = .{
                        .kind = d.kind,
                        .args = try ops.toOwnedSlice(c.x.arena),
                    } } };
                },
                // Parser guarantees no nested macro_def (decision v).
                .macro_def => return c.x.fail("MACRO definition inside a macro body", .{}, item.line, item.col),
            }
        }

        fn cloneOperand(c: *Ctx, op: Operand) Error!Operand {
            switch (op.payload) {
                .register, .string => return op,
                .memory => |m| {
                    const off: ?*Expr = if (m.offset) |e| try c.cloneExpr(e) else null;
                    return .{ .line = op.line, .col = op.col, .payload = .{
                        .memory = .{ .base = m.base, .offset = off },
                    } };
                },
                .expr => |e| {
                    // Whole-operand `\param` → argument verbatim (decision w).
                    switch (e.*) {
                        .macro_param => |sym| {
                            const i = c.paramIndex(sym.name) orelse
                                return c.x.fail("unknown macro parameter '\\{s}'", .{sym.name}, sym.line, sym.col);
                            return c.args[i];
                        },
                        else => {},
                    }
                    return .{ .line = op.line, .col = op.col, .payload = .{
                        .expr = try c.cloneExpr(e),
                    } };
                },
            }
        }

        fn newExpr(c: *Ctx, value: Expr) Error!*Expr {
            const node = try c.x.arena.create(Expr);
            node.* = value;
            return node;
        }

        fn cloneExpr(c: *Ctx, e: *const Expr) Error!*Expr {
            switch (e.*) {
                .number => |n| return c.newExpr(.{ .number = n }),
                .symbol => |sym| {
                    // Reference to a body-local label? Rename with the
                    // instance suffix (decision z).
                    if (c.local_labels.contains(sym.name)) {
                        return c.newExpr(.{ .symbol = .{
                            .name = try c.localName(sym.name),
                            .line = sym.line,
                            .col = sym.col,
                        } });
                    }
                    return c.newExpr(.{ .symbol = sym });
                },
                .macro_param => |sym| {
                    // In-expression `\param` → splice the argument's
                    // expression tree (decision w).
                    const i = c.paramIndex(sym.name) orelse
                        return c.x.fail("unknown macro parameter '\\{s}'", .{sym.name}, sym.line, sym.col);
                    switch (c.args[i].payload) {
                        .expr => |arg| return c.cloneExprNoSubst(arg),
                        .register => return c.x.fail("macro argument for '\\{s}' is a register, but the parameter is used inside an expression (decision w)", .{sym.name}, sym.line, sym.col),
                        .memory => return c.x.fail("macro argument for '\\{s}' is a memory operand, but the parameter is used inside an expression (decision w)", .{sym.name}, sym.line, sym.col),
                        .string => return c.x.fail("macro argument for '\\{s}' is a string, but the parameter is used inside an expression (decision w)", .{sym.name}, sym.line, sym.col),
                    }
                },
                .unary => |u| return c.newExpr(.{ .unary = .{
                    .op = u.op,
                    .sub = try c.cloneExpr(u.sub),
                } }),
                .binary => |b| return c.newExpr(.{ .binary = .{
                    .op = b.op,
                    .lhs = try c.cloneExpr(b.lhs),
                    .rhs = try c.cloneExpr(b.rhs),
                } }),
            }
        }

        /// Argument trees come from the invocation site: no macro params
        /// or body-local labels can occur inside them, so share them.
        fn cloneExprNoSubst(c: *Ctx, e: *Expr) Error!*Expr {
            _ = c;
            return e;
        }
    };
};

/// Convenience: parse + expand in one call (tests, driver).
pub fn expandSource(arena: std.mem.Allocator, src: []const u8) ![]Item {
    const items = try parser.parse(arena, src);
    var x = Expander.init(arena);
    return x.expand(items);
}

// ---------------------------------------------------------------------------
// Tests (task 10.3 acceptance: macros expand correctly).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "§8.3 LOAD_ADDR: whole-operand and in-expression substitution (decision w)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = try expandSource(arena,
        \\MACRO LOAD_ADDR reg, addr
        \\    LI   \reg, (\addr & $FFFF)
        \\    LUI  \reg, (\addr >> 16)
        \\ENDMACRO
        \\    LOAD_ADDR R1, $40000
        \\
    );
    try testing.expectEqual(@as(usize, 2), items.len);

    const li = items[0].payload.statement;
    try testing.expectEqualStrings("LI", li.head);
    try testing.expectEqual(@as(u4, 1), li.operands[0].payload.register);
    const and_e = li.operands[1].payload.expr;
    try testing.expectEqual(parser.BinOp.band, and_e.binary.op);
    try testing.expectEqual(parser.Expr{ .number = 0x40000 }, and_e.binary.lhs.*);
    try testing.expectEqual(parser.Expr{ .number = 0xFFFF }, and_e.binary.rhs.*);

    const lui = items[1].payload.statement;
    try testing.expectEqualStrings("LUI", lui.head);
    const shr_e = lui.operands[1].payload.expr;
    try testing.expectEqual(parser.BinOp.shr, shr_e.binary.op);
    try testing.expectEqual(parser.Expr{ .number = 0x40000 }, shr_e.binary.lhs.*);
}

test "PUSH_ALL zero-arg macro and macro-calls-macro (decision x)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = try expandSource(arena,
        \\MACRO PUSH_ALL
        \\    PUSHA
        \\ENDMACRO
        \\MACRO PROLOGUE
        \\    PUSH_ALL
        \\    MOV FP, SP
        \\ENDMACRO
        \\    PROLOGUE
        \\
    );
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("PUSHA", items[0].payload.statement.head);
    try testing.expectEqualStrings("MOV", items[1].payload.statement.head);
}

test "memory and string arguments substitute verbatim as whole operands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = try expandSource(arena,
        \\MACRO LOAD16 dst, src
        \\    LW \dst, \src
        \\ENDMACRO
        \\MACRO EMIT s
        \\    DB \s, 0
        \\ENDMACRO
        \\    LOAD16 R3, [R2 + 8]
        \\    EMIT "HI"
        \\
    );
    const lw = items[0].payload.statement;
    try testing.expectEqual(@as(u4, 3), lw.operands[0].payload.register);
    try testing.expectEqual(@as(u4, 2), lw.operands[1].payload.memory.base);
    const db = items[1].payload.directive;
    try testing.expectEqualStrings("HI", db.args[0].payload.string);
}

test "body-local labels are unique per expansion (decision z)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = try expandSource(arena,
        \\MACRO SPIN n
        \\    LI R1, \n
        \\wait:
        \\    SUBI R1, R1, 1
        \\    BNE wait
        \\ENDMACRO
        \\    SPIN 10
        \\    SPIN 20
        \\
    );
    try testing.expectEqual(@as(usize, 8), items.len);
    const label1 = items[1].payload.label;
    const label2 = items[5].payload.label;
    try testing.expect(std.mem.startsWith(u8, label1, "wait.@"));
    try testing.expect(std.mem.startsWith(u8, label2, "wait.@"));
    try testing.expect(!std.mem.eql(u8, label1, label2));
    // Each BNE references ITS OWN expansion's label.
    const bne1 = items[3].payload.statement;
    const bne2 = items[7].payload.statement;
    try testing.expectEqualStrings(label1, bne1.operands[0].payload.expr.symbol.name);
    try testing.expectEqualStrings(label2, bne2.operands[0].payload.expr.symbol.name);
    // Global symbols pass through untouched: check the LI got its arg.
    try testing.expectEqual(parser.Expr{ .number = 10 }, items[0].payload.statement.operands[1].payload.expr.*);
    try testing.expectEqual(parser.Expr{ .number = 20 }, items[4].payload.statement.operands[1].payload.expr.*);
}

test "expansion errors (decisions w, x, y)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Arity mismatch (y).
    {
        const items = try parser.parse(arena, "MACRO M a, b\nNOP\nENDMACRO\nM 1\n");
        var x = Expander.init(arena);
        try testing.expectError(Error.Macro, x.expand(items));
        try testing.expect(std.mem.indexOf(u8, x.err_msg, "expects 2 argument(s), got 1") != null);
    }
    // Register argument used inside an expression (w).
    {
        const items = try parser.parse(arena, "MACRO M v\nDW \\v + 1\nENDMACRO\nM R5\n");
        var x = Expander.init(arena);
        try testing.expectError(Error.Macro, x.expand(items));
        try testing.expect(std.mem.indexOf(u8, x.err_msg, "is a register") != null);
    }
    // Unknown parameter name.
    {
        const items = try parser.parse(arena, "MACRO M a\nLI R1, \\b\nENDMACRO\nM 1\n");
        var x = Expander.init(arena);
        try testing.expectError(Error.Macro, x.expand(items));
        try testing.expect(std.mem.indexOf(u8, x.err_msg, "unknown macro parameter") != null);
    }
    // Invocation before definition (x): head is not yet a macro, so it
    // passes through as a (bogus) instruction — codegen rejects it later.
    {
        const items = try parser.parse(arena, "M 1\nMACRO M a\nNOP\nENDMACRO\n");
        var x = Expander.init(arena);
        const out = try x.expand(items);
        try testing.expectEqual(@as(usize, 1), out.len);
        try testing.expectEqualStrings("M", out[0].payload.statement.head);
    }
    // Redefinition (x).
    {
        const items = try parser.parse(arena, "MACRO M\nNOP\nENDMACRO\nMACRO M\nHLT\nENDMACRO\n");
        var x = Expander.init(arena);
        try testing.expectError(Error.Macro, x.expand(items));
        try testing.expect(std.mem.indexOf(u8, x.err_msg, "redefined") != null);
    }
    // Self-recursion trips the depth cap (x).
    {
        const items = try parser.parse(arena, "MACRO M\nM\nENDMACRO\nM\n");
        var x = Expander.init(arena);
        try testing.expectError(Error.Macro, x.expand(items));
        try testing.expect(std.mem.indexOf(u8, x.err_msg, "depth 64") != null);
    }
    // Mnemonic shadowing (y) — from encode.Opcode names, plus MOV pseudo.
    {
        const items = try parser.parse(arena, "MACRO add x\nNOP\nENDMACRO\n");
        var x = Expander.init(arena);
        try testing.expectError(Error.Macro, x.expand(items));
        try testing.expect(std.mem.indexOf(u8, x.err_msg, "shadows an instruction mnemonic") != null);
    }
    {
        const items = try parser.parse(arena, "MACRO Mov x\nNOP\nENDMACRO\n");
        var x = Expander.init(arena);
        try testing.expectError(Error.Macro, x.expand(items));
    }
    // Register shadowing (y).
    {
        const items = try parser.parse(arena, "MACRO sp\nNOP\nENDMACRO\n");
        var x = Expander.init(arena);
        try testing.expectError(Error.Macro, x.expand(items));
        try testing.expect(std.mem.indexOf(u8, x.err_msg, "shadows a register") != null);
    }
}

test "isMnemonicName covers all 49 opcodes plus MOV" {
    try testing.expect(isMnemonicName("ADD"));
    try testing.expect(isMnemonicName("hlt"));
    try testing.expect(isMnemonicName("Calla"));
    try testing.expect(isMnemonicName("mfsr"));
    try testing.expect(isMnemonicName("MOV"));
    try testing.expect(!isMnemonicName("LOAD_ADDR"));
    try testing.expect(!isMnemonicName("ORG"));
}
