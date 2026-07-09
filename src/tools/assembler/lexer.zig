//! flas lexer — source text → token stream (Block 10, task 10.1).
//!
//! Tokenises the Gab-16 assembly language of Phase 8 §8.3: identifiers,
//! decimal / `$`-hex / `0b`-binary / `'c'`-char literals, `"…"` strings,
//! macro parameters (`\name`), expression operators (needed for the §8.3
//! macro example `(\addr & $FFFF)` / `(\addr >> 16)`), and punctuation.
//! `;` starts a comment running to end of line. Newlines are significant
//! (statement separators) and are emitted as tokens; the parser folds
//! consecutive ones.
//!
//! The lexer does NOT classify identifiers into mnemonics / directives /
//! registers / labels — that is the parser's job (parser.zig), keeping this
//! module a pure tokeniser.
//!
//! Implementation decisions (continuing the lettered series; input.zig used
//! a–j, debugger.zig k–m):
//!   (n) Identifiers are `[A-Za-z_][A-Za-z0-9_]*`. The spec's examples use
//!       plain names for labels, sections, macros and constants; no dotted
//!       or unicode names appear anywhere in Phase 8, so none are accepted.
//!   (o) Character and string literals support the escape sequences
//!       `\n \t \r \0 \\ \' \"` (§8.3 is silent; these are the minimal C
//!       set a null-terminated-string workflow needs). Any other escape is
//!       a lex error rather than silently passing the backslash through.
//!   (p) Numeric literals must fit in 32 bits unsigned ($FFFFFFFF max —
//!       DD's width, the widest field any directive or encoder consumes).
//!       Out-of-range literals are a lex error at the literal, not a wrap.
//!       Negation is not the lexer's business: `-5` lexes as `minus`,
//!       `number 5`, and the expression evaluator applies the sign.
//!   (q) Token values carry source line and column (1-based) for
//!       diagnostics; every later stage reports positions through these.

const std = @import("std");

pub const Tag = enum {
    identifier,
    number, // value in Token.value (decision p)
    string, // Token.text is the *decoded* bytes (escapes applied)
    macro_param, // `\name` — Token.text is the name without the backslash
    comma,
    colon,
    lbracket,
    rbracket,
    lparen,
    rparen,
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    tilde,
    shl, // <<
    shr, // >>
    newline,
    eof,
};

pub const Token = struct {
    tag: Tag,
    /// Raw source slice for identifiers; decoded bytes for strings
    /// (allocated in the lexer's arena — see Lexer.init).
    text: []const u8 = "",
    /// Literal value for .number (decision p).
    value: u32 = 0,
    line: u32,
    col: u32,
};

