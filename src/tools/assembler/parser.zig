//! flas parser — token stream → AST (Block 10, task 10.2).
//!
//! Grammar (Phase 8 §8.3):
//!   line      := (label ':')* (directive | statement)? NEWLINE
//!   statement := head (operand (',' operand)*)?      ; instruction OR macro
//!   operand   := register | string | memory | expr
//!   memory    := '[' register (('+'|'-') expr)? ']'
//!   expr      := precedence-climbing over | ^ & (<< >>) (+ -) (* / %)
//!                with unary - ~ and primaries: number, symbol,
//!                macro-param, '(' expr ')'
//!
//! The parser is a pure grammar layer. It recognizes DIRECTIVES (fixed set,
//! §8.3 table + MACRO/ENDMACRO) but does NOT classify other statement heads
//! into instruction mnemonics vs macro invocations — both parse identically
//! and the distinction needs the macro table (macro.zig) and the mnemonic
//! set (codegen.zig via encode.zig). It also does not enforce the
//! ORG-vs-SECTION mode rule (task 10.4, codegen) and does not do file I/O:
//! INCLUDE/INCBIN become AST items whose paths the driver resolves.
//!
//! Implementation decisions (continuing lexer.zig's n–q):
//!   (r) Directive names and register names are CASE-INSENSITIVE (the spec
//!       writes them uppercase; requiring case would make `org`/`ORG`
//!       gratuitously different). Labels, macro names, and EQU constants
//!       are CASE-SENSITIVE, matching every symbol table convention in
//!       Blocks 1–9. Mnemonic case is codegen's call — same rule (r) there.
//!   (s) Register names R0–R15 and the Phase 2 §2.2 aliases ZERO (R0),
//!       FP (R13), LR (R14), SP (R15) are reserved words in operand
//!       position: an identifier matching one always parses as a register,
//!       never as a symbol.
//!   (t) Expression operator precedence follows C (tightest first):
//!       unary - ~; then * / %; + -; << >>; &; ^; |. All arithmetic is
//!       wrapping u32; the '-'-as-negation case is (wrapping) two's
//!       complement, so `LI R1, -1` reaches codegen as $FFFFFFFF and range
//!       checks happen there against the target field's signedness.
//!   (u) `[reg - expr]` is accepted alongside the spec's `[reg + expr]`
//!       and parses as `[reg + (0 - expr)]` — IMM is signed (§2.3) and a
//!       negative-displacement syntax costs nothing.
//!   (v) MACRO parameter lists accept both `MACRO NAME p1, p2` (the §8.3
//!       example) and space separation; ENDMACRO must be alone on its
//!       line. Macro definitions do not nest.

const std = @import("std");
const lexer = @import("lexer");

pub const Error = error{ Parse, OutOfMemory } || lexer.Error;

// ---------------------------------------------------------------------------
// AST.
// ---------------------------------------------------------------------------

pub const UnOp = enum { neg, bit_not };
pub const BinOp = enum { add, sub, mul, div, mod, shl, shr, band, bxor, bor };

pub const Expr = union(enum) {
    number: u32,
    symbol: Sym,
    macro_param: Sym,
    unary: struct { op: UnOp, sub: *Expr },
    binary: struct { op: BinOp, lhs: *Expr, rhs: *Expr },

    pub const Sym = struct { name: []const u8, line: u32, col: u32 };
};

pub const Operand = struct {
    line: u32,
    col: u32,
    payload: union(enum) {
        register: u4,
        /// `[base + offset]`; null offset = `[base]` (offset 0).
        memory: struct { base: u4, offset: ?*Expr },
        string: []const u8,
        expr: *Expr,
    },
};

pub const Directive = enum {
    org,
    db,
    dw,
    dd,
    ds,
    equ,
    include,
    incbin,
    @"align",
    section,
};

pub const Item = struct {
    line: u32,
    col: u32,
    payload: union(enum) {
        label: []const u8,
        /// Instruction OR macro invocation — resolved by later stages.
        statement: struct { head: []const u8, operands: []Operand },
        directive: struct { kind: Directive, args: []Operand },
        macro_def: struct {
            name: []const u8,
            params: [][]const u8,
            body: []Item,
        },
    },
};

