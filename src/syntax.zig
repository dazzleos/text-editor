//! Colouring code: JSON, Python and Zig, chosen by the file's name. Each
//! highlighter reads the whole text and says what each byte is (see
//! `ui.Highlight`); it is quick and forgiving rather than a full parser, so
//! text that does not parse is still coloured as far as it makes sense.

const std = @import("std");
const ui = @import("ui");

const Highlight = ui.Highlight;

pub const Language = enum { plain, json, python, zig };

/// The language of a file named `name`, by the ending of its name.
pub fn languageOf(name: []const u8) Language {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .plain;
    const ext = name[dot + 1 ..];
    const table = [_]struct { []const u8, Language }{
        .{ "json", .json },
        .{ "py", .python },
        .{ "pyw", .python },
        .{ "zig", .zig },
        .{ "zon", .zig },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
    return .plain;
}

/// The highlighter for `language`, if it is code.
pub fn highlighter(language: Language) ?ui.TextArea.Highlighter {
    return switch (language) {
        .plain => null,
        .json => json,
        .python => python,
        .zig => zig,
    };
}

// --- Shared pieces ---------------------------------------------------------------

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdent(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn identEnd(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and isIdent(text[i])) i += 1;
    return i;
}

/// The end of a number starting at `from`: digits, letters (0x1F, 1e9, 10u),
/// underscores, dots between digits, and a sign after an exponent.
fn numberEnd(text: []const u8, from: usize) usize {
    var i = from;
    const hex = i + 1 < text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X');
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        if (c == '.' and i + 1 < text.len and std.ascii.isDigit(text[i + 1])) continue;
        if ((c == '+' or c == '-') and !hex and i > from and (text[i - 1] == 'e' or text[i - 1] == 'E')) continue;
        break;
    }
    return i;
}

/// The end of a quoted string starting at `from` (its quote), on one line:
/// after its closing quote, or at the line's end if it has none.
fn quotedEnd(text: []const u8, from: usize) usize {
    const q = text[from];
    var i = from + 1;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '\\' => i += 1,
        '\n' => return i,
        else => if (text[i] == q) return i + 1,
    };
    return text.len;
}

fn lineEnd(text: []const u8, from: usize) usize {
    return std.mem.indexOfScalarPos(u8, text, from, '\n') orelse text.len;
}

fn nextNonSpace(text: []const u8, from: usize) ?u8 {
    var i = from;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return if (i < text.len) text[i] else null;
}

fn mark(out: []Highlight, from: usize, to: usize, h: Highlight) void {
    @memset(out[from..@min(to, out.len)], h);
}

fn isOneOf(word: []const u8, comptime words: []const []const u8) bool {
    inline for (words) |w| if (std.mem.eql(u8, word, w)) return true;
    return false;
}

// --- JSON ----------------------------------------------------------------------

/// Names (the strings before a colon), strings, numbers, and true, false and
/// null.
pub fn json(text: []const u8, out: []Highlight) void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"') {
            const end = quotedEnd(text, i);
            mark(out, i, end, if (nextNonSpace(text, end) == ':') .property else .string);
            i = end;
        } else if (std.ascii.isDigit(c) or (c == '-' and i + 1 < text.len and std.ascii.isDigit(text[i + 1]))) {
            const end = numberEnd(text, i + 1);
            mark(out, i, end, .number);
            i = end;
        } else if (std.ascii.isAlphabetic(c)) {
            const end = identEnd(text, i);
            if (isOneOf(text[i..end], &.{ "true", "false", "null" })) mark(out, i, end, .constant);
            i = end;
        } else i += 1;
    }
}

// --- Python --------------------------------------------------------------------

const python_keywords = [_][]const u8{
    "and",    "as",     "assert", "async",  "await",    "break", "class", "continue", "def",
    "del",    "elif",   "else",   "except", "finally",  "for",   "from",  "global",   "if",
    "import", "in",     "is",     "lambda", "nonlocal", "not",   "or",    "pass",     "raise",
    "return", "try",    "while",  "with",   "yield",    "match", "case",
};

const python_builtins = [_][]const u8{
    "abs",   "all",        "any",        "bool",    "bytes",  "callable", "chr",     "dict",   "dir",
    "enumerate", "filter", "float",      "format",  "getattr", "hasattr", "hash",   "hex",    "id",
    "input", "int",        "isinstance", "issubclass", "iter", "len",     "list",    "map",    "max",
    "min",   "next",       "object",     "open",    "ord",    "print",    "range",   "repr",   "reversed",
    "round", "set",        "setattr",    "sorted",  "str",    "sum",      "super",   "tuple",  "type",
    "zip",   "self",       "cls",
};