pub const Error = error{ Lex, OutOfMemory };

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
    /// Arena for decoded string literals; owned by the caller.
    arena: std.mem.Allocator,
    /// Valid after `Error.Lex`: human-readable message and its position.
    err_msg: []const u8 = "",
    err_line: u32 = 0,
    err_col: u32 = 0,

    pub fn init(arena: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .arena = arena, .src = src };
    }

    fn fail(l: *Lexer, comptime fmt: []const u8, args: anytype, line: u32, col: u32) Error {
        l.err_msg = std.fmt.allocPrint(l.arena, fmt, args) catch "out of memory formatting diagnostic";
        l.err_line = line;
        l.err_col = col;
        return Error.Lex;
    }

    fn peek(l: *const Lexer) ?u8 {
        return if (l.pos < l.src.len) l.src[l.pos] else null;
    }

    fn advance(l: *Lexer) void {
        if (l.pos < l.src.len) {
            if (l.src[l.pos] == '\n') {
                l.line += 1;
                l.col = 1;
            } else {
                l.col += 1;
            }
            l.pos += 1;
        }
    }

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }
    fn isIdentCont(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Next token, or Error.Lex with err_msg/err_line/err_col set.
    pub fn next(l: *Lexer) Error!Token {
        // Skip horizontal whitespace and comments (but not newlines).
        while (l.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\r') {
                l.advance();
            } else if (c == ';') {
                while (l.peek()) |c2| {
                    if (c2 == '\n') break;
                    l.advance();
                }
            } else break;
        }

        const start_line = l.line;
        const start_col = l.col;
        const c = l.peek() orelse
            return .{ .tag = .eof, .line = start_line, .col = start_col };

        // Single- and double-character punctuation.
        switch (c) {
            '\n' => {
                l.advance();
                return .{ .tag = .newline, .line = start_line, .col = start_col };
            },
            ',' => return l.punct(.comma, start_line, start_col),
            ':' => return l.punct(.colon, start_line, start_col),
            '[' => return l.punct(.lbracket, start_line, start_col),
            ']' => return l.punct(.rbracket, start_line, start_col),
            '(' => return l.punct(.lparen, start_line, start_col),
            ')' => return l.punct(.rparen, start_line, start_col),
            '+' => return l.punct(.plus, start_line, start_col),
            '-' => return l.punct(.minus, start_line, start_col),
            '*' => return l.punct(.star, start_line, start_col),
            '/' => return l.punct(.slash, start_line, start_col),
            '%' => return l.punct(.percent, start_line, start_col),
            '&' => return l.punct(.amp, start_line, start_col),
            '|' => return l.punct(.pipe, start_line, start_col),
            '^' => return l.punct(.caret, start_line, start_col),
            '~' => return l.punct(.tilde, start_line, start_col),
            '<' => {
                l.advance();
                if (l.peek() == '<') {
                    l.advance();
                    return .{ .tag = .shl, .line = start_line, .col = start_col };
                }
                return l.fail("expected '<<' (single '<' is not an operator)", .{}, start_line, start_col);
            },
            '>' => {
                l.advance();
                if (l.peek() == '>') {
                    l.advance();
                    return .{ .tag = .shr, .line = start_line, .col = start_col };
                }
                return l.fail("expected '>>' (single '>' is not an operator)", .{}, start_line, start_col);
            },
            '\\' => {
                l.advance();
                const s = l.pos;
                if (l.peek() == null or !isIdentStart(l.peek().?))
                    return l.fail("expected macro parameter name after '\\'", .{}, start_line, start_col);
                while (l.peek()) |c2| {
                    if (!isIdentCont(c2)) break;
                    l.advance();
                }
                return .{ .tag = .macro_param, .text = l.src[s..l.pos], .line = start_line, .col = start_col };
            },
            '$' => {
                l.advance();
                const s = l.pos;
                while (l.peek()) |c2| {
                    if (!std.ascii.isHex(c2)) break;
                    l.advance();
                }
                if (l.pos == s)
                    return l.fail("expected hex digits after '$'", .{}, start_line, start_col);
                const v = std.fmt.parseInt(u32, l.src[s..l.pos], 16) catch
                    return l.fail("hex literal '${s}' exceeds 32 bits", .{l.src[s..l.pos]}, start_line, start_col);
                return .{ .tag = .number, .value = v, .line = start_line, .col = start_col };
            },
            '\'' => {
                l.advance();
                const ch = try l.charOrEscape('\'', start_line, start_col);
                if (l.peek() != '\'')
                    return l.fail("unterminated character literal", .{}, start_line, start_col);
                l.advance();
                return .{ .tag = .number, .value = ch, .line = start_line, .col = start_col };
            },
            '"' => {
                l.advance();
                var buf: std.ArrayList(u8) = .empty;
                while (true) {
                    const c2 = l.peek() orelse
                        return l.fail("unterminated string literal", .{}, start_line, start_col);
                    if (c2 == '"') {
                        l.advance();
                        break;
                    }
                    if (c2 == '\n')
                        return l.fail("unterminated string literal", .{}, start_line, start_col);
                    const ch = try l.charOrEscape('"', start_line, start_col);
                    try buf.append(l.arena, @intCast(ch));
                }
                return .{ .tag = .string, .text = try buf.toOwnedSlice(l.arena), .line = start_line, .col = start_col };
            },
            else => {},
        }

        if (std.ascii.isDigit(c)) {
            const s = l.pos;
            if (c == '0' and l.pos + 1 < l.src.len and l.src[l.pos + 1] == 'b') {
                l.advance();
                l.advance();
                const bs = l.pos;
                while (l.peek()) |c2| {
                    if (c2 != '0' and c2 != '1') break;
                    l.advance();
                }
                if (l.pos == bs)
                    return l.fail("expected binary digits after '0b'", .{}, start_line, start_col);
                const v = std.fmt.parseInt(u32, l.src[bs..l.pos], 2) catch
                    return l.fail("binary literal '0b{s}' exceeds 32 bits", .{l.src[bs..l.pos]}, start_line, start_col);
                return .{ .tag = .number, .value = v, .line = start_line, .col = start_col };
            }
            while (l.peek()) |c2| {
                if (!std.ascii.isDigit(c2)) break;
                l.advance();
            }
            const v = std.fmt.parseInt(u32, l.src[s..l.pos], 10) catch
                return l.fail("decimal literal '{s}' exceeds 32 bits", .{l.src[s..l.pos]}, start_line, start_col);
            return .{ .tag = .number, .value = v, .line = start_line, .col = start_col };
        }

        if (isIdentStart(c)) {
            const s = l.pos;
            while (l.peek()) |c2| {
                if (!isIdentCont(c2)) break;
                l.advance();
            }
            return .{ .tag = .identifier, .text = l.src[s..l.pos], .line = start_line, .col = start_col };
        }

        return l.fail("unexpected character '{c}' (${X:0>2})", .{ c, c }, start_line, start_col);
    }

    fn punct(l: *Lexer, tag: Tag, line: u32, col: u32) Token {
        l.advance();
        return .{ .tag = tag, .line = line, .col = col };
    }

    /// One character inside a '…' or "…" literal, applying decision (o)
    /// escapes. `quote` is the active delimiter (for error text only).
    fn charOrEscape(l: *Lexer, quote: u8, line: u32, col: u32) Error!u8 {
        _ = quote;
        const c = l.peek() orelse
            return l.fail("unterminated literal", .{}, line, col);
        if (c != '\\') {
            l.advance();
            return c;
        }
        l.advance();
        const e = l.peek() orelse
            return l.fail("unterminated escape sequence", .{}, line, col);
        l.advance();
        return switch (e) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0' => 0,
            '\\' => '\\',
            '\'' => '\'',
            '"' => '"',
            else => l.fail("unknown escape sequence '\\{c}' (decision o)", .{e}, line, col),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests (task 10.1 acceptance).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn lexAll(arena: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Token)) !void {
    var l = Lexer.init(arena, src);
    while (true) {
        const t = try l.next();
        try out.append(arena, t);
        if (t.tag == .eof) break;
    }
}

