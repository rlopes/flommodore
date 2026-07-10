//! flas .flst listing writer (Block 10, task 10.10).
//!
//! Renders codegen's pass-2 listing entries side by side with the source
//! text per Phase 8 §8.8 (bytes in file/memory order — amendment §8.7).
//! Acceptance: the output reproduces the §8.8 hello.asm example verbatim.
//!
//! Row layout, reverse-engineered byte-exactly from the §8.8 example:
//!
//!   $04100  10 41 40 14   start:  LI    R1, msg
//!   ADDR(6)|2sp|BYTES(11)|3sp|LABEL(8)|STATEMENT
//!
//!   $04110              msg:
//!   ADDR(6)|14sp|LABEL:            (standalone label row)
//!
//!   $04114  4F 2C 20 46
//!   ADDR(6)|2sp|BYTES               (data continuation row)
//!
//! Implementation decisions (continuing objfile.zig's aj–ak):
//!   (al) Rendering rules that reproduce §8.8 exactly:
//!        - Only emitting items appear: instructions, data directives, and
//!          labels. ORG/SECTION/EQU, blank lines, and pure comments are
//!          omitted; bss rows are omitted (no payload to show).
//!        - The statement column echoes the item's SOURCE LINE with the
//!          comment stripped (quote-aware) and surrounding whitespace
//!          trimmed — preserving the programmer's own operand spacing
//!          (`LI    R1, msg`).
//!        - A label merges onto the next row when that row is an
//!          INSTRUCTION at the same address (`start:  LI ...`); before a
//!          data directive it gets a standalone row (`msg:` in §8.8).
//!          The label field is `name:` padded to at least 8 columns with
//!          at least 2 trailing spaces.
//!        - Data longer than 4 bytes continues on address-advanced rows
//!          of up to 4 bytes with no statement text.
//!        - Addresses are `$` + 5 uppercase hex digits (20-bit space);
//!          for relocatable sections the load address is 0, so the
//!          "address" is the section offset. No row has trailing spaces.
//!   (am) Listing entries carry the line numbers of the macro-EXPANDED
//!        AST, so an expanded macro lists its body lines (per expansion),
//!        which is what a listing is for. Items synthesized without a
//!        real source line fall back to an empty statement column.

const std = @import("std");
const codegen = @import("codegen");

pub const Error = error{OutOfMemory};

/// Render the .flst text for `obj` (assembled from `src`).
pub fn emit(arena: std.mem.Allocator, src: []const u8, obj: *const codegen.Object) Error![]u8 {
    // 1-based line table.
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.append(arena, ""); // index 0 unused
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(arena, l);

    var out: std.ArrayList(u8) = .empty;
    var pending_label: ?codegen.ListingEntry = null;

    for (obj.listing) |entry| {
        switch (entry.kind) {
            .label => {
                if (pending_label) |p| try labelRow(arena, &out, obj, p);
                pending_label = entry;
            },
            .instr => {
                var label_field: []const u8 = "        ";
                if (pending_label) |p| {
                    if (p.section == entry.section and p.offset == entry.offset) {
                        label_field = try labelField(arena, p.name);
                    } else {
                        try labelRow(arena, &out, obj, p);
                    }
                    pending_label = null;
                }
                const bytes = sectionBytes(obj, entry);
                try byteRow(arena, &out, addrOf(obj, entry), bytes, label_field, statementText(lines.items, entry.line));
            },
            .data => {
                if (pending_label) |p| {
                    try labelRow(arena, &out, obj, p); // labels never merge into data (decision al)
                    pending_label = null;
                }
                const bytes = sectionBytes(obj, entry);
                var addr = addrOf(obj, entry);
                var rest = bytes;
                var first = true;
                while (rest.len > 0) {
                    const n = @min(rest.len, 4);
                    if (first) {
                        try byteRow(arena, &out, addr, rest[0..n], "        ", statementText(lines.items, entry.line));
                        first = false;
                    } else {
                        try byteRow(arena, &out, addr, rest[0..n], "", "");
                    }
                    rest = rest[n..];
                    addr +%= @intCast(n);
                }
            },
        }
    }
    if (pending_label) |p| try labelRow(arena, &out, obj, p);

    return out.toOwnedSlice(arena);
}

fn addrOf(obj: *const codegen.Object, e: codegen.ListingEntry) u32 {
    return obj.sections[e.section].load_addr +% e.offset;
}

fn sectionBytes(obj: *const codegen.Object, e: codegen.ListingEntry) []const u8 {
    return obj.sections[e.section].data.items[e.offset .. e.offset + e.size];
}