/// Reserved register names (decision s), case-insensitive (decision r).
pub fn registerFromName(name: []const u8) ?u4 {
    if (name.len >= 2 and name.len <= 3 and (name[0] == 'R' or name[0] == 'r')) {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (n <= 15) return @intCast(n);
        return null;
    }
    if (std.ascii.eqlIgnoreCase(name, "ZERO")) return 0;
    if (std.ascii.eqlIgnoreCase(name, "FP")) return 13;
    if (std.ascii.eqlIgnoreCase(name, "LR")) return 14;
    if (std.ascii.eqlIgnoreCase(name, "SP")) return 15;
    return null;
}

fn directiveFromName(name: []const u8) ?Directive {
    inline for (@typeInfo(Directive).@"enum".fields) |f| {
        if (std.ascii.eqlIgnoreCase(name, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

// ---------------------------------------------------------------------------
// Parser.
// ---------------------------------------------------------------------------

pub const Parser = struct {
    arena: std.mem.Allocator,
    lex: lexer.Lexer,
    tok: lexer.Token,
    /// Valid after Error.Parse (Error.Lex diagnostics stay on `lex`).
    err_msg: []const u8 = "",
    err_line: u32 = 0,
    err_col: u32 = 0,

    pub fn init(arena: std.mem.Allocator, src: []const u8) Error!Parser {
        var p = Parser{
            .arena = arena,
            .lex = lexer.Lexer.init(arena, src),
            .tok = undefined,
        };
        p.tok = try p.lex.next();
        return p;
    }

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype, line: u32, col: u32) Error {
        p.err_msg = std.fmt.allocPrint(p.arena, fmt, args) catch "out of memory formatting diagnostic";
        p.err_line = line;
        p.err_col = col;
        return Error.Parse;
    }

    fn advance(p: *Parser) Error!void {
        p.tok = try p.lex.next();
    }

    fn skipNewlines(p: *Parser) Error!void {
        while (p.tok.tag == .newline) try p.advance();
    }

    /// End of the current statement: newline or EOF.
    fn atLineEnd(p: *const Parser) bool {
        return p.tok.tag == .newline or p.tok.tag == .eof;
    }

    fn expectLineEnd(p: *Parser) Error!void {
        if (!p.atLineEnd())
            return p.fail("expected end of line, found '{t}'", .{p.tok.tag}, p.tok.line, p.tok.col);
    }

    /// Parse a whole source file into a flat item list.
    pub fn parseProgram(p: *Parser) Error![]Item {
        var items: std.ArrayList(Item) = .empty;
        try p.skipNewlines();
        while (p.tok.tag != .eof) {
            try p.parseLine(&items, false);
            try p.skipNewlines();
        }
        return items.toOwnedSlice(p.arena);
    }

    /// One logical line: labels, then at most one directive/statement.
    /// `in_macro` forbids nested MACRO and makes ENDMACRO the terminator
    /// (handled by the caller, parseMacroDef).
    fn parseLine(p: *Parser, items: *std.ArrayList(Item), in_macro: bool) Error!void {
        // Leading labels: IDENT ':' (possibly several, then a statement).
        while (p.tok.tag == .identifier) {
            const head = p.tok;
            // One-token lookahead for ':' — the lexer is not rewindable, so
            // decide from the next token.
            try p.advance();
            if (p.tok.tag == .colon) {
                try p.advance();
                try items.append(p.arena, .{
                    .line = head.line,
                    .col = head.col,
                    .payload = .{ .label = head.text },
                });
                continue; // maybe another label or a statement follows
            }
            // Not a label — `head` starts a directive or statement.
            return p.parseHeaded(items, head, in_macro);
        }
        if (p.atLineEnd()) return; // label-only or empty line
        return p.fail("expected label, directive, or instruction, found '{t}'", .{p.tok.tag}, p.tok.line, p.tok.col);
    }

    /// Directive or statement whose head identifier is already consumed.
    fn parseHeaded(p: *Parser, items: *std.ArrayList(Item), head: lexer.Token, in_macro: bool) Error!void {
        if (std.ascii.eqlIgnoreCase(head.text, "MACRO")) {
            if (in_macro)
                return p.fail("macro definitions do not nest (decision v)", .{}, head.line, head.col);
            return p.parseMacroDef(items, head);
        }
        if (std.ascii.eqlIgnoreCase(head.text, "ENDMACRO"))
            return p.fail("ENDMACRO without MACRO", .{}, head.line, head.col);

        if (directiveFromName(head.text)) |kind| {
            const args = try p.parseOperandList();
            try p.expectLineEnd();
            try items.append(p.arena, .{
                .line = head.line,
                .col = head.col,
                .payload = .{ .directive = .{ .kind = kind, .args = args } },
            });
            return;
        }

        const operands = try p.parseOperandList();
        try p.expectLineEnd();
        try items.append(p.arena, .{
            .line = head.line,
            .col = head.col,
            .payload = .{ .statement = .{ .head = head.text, .operands = operands } },
        });
    }

    /// `MACRO NAME [p1[,] p2 …]` … `ENDMACRO` (decision v).
    fn parseMacroDef(p: *Parser, items: *std.ArrayList(Item), head: lexer.Token) Error!void {
        if (p.tok.tag != .identifier)
            return p.fail("expected macro name after MACRO", .{}, p.tok.line, p.tok.col);
        const name = p.tok.text;
        try p.advance();

        var params: std.ArrayList([]const u8) = .empty;
        while (!p.atLineEnd()) {
            if (p.tok.tag == .comma) {
                try p.advance();
                continue;
            }
            if (p.tok.tag != .identifier)
                return p.fail("expected macro parameter name, found '{t}'", .{p.tok.tag}, p.tok.line, p.tok.col);
            try params.append(p.arena, p.tok.text);
            try p.advance();
        }

        var body: std.ArrayList(Item) = .empty;
        while (true) {
            try p.skipNewlines();
            if (p.tok.tag == .eof)
                return p.fail("unterminated MACRO '{s}' (missing ENDMACRO)", .{name}, head.line, head.col);
            if (p.tok.tag == .identifier and std.ascii.eqlIgnoreCase(p.tok.text, "ENDMACRO")) {
                try p.advance();
                try p.expectLineEnd();
                break;
            }
            try p.parseLine(&body, true);
        }

        try items.append(p.arena, .{
            .line = head.line,
            .col = head.col,
            .payload = .{ .macro_def = .{
                .name = name,
                .params = try params.toOwnedSlice(p.arena),
                .body = try body.toOwnedSlice(p.arena),
            } },
        });
    }

    fn parseOperandList(p: *Parser) Error![]Operand {
        var ops: std.ArrayList(Operand) = .empty;
        if (p.atLineEnd()) return ops.toOwnedSlice(p.arena);
        while (true) {
            try ops.append(p.arena, try p.parseOperand());
            if (p.tok.tag != .comma) break;
            try p.advance();
        }
        return ops.toOwnedSlice(p.arena);
    }

    fn parseOperand(p: *Parser) Error!Operand {
        const line = p.tok.line;
        const col = p.tok.col;

        switch (p.tok.tag) {
            .string => {
                const text = p.tok.text;
                try p.advance();
                return .{ .line = line, .col = col, .payload = .{ .string = text } };
            },
            .lbracket => {
                try p.advance();
                if (p.tok.tag != .identifier)
                    return p.fail("expected base register after '['", .{}, p.tok.line, p.tok.col);
                const base = registerFromName(p.tok.text) orelse
                    return p.fail("'{s}' is not a register (memory operands are [reg + offset])", .{p.tok.text}, p.tok.line, p.tok.col);
                try p.advance();
                var offset: ?*Expr = null;
                if (p.tok.tag == .plus or p.tok.tag == .minus) {
                    const negate = p.tok.tag == .minus; // decision u
                    try p.advance();
                    var e = try p.parseExpr();
                    if (negate) {
                        const node = try p.arena.create(Expr);
                        node.* = .{ .unary = .{ .op = .neg, .sub = e } };
                        e = node;
                    }
                    offset = e;
                }
                if (p.tok.tag != .rbracket)
                    return p.fail("expected ']' to close memory operand", .{}, p.tok.line, p.tok.col);
                try p.advance();
                return .{ .line = line, .col = col, .payload = .{ .memory = .{ .base = base, .offset = offset } } };
            },
            .identifier => {
                // Reserved register word (decision s)?
                if (registerFromName(p.tok.text)) |r| {
                    try p.advance();
                    return .{ .line = line, .col = col, .payload = .{ .register = r } };
                }
                // Fall through: symbol inside an expression.
            },
            else => {},
        }
        const e = try p.parseExpr();
        return .{ .line = line, .col = col, .payload = .{ .expr = e } };
    }

    // -- Expressions (decision t precedence) ------------------------------

    fn newExpr(p: *Parser, value: Expr) Error!*Expr {
        const node = try p.arena.create(Expr);
        node.* = value;
        return node;
    }

    fn parseExpr(p: *Parser) Error!*Expr {
        return p.parseBinary(0);
    }

    const Level = struct { tag: lexer.Tag, op: BinOp };
    /// Loosest binding first (decision t): | ^ & (<< >>) (+ -) (* / %).
    const levels = [_][]const Level{
        &.{.{ .tag = .pipe, .op = .bor }},
        &.{.{ .tag = .caret, .op = .bxor }},
        &.{.{ .tag = .amp, .op = .band }},
        &.{ .{ .tag = .shl, .op = .shl }, .{ .tag = .shr, .op = .shr } },
        &.{ .{ .tag = .plus, .op = .add }, .{ .tag = .minus, .op = .sub } },
        &.{ .{ .tag = .star, .op = .mul }, .{ .tag = .slash, .op = .div }, .{ .tag = .percent, .op = .mod } },
    };

    fn parseBinary(p: *Parser, level: usize) Error!*Expr {
        if (level == levels.len) return p.parseUnary();
        var lhs = try p.parseBinary(level + 1);
        outer: while (true) {
            for (levels[level]) |cand| {
                if (p.tok.tag == cand.tag) {
                    try p.advance();
                    const rhs = try p.parseBinary(level + 1);
                    lhs = try p.newExpr(.{ .binary = .{ .op = cand.op, .lhs = lhs, .rhs = rhs } });
                    continue :outer;
                }
            }
            return lhs;
        }
    }

    fn parseUnary(p: *Parser) Error!*Expr {
        switch (p.tok.tag) {
            .minus => {
                try p.advance();
                return p.newExpr(.{ .unary = .{ .op = .neg, .sub = try p.parseUnary() } });
            },
            .tilde => {
                try p.advance();
                return p.newExpr(.{ .unary = .{ .op = .bit_not, .sub = try p.parseUnary() } });
            },
            else => return p.parsePrimary(),
        }
    }

    fn parsePrimary(p: *Parser) Error!*Expr {
        const t = p.tok;
        switch (t.tag) {
            .number => {
                try p.advance();
                return p.newExpr(.{ .number = t.value });
            },
            .identifier => {
                if (registerFromName(t.text) != null)
                    return p.fail("register '{s}' is not valid inside an expression (decision s)", .{t.text}, t.line, t.col);
                try p.advance();
                return p.newExpr(.{ .symbol = .{ .name = t.text, .line = t.line, .col = t.col } });
            },
            .macro_param => {
                try p.advance();
                return p.newExpr(.{ .macro_param = .{ .name = t.text, .line = t.line, .col = t.col } });
            },
            .lparen => {
                try p.advance();
                const e = try p.parseExpr();
                if (p.tok.tag != .rparen)
                    return p.fail("expected ')'", .{}, p.tok.line, p.tok.col);
                try p.advance();
                return e;
            },
            else => return p.fail("expected expression, found '{t}'", .{t.tag}, t.line, t.col),
        }
    }
};

/// Convenience: parse a whole source text in one call.
pub fn parse(arena: std.mem.Allocator, src: []const u8) Error![]Item {
    var p = try Parser.init(arena, src);
    return p.parseProgram();
}

// ---------------------------------------------------------------------------
// Tests (task 10.2 acceptance: parser produces correct AST).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectNumber(e: *const Expr, want: u32) !void {
    try testing.expectEqual(Expr{ .number = want }, e.*);
}

test "hello.asm shape (§8.3 example program)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\; hello.asm
        \\    ORG $04100
        \\    EQU SYS_PUTSTR, $FC104
        \\start:
        \\    LI    R1, msg
        \\    CALLA SYS_PUTSTR
        \\    HLT
        \\msg:
        \\    DB "HELLO", 0
        \\
    ;
    const items = try parse(arena, src);
    try testing.expectEqual(@as(usize, 8), items.len);

    try testing.expectEqual(Directive.org, items[0].payload.directive.kind);
    try expectNumber(items[0].payload.directive.args[0].payload.expr, 0x04100);

    const equ = items[1].payload.directive;
    try testing.expectEqual(Directive.equ, equ.kind);
    try testing.expectEqualStrings("SYS_PUTSTR", equ.args[0].payload.expr.symbol.name);
    try expectNumber(equ.args[1].payload.expr, 0xFC104);

    try testing.expectEqualStrings("start", items[2].payload.label);

    const li = items[3].payload.statement;
    try testing.expectEqualStrings("LI", li.head);
    try testing.expectEqual(@as(u4, 1), li.operands[0].payload.register);
    try testing.expectEqualStrings("msg", li.operands[1].payload.expr.symbol.name);

    try testing.expectEqualStrings("CALLA", items[4].payload.statement.head);
    try testing.expectEqualStrings("HLT", items[5].payload.statement.head);
    try testing.expectEqual(@as(usize, 0), items[5].payload.statement.operands.len);

    try testing.expectEqualStrings("msg", items[6].payload.label);
    const db = items[7].payload.directive;
    try testing.expectEqual(Directive.db, db.kind);
    try testing.expectEqualStrings("HELLO", db.args[0].payload.string);
    try expectNumber(db.args[1].payload.expr, 0);
}

test "label and instruction on one line; register aliases (decision s)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = try parse(arena, "loop: ADD sp, SP, Zero\n");
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("loop", items[0].payload.label);
    const s = items[1].payload.statement;
    try testing.expectEqual(@as(u4, 15), s.operands[0].payload.register);
    try testing.expectEqual(@as(u4, 15), s.operands[1].payload.register);
    try testing.expectEqual(@as(u4, 0), s.operands[2].payload.register);
}