test "identifiers, punctuation, comments, newlines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var toks: std.ArrayList(Token) = .empty;
    try lexAll(arena, "start:  LI R1, msg ; load\n  HLT\n", &toks);

    const tags = [_]Tag{ .identifier, .colon, .identifier, .identifier, .comma, .identifier, .newline, .identifier, .newline, .eof };
    try testing.expectEqual(tags.len, toks.items.len);
    for (tags, toks.items) |want, got| try testing.expectEqual(want, got.tag);
    try testing.expectEqualStrings("start", toks.items[0].text);
    try testing.expectEqualStrings("LI", toks.items[2].text);
    try testing.expectEqualStrings("msg", toks.items[5].text);
    // Positions (decision q): HLT is line 2, col 3.
    try testing.expectEqual(@as(u32, 2), toks.items[7].line);
    try testing.expectEqual(@as(u32, 3), toks.items[7].col);
}

test "numeric literal forms per §8.3" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var toks: std.ArrayList(Token) = .empty;
    try lexAll(arena, "42 $2A 0b00101010 'A' $FFFFFFFF", &toks);
    try testing.expectEqual(@as(usize, 6), toks.items.len);
    for (toks.items[0..4]) |t| try testing.expectEqual(Tag.number, t.tag);
    try testing.expectEqual(@as(u32, 42), toks.items[0].value);
    try testing.expectEqual(@as(u32, 0x2A), toks.items[1].value);
    try testing.expectEqual(@as(u32, 42), toks.items[2].value);
    try testing.expectEqual(@as(u32, 'A'), toks.items[3].value);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), toks.items[4].value);
}