/// Comments, strings (with their prefixes, and triple-quoted ones over many
/// lines), numbers, keywords, True, False and None, built-in functions,
/// decorators, and the names `def` and `class` give.
pub fn python(text: []const u8, out: []Highlight) void {
    var i: usize = 0;
    // What the last word was: the next names a function or a class.
    var naming: ?Highlight = null;
    while (i < text.len) {
        const c = text[i];
        if (c == '#') {
            const end = lineEnd(text, i);
            mark(out, i, end, .comment);
            i = end;
        } else if (c == '"' or c == '\'') {
            const end = pythonStringEnd(text, i);
            mark(out, i, end, .string);
            i = end;
            naming = null;
        } else if (std.ascii.isDigit(c) or (c == '.' and i + 1 < text.len and std.ascii.isDigit(text[i + 1]))) {
            const end = numberEnd(text, i);
            mark(out, i, end, .number);
            i = end;
        } else if (c == '@' and i + 1 < text.len and isIdentStart(text[i + 1]) and atLineStart(text, i)) {
            // A decorator, with its dotted name.
            var end = identEnd(text, i + 1);
            while (end + 1 < text.len and text[end] == '.' and isIdentStart(text[end + 1])) end = identEnd(text, end + 1);
            mark(out, i, end, .builtin);
            i = end;
        } else if (isIdentStart(c)) {
            const end = identEnd(text, i);
            const word = text[i..end];
            // A string's prefix: r"", b'', f"""...""".
            if (end < text.len and (text[end] == '"' or text[end] == '\'') and word.len <= 2 and isStringPrefix(word)) {
                const s_end = pythonStringEnd(text, end);
                mark(out, i, s_end, .string);
                i = s_end;
                continue;
            }
            const h: Highlight = if (naming) |n|
                n
            else if (isOneOf(word, &python_keywords))
                .keyword
            else if (isOneOf(word, &.{ "True", "False", "None" }))
                .constant
            else if (isOneOf(word, &python_builtins))
                .builtin
            else if (nextNonSpace(text, end) == '(')
                .function
            else
                .plain;
            mark(out, i, end, h);
            naming = if (std.mem.eql(u8, word, "def")) .function else if (std.mem.eql(u8, word, "class")) .type else null;
            i = end;
        } else {
            if (c != ' ' and c != '\t') naming = null;
            i += 1;
        }
    }
}

fn isStringPrefix(word: []const u8) bool {
    for (word) |ch| switch (std.ascii.toLower(ch)) {
        'r', 'b', 'f', 'u' => {},
        else => return false,
    };
    return true;
}

fn atLineStart(text: []const u8, i: usize) bool {
    var j = i;
    while (j > 0) {
        j -= 1;
        switch (text[j]) {
            '\n' => return true,
            ' ', '\t' => {},
            else => return false,
        }
    }
    return true;
}

/// The end of a Python string at `from` (its first quote): a triple-quoted
/// one may go over many lines.
fn pythonStringEnd(text: []const u8, from: usize) usize {
    const q = text[from];
    if (from + 2 < text.len and text[from + 1] == q and text[from + 2] == q) {
        var i = from + 3;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\') {
                i += 1;
            } else if (text[i] == q and i + 2 < text.len and text[i + 1] == q and text[i + 2] == q) return i + 3;
        }
        return text.len;
    }
    return quotedEnd(text, from);
}

// --- Zig -------------------------------------------------------------------------

const zig_keywords = [_][]const u8{
    "addrspace", "align",    "allowzero", "and",         "anyframe",    "asm",     "break",    "callconv",
    "catch",     "comptime", "const",     "continue",    "defer",       "else",    "enum",     "errdefer",
    "error",     "export",   "extern",    "fn",          "for",         "if",      "inline",   "linksection",
    "noalias",   "noinline", "nosuspend", "opaque",      "or",          "orelse",  "packed",   "pub",
    "resume",    "return",   "struct",    "suspend",     "switch",      "test",    "threadlocal", "try",
    "union",     "usingnamespace", "var", "volatile",    "while",
};

const zig_types = [_][]const u8{
    "bool",       "void",          "type",         "anytype",     "anyerror", "anyopaque", "noreturn",
    "usize",      "isize",         "comptime_int", "comptime_float", "f16",  "f32",       "f64",
    "f80",        "f128",          "c_int",        "c_uint",      "c_long",   "c_ulong",   "c_char",
    "c_short",    "c_ushort",      "c_longlong",   "c_ulonglong", "c_longdouble",
};