test "memory operands: [reg + expr], [reg], [reg - expr] (decision u)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = try parse(arena,
        \\LW R1, [R2 + 4]
        \\SW [R3], R4
        \\LB R5, [FP - 2]
        \\
    );
    const lw = items[0].payload.statement;
    const mem0 = lw.operands[1].payload.memory;
    try testing.expectEqual(@as(u4, 2), mem0.base);
    try expectNumber(mem0.offset.?, 4);

    const sw = items[1].payload.statement;
    const mem1 = sw.operands[0].payload.memory;
    try testing.expectEqual(@as(u4, 3), mem1.base);
    try testing.expectEqual(@as(?*Expr, null), mem1.offset);
    try testing.expectEqual(@as(u4, 4), sw.operands[1].payload.register);

    const lb = items[2].payload.statement;
    const mem2 = lb.operands[1].payload.memory;
    try testing.expectEqual(@as(u4, 13), mem2.base);
    try testing.expectEqual(UnOp.neg, mem2.offset.?.unary.op);
    try expectNumber(mem2.offset.?.unary.sub, 2);
}

test "expression precedence (decision t)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1 | 2 ^ 3 & 4 << 5 + 6 * 7  ⇒  1 | (2 ^ (3 & (4 << (5 + (6 * 7)))))
    const items = try parse(arena, "DW 1 | 2 ^ 3 & 4 << 5 + 6 * 7\n");
    const top = items[0].payload.directive.args[0].payload.expr;
    try testing.expectEqual(BinOp.bor, top.binary.op);
    try expectNumber(top.binary.lhs, 1);
    const xor_n = top.binary.rhs;
    try testing.expectEqual(BinOp.bxor, xor_n.binary.op);
    const and_n = xor_n.binary.rhs;
    try testing.expectEqual(BinOp.band, and_n.binary.op);
    const shl_n = and_n.binary.rhs;
    try testing.expectEqual(BinOp.shl, shl_n.binary.op);
    const add_n = shl_n.binary.rhs;
    try testing.expectEqual(BinOp.add, add_n.binary.op);
    const mul_n = add_n.binary.rhs;
    try testing.expectEqual(BinOp.mul, mul_n.binary.op);

    // Parentheses and left association: (8 - 2) - 1.
    const items2 = try parse(arena, "DW (8 - 2) - 1\n");
    const sub2 = items2[0].payload.directive.args[0].payload.expr;
    try testing.expectEqual(BinOp.sub, sub2.binary.op);
    try expectNumber(sub2.binary.rhs, 1);
    try testing.expectEqual(BinOp.sub, sub2.binary.lhs.binary.op);
}