test "string literals decode escapes (decision o)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var toks: std.ArrayList(Token) = .empty;
    try lexAll(arena, "DB \"HELLO\\n\\0\", 0", &toks);
    try testing.expectEqual(Tag.string, toks.items[1].tag);
    try testing.expectEqualStrings("HELLO\n\x00", toks.items[1].text);
}

test "expression operators and macro params (§8.3 macro example)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var toks: std.ArrayList(Token) = .empty;
    try lexAll(arena, "LI \\reg, (\\addr & $FFFF)\nLUI \\reg, (\\addr >> 16)", &toks);

    try testing.expectEqual(Tag.macro_param, toks.items[1].tag);
    try testing.expectEqualStrings("reg", toks.items[1].text);
    try testing.expectEqual(Tag.lparen, toks.items[3].tag);
    try testing.expectEqual(Tag.macro_param, toks.items[4].tag);
    try testing.expectEqualStrings("addr", toks.items[4].text);
    try testing.expectEqual(Tag.amp, toks.items[5].tag);
    try testing.expectEqual(Tag.number, toks.items[6].tag);
    try testing.expectEqual(Tag.rparen, toks.items[7].tag);
    // Second line: … ( \addr >> 16 )
    try testing.expectEqual(Tag.shr, toks.items[14].tag);
}

test "memory operand brackets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var toks: std.ArrayList(Token) = .empty;
    try lexAll(arena, "LW R1, [R2 + 4]", &toks);
    const tags = [_]Tag{ .identifier, .identifier, .comma, .lbracket, .identifier, .plus, .number, .rbracket, .eof };
    for (tags, toks.items) |want, got| try testing.expectEqual(want, got.tag);
}

test "lex errors carry position and message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Overflow (decision p).
    var l = Lexer.init(arena, "DD $1FFFFFFFF");
    try testing.expectEqual(Tag.identifier, (try l.next()).tag);
    try testing.expectError(Error.Lex, l.next());
    try testing.expect(std.mem.indexOf(u8, l.err_msg, "exceeds 32 bits") != null);
    try testing.expectEqual(@as(u32, 1), l.err_line);
    try testing.expectEqual(@as(u32, 4), l.err_col);

    // Unknown escape (decision o).
    var l2 = Lexer.init(arena, "\"a\\qb\"");
    try testing.expectError(Error.Lex, l2.next());

    // Stray character.
    var l3 = Lexer.init(arena, "LI R1, #5");
    _ = try l3.next();
    _ = try l3.next();
    _ = try l3.next();
    try testing.expectError(Error.Lex, l3.next());
    try testing.expect(std.mem.indexOf(u8, l3.err_msg, "unexpected character") != null);
}

test "single '<' or '>' is an error, '<<'/'>>' lex" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var l = Lexer.init(arena, "1 << 2 >> 3");
    try testing.expectEqual(Tag.number, (try l.next()).tag);
    try testing.expectEqual(Tag.shl, (try l.next()).tag);
    try testing.expectEqual(Tag.number, (try l.next()).tag);
    try testing.expectEqual(Tag.shr, (try l.next()).tag);

    var l2 = Lexer.init(arena, "1 < 2");
    _ = try l2.next();
    try testing.expectError(Error.Lex, l2.next());
}