/// Comments, strings (and multi-line ones), characters, numbers, keywords,
/// types (the built-in ones, and names starting with a capital), builtins
/// (@import), constants (true, null, undefined, ...), and functions.
pub fn zig(text: []const u8, out: []Highlight) void {
    var i: usize = 0;
    var after_fn = false;
    while (i < text.len) {
        const c = text[i];
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            const end = lineEnd(text, i);
            mark(out, i, end, .comment);
            i = end;
        } else if (c == '\\' and i + 1 < text.len and text[i + 1] == '\\') {
            // A line of a multi-line string.
            const end = lineEnd(text, i);
            mark(out, i, end, .string);
            i = end;
        } else if (c == '"' or c == '\'') {
            const end = quotedEnd(text, i);
            mark(out, i, end, .string);
            i = end;
        } else if (std.ascii.isDigit(c)) {
            const end = numberEnd(text, i);
            mark(out, i, end, .number);
            i = end;
        } else if (c == '@' and i + 1 < text.len and text[i + 1] == '"') {
            // A name that is not an identifier: @"error".
            const end = quotedEnd(text, i + 1);
            if (after_fn) mark(out, i, end, .function);
            after_fn = false;
            i = end;
        } else if (c == '@' and i + 1 < text.len and isIdentStart(text[i + 1])) {
            const end = identEnd(text, i + 1);
            mark(out, i, end, .builtin);
            i = end;
        } else if (isIdentStart(c)) {
            const end = identEnd(text, i);
            const word = text[i..end];
            // A field or declaration reached with a dot is never a keyword.
            const dotted = i > 0 and text[i - 1] == '.';
            const h: Highlight = if (after_fn)
                .function
            else if (!dotted and isOneOf(word, &zig_keywords))
                .keyword
            else if (!dotted and isOneOf(word, &.{ "true", "false", "null", "undefined", "unreachable" }))
                .constant
            else if (!dotted and (isOneOf(word, &zig_types) or isIntType(word)))
                .type
            else if (nextNonSpace(text, end) == '(')
                .function
            else if (std.ascii.isUpper(word[0]))
                .type
            else
                .plain;
            mark(out, i, end, h);
            after_fn = !dotted and std.mem.eql(u8, word, "fn");
            i = end;
        } else {
            if (c != ' ' and c != '\t' and c != '\n') after_fn = false;
            i += 1;
        }
    }
}

/// u8, i32, u0, ...
fn isIntType(word: []const u8) bool {
    if (word.len < 2 or (word[0] != 'u' and word[0] != 'i')) return false;
    for (word[1..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

// --- Tests -------------------------------------------------------------------------

const testing = std.testing;

/// The text with each byte's highlight, as one letter each (`.` plain).
fn classes(f: ui.TextArea.Highlighter, text: []const u8) ![]u8 {
    const hs = try testing.allocator.alloc(Highlight, text.len);
    defer testing.allocator.free(hs);
    @memset(hs, .plain);
    f(text, hs);
    const out = try testing.allocator.alloc(u8, text.len);
    for (hs, out) |h, *o| o.* = switch (h) {
        .plain => '.',
        .keyword => 'k',
        .type => 't',
        .function => 'f',
        .builtin => 'b',
        .string => 's',
        .number => 'n',
        .constant => 'c',
        .property => 'p',
        .comment => '#',
    };
    return out;
}

fn expectClasses(f: ui.TextArea.Highlighter, text: []const u8, want: []const u8) !void {
    const got = try classes(f, text);
    defer testing.allocator.free(got);
    testing.expectEqualStrings(want, got) catch |err| {
        std.debug.print("text: {s}\n", .{text});
        return err;
    };
}

test "languages by name" {
    try testing.expectEqual(Language.json, languageOf("data.JSON"));
    try testing.expectEqual(Language.python, languageOf("tool.py"));
    try testing.expectEqual(Language.zig, languageOf("main.zig"));
    try testing.expectEqual(Language.zig, languageOf("build.zig.zon"));
    try testing.expectEqual(Language.plain, languageOf("notes.txt"));
    try testing.expectEqual(Language.plain, languageOf("README"));
    try testing.expect(highlighter(.plain) == null);
}

test "JSON" {
    try expectClasses(json, "{\"a\": [1, -2.5e3, true, null, \"x\\\"y\"]}", ".ppp...n..nnnnnn..cccc..cccc..ssssss..");
    try expectClasses(json, "{\"k\" :\"v", ".ppp..ss");
}

test "Python" {
    try expectClasses(python, "def f(x):  # hi", "kkk.f......####");
    try expectClasses(python, "class A(B): pass", "kkkkk.t.....kkkk");
    try expectClasses(python, "x = r'a\\'b' + 0x1F", "....sssssss...nnnn");
    try expectClasses(python, "print(len(s), None)", "bbbbb.bbb.....cccc.");
    try expectClasses(python, "@app.route\ndef go(): return \"\"\"a\nb\"\"\"", "bbbbbbbbbb.kkk.ff....kkkkkk.sssssssss");
    try expectClasses(python, "a @ b; foo()", ".......fff..");
}

test "Zig" {
    try expectClasses(zig, "const x: u8 = @intCast(y); // n", "kkkkk....tt...bbbbbbbb.....####");
    try expectClasses(zig, "pub fn main() !void {}", "kkk.kk.ffff....tttt...");
    try expectClasses(zig, "std.mem.eql(u8, a.len, \"s\\n\")", "........fff.tt.........sssss.");
    try expectClasses(zig, "const S = struct { e: E = .none, n: ?*T = null };", "kkkkk.t...kkkkkk......t...............t...cccc...");
    try expectClasses(zig, "\\\\ line\nx = 'a' + 0x10_00;", "sssssss.....sss...nnnnnnn.");
    try expectClasses(zig, "fn @\"error\"() void", "kk.ffffffff...tttt");
}