test "macro definition and invocation (§8.3, decision v)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\MACRO LOAD_ADDR reg, addr
        \\    LI   \reg, (\addr & $FFFF)
        \\    LUI  \reg, (\addr >> 16)
        \\ENDMACRO
        \\    LOAD_ADDR R1, $40000
        \\
    ;
    const items = try parse(arena, src);
    try testing.expectEqual(@as(usize, 2), items.len);

    const def = items[0].payload.macro_def;
    try testing.expectEqualStrings("LOAD_ADDR", def.name);
    try testing.expectEqual(@as(usize, 2), def.params.len);
    try testing.expectEqualStrings("reg", def.params[0]);
    try testing.expectEqualStrings("addr", def.params[1]);
    try testing.expectEqual(@as(usize, 2), def.body.len);

    const li = def.body[0].payload.statement;
    try testing.expectEqualStrings("LI", li.head);
    try testing.expectEqualStrings("reg", li.operands[0].payload.expr.macro_param.name);
    const and_e = li.operands[1].payload.expr;
    try testing.expectEqual(BinOp.band, and_e.binary.op);
    try testing.expectEqualStrings("addr", and_e.binary.lhs.macro_param.name);

    const call = items[1].payload.statement;
    try testing.expectEqualStrings("LOAD_ADDR", call.head);
    try testing.expectEqual(@as(u4, 1), call.operands[0].payload.register);
}