/// `name:` padded to at least 8 columns, always ≥ 2 trailing spaces.
fn labelField(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    const width = @max(8, name.len + 3);
    const buf = try arena.alloc(u8, width);
    @memset(buf, ' ');
    @memcpy(buf[0..name.len], name);
    buf[name.len] = ':';
    return buf;
}

/// Standalone label row: ADDR + 14 spaces + `name:` (per the §8.8 msg: row).
fn labelRow(arena: std.mem.Allocator, out: *std.ArrayList(u8), obj: *const codegen.Object, e: codegen.ListingEntry) Error!void {
    var abuf: [8]u8 = undefined;
    const a = std.fmt.bufPrint(&abuf, "${X:0>5}", .{addrOf(obj, e)}) catch unreachable;
    try out.appendSlice(arena, a);
    try out.appendNTimes(arena, ' ', 14);
    try out.appendSlice(arena, e.name);
    try out.appendSlice(arena, ":\n");
}

/// ADDR + 2sp + bytes (padded to 11 iff content follows) + 3sp + label
/// field + statement. Continuation rows pass empty label/statement.
fn byteRow(arena: std.mem.Allocator, out: *std.ArrayList(u8), addr: u32, bytes: []const u8, label_field: []const u8, statement: []const u8) Error!void {
    var abuf: [8]u8 = undefined;
    const a = std.fmt.bufPrint(&abuf, "${X:0>5}", .{addr}) catch unreachable;
    try out.appendSlice(arena, a);
    try out.appendSlice(arena, "  ");
    var col: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i > 0) {
            try out.append(arena, ' ');
            col += 1;
        }
        var bbuf: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&bbuf, "{X:0>2}", .{b}) catch unreachable;
        try out.appendSlice(arena, &bbuf);
        col += 2;
    }
    const tail = label_field.len > 0 or statement.len > 0;
    if (tail) {
        try out.appendNTimes(arena, ' ', (11 - col) + 3);
        try out.appendSlice(arena, label_field);
        try out.appendSlice(arena, statement);
    }
    try out.append(arena, '\n');
}

/// Source line with the comment stripped (quote-aware) and whitespace
/// trimmed — the statement column of decision al.
fn statementText(lines: []const []const u8, line: u32) []const u8 {
    if (line == 0 or line >= lines.len) return "";
    const l = lines[line];
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

// ---------------------------------------------------------------------------
// Tests (task 10.10 acceptance: §8.8 hello.asm example, verbatim).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "hello.asm listing reproduces the Phase 8 §8.8 example" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Exact §8.3 hello.asm source (comments and spacing preserved).
    const src =
        \\; hello.asm — print "HELLO" to the screen via BIOS system call
        \\
        \\    ORG $04100          ; start of free RAM
        \\
        \\    EQU SYS_PUTSTR, $FC104
        \\    EQU SYS_GETKEY, $FC118
        \\
        \\start:
        \\    LI    R1, msg       ; R1 = address of string
        \\    CALLA SYS_PUTSTR    ; call BIOS print string
        \\    CALLA SYS_GETKEY    ; wait for a keypress
        \\    HLT                 ; halt
        \\
        \\msg:
        \\    DB "HELLO, FLOMMODORE!", 0   ; null-terminated string
        \\
    ;
    const incbins = codegen.IncbinMap.empty;
    const obj = try codegen.assemble(arena, src, &incbins);
    const flst = try emit(arena, src, &obj);

    // §8.8 example rows (the doc's trailing `...` elides the remaining DB
    // continuation rows, completed here). Worked words per §8.8: LI →
    // $14404110, CALLA $FC104 → $AC0FC104, HLT → $E4000000.
    const expected =
        \\$04100  10 41 40 14   start:  LI    R1, msg
        \\$04104  04 C1 0F AC           CALLA SYS_PUTSTR
        \\$04108  18 C1 0F AC           CALLA SYS_GETKEY
        \\$0410C  00 00 00 E4           HLT
        \\$04110              msg:
        \\$04110  48 45 4C 4C           DB "HELLO, FLOMMODORE!", 0
        \\$04114  4F 2C 20 46
        \\$04118  4C 4F 4D 4D
        \\$0411C  4F 44 4F 52
        \\$04120  45 21 00
        \\
    ;
    try testing.expectEqualStrings(expected, flst);
}

test "short data row, trailing label, ALIGN padding row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\    ORG $00100
        \\    DB 1
        \\    ALIGN 4
        \\done:
        \\
    ;
    const incbins = codegen.IncbinMap.empty;
    const obj = try codegen.assemble(arena, src, &incbins);
    const flst = try emit(arena, src, &obj);

    const expected =
        \\$00100  01                    DB 1
        \\$00101  00 00 00              ALIGN 4
        \\$00104              done:
        \\
    ;
    try testing.expectEqualStrings(expected, flst);
}