test "directives are case-insensitive; labels case-sensitive (decision r)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = try parse(arena, "org $100\nSection code\nFoo:\nfoo:\n");
    try testing.expectEqual(Directive.org, items[0].payload.directive.kind);
    try testing.expectEqual(Directive.section, items[1].payload.directive.kind);
    try testing.expectEqualStrings("code", items[1].payload.directive.args[0].payload.expr.symbol.name);
    // Distinct labels — no case folding.
    try testing.expectEqualStrings("Foo", items[2].payload.label);
    try testing.expectEqualStrings("foo", items[3].payload.label);
}

test "parse errors carry position and message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Unclosed memory operand.
    {
        var p = try Parser.init(arena, "LW R1, [R2 + 4\n");
        try testing.expectError(Error.Parse, p.parseProgram());
        try testing.expect(std.mem.indexOf(u8, p.err_msg, "']'") != null);
        try testing.expectEqual(@as(u32, 1), p.err_line);
    }
    // Register inside an expression (decision s). Note `DW R5 + 1` is
    // different: R5 at operand head parses as a *register operand* and the
    // '+' trips "expected end of line" — the in-expression check needs the
    // register in a non-head position.
    {
        var p = try Parser.init(arena, "DW 1 + R5\n");
        try testing.expectError(Error.Parse, p.parseProgram());
        try testing.expect(std.mem.indexOf(u8, p.err_msg, "not valid inside an expression") != null);
    }
    // ENDMACRO without MACRO; unterminated MACRO.
    {
        var p = try Parser.init(arena, "ENDMACRO\n");
        try testing.expectError(Error.Parse, p.parseProgram());
    }
    {
        var p = try Parser.init(arena, "MACRO M\nNOP\n");
        try testing.expectError(Error.Parse, p.parseProgram());
        try testing.expect(std.mem.indexOf(u8, p.err_msg, "unterminated MACRO") != null);
    }
    // Nested MACRO (decision v).
    {
        var p = try Parser.init(arena, "MACRO A\nMACRO B\nENDMACRO\nENDMACRO\n");
        try testing.expectError(Error.Parse, p.parseProgram());
        try testing.expect(std.mem.indexOf(u8, p.err_msg, "do not nest") != null);
    }
    // Trailing junk after operands.
    {
        var p = try Parser.init(arena, "NOP 1 2\n");
        try testing.expectError(Error.Parse, p.parseProgram());
        try testing.expect(std.mem.indexOf(u8, p.err_msg, "end of line") != null);
    }
}

test "no-file-without-newline still parses (EOF terminates a statement)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = try parse(arena, "HLT");
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("HLT", items[0].payload.statement.head);
}
