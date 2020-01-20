const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const unicode = std.unicode;

pub const Parser = struct {
    it: unicode.Utf8Iterator,
    indent_char: ?u32 = null,
    chars_per_indent: ?u8 = null,
};

fn isWhiteSpace(c: u32) bool {
    return switch (c) {
        ' ', '\t',
        // NO-BREAK SPACE
        0x00A0,
        // OGHAM SPACE MARK
        0x1680,
        // MONGOLIAN VOWEL SEPARATOR
        0x180E,
        // EN QUAD
        0x2000,
        // EM QUAD
        0x2001,
        // EN SPACE
        0x2002,
        // EM SPACE
        0x2003,
        // THREE-PER-EM SPACE
        0x2004,
        // FOUR-PER-EM SPACE
        0x2005,
        // SIX-PER-EM SPACE
        0x2006,
        // FIGURE SPACE
        0x2007,
        // PUNCTUATION SPACE
        0x2008,
        // THIN SPACE
        0x2009,
        // HAIR SPACE
        0x200A,
        // ZERO WIDTH SPACE
        0x200B,
        // NARROW NO-BREAK SPACE
        0x202F,
        // MEDIUM MATHEMATICAL SPACE
        0x205F,
        // IDEOGRAPHIC SPACE
        0x3000,
        // ZERO WIDTH NO-BREAK SPACE
        0xFEFF,
        // HALFWIDTH HANGUL FILLER
        0xFFA0 => true,
        else => false,
    };
}

fn isIdentifier(c: u32) bool {
    // TODO unicode identifiers
    return switch (c) {
        'a'...'z',
        'A'...'Z',
        '_',
        '0'...'9',
        => true,
        else => false,
    };
}

fn getIndent(parser: *Parser, err_stream: var) u8 {
    var count: u32 = 0;
    while (parser.it.nextCodepoint()) |c| {
        if (parser.indent_char) |some| {} else if (isWhiteSpace(c)) {
            parser.indent_char = c;
            count += 1;
        } else {
            if (parser.chars_per_indent) |some| {
                if (count % parser.chars_per_indent) {
                    try err_stream.print("invalid indentation\n", .{});
                    return error.Invalid;
                } else {
                    const levels = @divExact(count, parser.chars_per_indent);
                    if (levels > 25) {
                        try err_stream.print("indentation exceeds maximum of 25 levels\n", .{});
                        return error.Invalid;
                    }
                    return levels;
                }
            } else {
                parser.chars_per_indent = count;
            }
        }
    }
}

pub const Token = union(enum) {
    Eof,
    Identifier: []const u8,
    String: []const u8,
    Number: []const u8,
    Nl,
    Pipe,
    PipeEqual,
    Equal,
    EqualEqual,
    BangEqual,
    LParen,
    RParen,
    Percent,
    PercentEqual,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    Period,
    Ellipsis,
    Caret,
    CaretEqual,
    Plus,
    PlusEqual,
    Minus,
    MinusEqual,
    Asterisk,
    AsteriskEqual,
    // AsteriskAsterisk,
    // AsteriskAsteriskEqual,
    Slash,
    SlashEqual,
    SlashSlash,
    SlashSlashEqual,
    Comma,
    Ampersand,
    AmpersandEqual,
    LArr,
    LArrEqual,
    LArrArr,
    LArrArrEqual,
    RArr,
    RArrEqual,
    RArrArr,
    RArrArrEqual,
    Tilde,

    /// keywords
    Keyword_not,
    Keyword_and,
    Keyword_or,
    Keyword_let,
    Keyword_continue,
    Keyword_break,
    Keyword_return,
    Keyword_if,
    Keyword_else,
    Keyword_false,
    Keyword_true,
    Keyword_for,
    Keyword_while,
    Keyword_match,
    Keyword_catch,
    Keyword_try,
    Keyword_error,
    Keyword_import,

    pub const Keyword = struct {
        bytes: []const u8,
        id: Token,
    };

    pub const keywords = [_]Keyword{
        .{ .bytes = "not", .id = .Keyword_not },
        .{ .bytes = "and", .id = .Keyword_and },
        .{ .bytes = "or", .id = .Keyword_or },
        .{ .bytes = "let", .id = .Keyword_let },
        .{ .bytes = "continue", .id = .Keyword_continue },
        .{ .bytes = "break", .id = .Keyword_break },
        .{ .bytes = "return", .id = .Keyword_return },
        .{ .bytes = "if", .id = .Keyword_if },
        .{ .bytes = "else", .id = .Keyword_else },
        .{ .bytes = "false", .id = .Keyword_false },
        .{ .bytes = "true", .id = .Keyword_true },
        .{ .bytes = "for", .id = .Keyword_for },
        .{ .bytes = "while", .id = .Keyword_while },
        .{ .bytes = "match", .id = .Keyword_match },
        .{ .bytes = "catch", .id = .Keyword_catch },
        .{ .bytes = "try", .id = .Keyword_try },
        .{ .bytes = "error", .id = .Keyword_error },
        .{ .bytes = "import", .id = .Keyword_import },
    };

    pub fn getKeyword(bytes: []const u8) ?Token {
        for (keywords) |kw| {
            if (mem.eql(u8, kw.bytes, bytes)) {
                return kw.id;
            }
        }
        return null;
    }

    pub fn next(it: *unicode.Utf8Iterator, err_stream: var) !Token {
        var start_index = it.i;
        var state: enum {
            Start,
            Cr,
            BackSlash,
            BackSlashCr,
            String,
            EscapeSequence,
            CrEscape,
            HexEscape,
            UnicodeStart,
            UnicodeEscape,
            UnicodeEnd,
            Identifier,
            Equal,
            Bang,
            Pipe,
            Percent,
            Asterisk,
            Plus,
            LArr,
            LArrArr,
            RArr,
            RArrArr,
            Caret,
            Period,
            Period2,
            Minus,
            Slash,
            SlashSlash,
            Ampersand,
            LineComment,
            BinaryNumber,
            OctalNumber,
            HexNumber,
            Number,
            Zero,
            FloatFraction,
            FloatExponent,
            FloatExponentDigits,
        } = .Start;
        var str_delimit: u32 = undefined;
        var counter: u32 = 0;

        while (it.nextCodepoint()) |c| {
            switch (state) {
                .Start => switch (c) {
                    '#' => {
                        state = .LineComment;
                    },
                    '\n' => {
                        return Token.Nl;
                    },
                    '\r' => {
                        state = .Cr;
                    },
                    '"', '\'' => {
                        start_index = it.i;
                        str_delimit = c;
                        state = .String;
                    },
                    '=' => {
                        state = .Equal;
                    },
                    '!' => {
                        state = .Bang;
                    },
                    '|' => {
                        state = .Pipe;
                    },
                    '(' => {
                        return Token.LParen;
                    },
                    ')' => {
                        return Token.RParen;
                    },
                    '[' => {
                        return Token.LBracket;
                    },
                    ']' => {
                        return Token.RBracket;
                    },
                    ',' => {
                        return Token.Comma;
                    },
                    '%' => {
                        state = .Percent;
                    },
                    '*' => {
                        state = .Asterisk;
                    },
                    '+' => {
                        state = .Plus;
                    },
                    '<' => {
                        state = .LArr;
                    },
                    '>' => {
                        state = .RArr;
                    },
                    '^' => {
                        state = .Caret;
                    },
                    '{' => {
                        return Token.LBrace;
                    },
                    '}' => {
                        return Token.RBrace;
                    },
                    '~' => {
                        return Token.Tilde;
                    },
                    '.' => {
                        state = .Period;
                    },
                    '-' => {
                        state = .Minus;
                    },
                    '/' => {
                        state = .Slash;
                    },
                    '&' => {
                        state = .Ampersand;
                    },
                    '0' => {
                        state = .Zero;
                    },
                    '1'...'9' => {
                        state = .Number;
                    },
                    '\\' => {
                        state = .BackSlash;
                    },
                    else => {
                        if (isWhiteSpace(c)) {
                            start_index = it.i;
                        } else if (isIdentifier(c)) {
                            state = .Identifier;
                        } else {
                            try err_stream.print("invalid character\n", .{});
                            return error.Invalid;
                        }
                    },
                },
                .Cr => switch (c) {
                    '\n' => {
                        return Token.Nl;
                    },
                    else => {
                        try err_stream.print("invalid character\n", .{});
                        return error.Invalid;
                    },
                },
                .BackSlash => switch (c) {
                    '\n' => {
                        state = .Start;
                    },
                    '\r' => {
                        state = .BackSlashCr;
                    },
                    else => {
                        try err_stream.print("invalid character\n", .{});
                        return error.Invalid;
                    },
                },
                .BackSlashCr => switch (c) {
                    '\n' => {
                        state = .Start;
                    },
                    else => {
                        try err_stream.print("invalid character\n", .{});
                        return error.Invalid;
                    },
                },
                .String => switch (c) {
                    '\\' => {
                        state = .EscapeSequence;
                    },
                    '\n', '\r' => {
                        try err_stream.print("invalid character\n", .{});
                        return error.Invalid;
                    },
                    else => {
                        if (c == str_delimit) {
                            return Token{ .String = it.bytes[start_index..it.i] };
                        }
                    },
                },
                .EscapeSequence => switch (c) {
                    '\'', '"', '\\', 'n', 'r', 't', '\n' => {
                        state = .String;
                    },
                    '\r' => {
                        state = .CrEscape;
                    },
                    'x' => {
                        counter = 0;
                        state = .HexEscape;
                    },
                    'u' => {
                        state = .UnicodeStart;
                    },
                    else => {
                        try err_stream.print("invalid escape sequence\n", .{});
                        return error.Invalid;
                    },
                },
                .CrEscape => switch (c) {
                    '\n' => {
                        state = .String;
                    },
                    else => {
                        try err_stream.print("invalid character\n", .{});
                        return error.Invalid;
                    },
                },
                .HexEscape => switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        counter += 1;
                        if (counter > 2) {
                            state = .String;
                        }
                    },
                    else => {
                        state = .String;
                    },
                },
                .UnicodeStart => if (c == '{') {
                    counter = 0;
                    state = .UnicodeEscape;
                } else {
                    try err_stream.print("invalid escape sequence\n", .{});
                    return error.Invalid;
                },
                .UnicodeEscape => switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        counter += 1;
                        if (counter > 6) {
                            state = .UnicodeEnd;
                        }
                    },
                    '}' => {
                        state = .String;
                    },
                    else => {
                        try err_stream.print("invalid escape sequence\n", .{});
                        return error.Invalid;
                    },
                },
                .UnicodeEnd => if (c == '}') {
                    state = .String;
                } else {
                    try err_stream.print("invalid escape sequence\n", .{});
                    return error.Invalid;
                },
                .Identifier => {
                    if (!isIdentifier(c)) {
                        it.i -= unicode.utf8CodepointSequenceLength(c) catch unreachable;
                        const slice = it.bytes[start_index..it.i];
                        // directly returning causes llvm error
                        const copy = getKeyword(slice) orelse Token{ .Identifier = slice };
                        return copy;
                    }
                },
                .Equal => switch (c) {
                    '=' => {
                        return Token.EqualEqual;
                    },
                    else => {
                        it.i = start_index + 1;
                        return Token.Equal;
                    },
                },
                .Bang => switch (c) {
                    '=' => {
                        return Token.BangEqual;
                    },
                    else => {
                        try err_stream.print("invalid escape sequence\n", .{});
                        return error.Invalid;
                    },
                },
                .Pipe => switch (c) {
                    '=' => {
                        return Token.PipeEqual;
                    },
                    else => {
                        it.i = start_index + 1;
                        return Token.Pipe;
                    },
                },
                .Percent => switch (c) {
                    '=' => {
                        return Token.PercentEqual;
                    },
                    else => {
                        it.i = start_index + 1;
                        return Token.Percent;
                    },
                },
                .Asterisk => switch (c) {
                    '=' => {
                        return Token.AsteriskEqual;
                    },
                    else => {
                        it.i = start_index + 1;
                        return Token.Asterisk;
                    },
                },
                .Plus => switch (c) {
                    '=' => {
                        return Token.PlusEqual;
                    },
                    else => {
                        it.i = start_index + 1;
                        return Token.Plus;
                    },
                },
                .LArr => switch (c) {
                    '<' => {
                        state = .LArrArr;
                    },
                    '=' => {
                        return Token.LArrEqual;
                    },
                    else => {
                        it.i = start_index + 1;
                        return Token.LArr;
                    },
                },
                .LArrArr => switch (c) {
                    '=' => {
                        return Token.LArrArrEqual;
                    },
                    else => {
                        it.i = start_index + 2;
                        return Token.LArrArr;
                    },
                },
                .RArr => switch (c) {
                    '>' => {
                        state = .RArrArr;
                    },
                    '=' => {
                        return Token.RArrEqual;
                    },
                    else => {
                        it.i = start_index + 1;
                        return Token.RArr;
                    },
                },
                .RArrArr => switch (c) {
                    '=' => {
                        return Token.RArrArrEqual;
                    },
                    else => {
                        it.i = start_index + 2;
                        return Token.RArrArr;
                    },
                },
                .Caret => switch (c) {
                    '=' => {
                        return Token.CaretEqual;
                    },
                    else => {
                        it.i = start_index + 1;
                        return Token.Caret;
                    },
                },
                .Period => switch (c) {
                    '.' => {
                        state = .Period2;
                    },
                    else => {
                        it.i = start_index + 1;
                        return Token.Period;
                    },
                },
                .Period2 => switch (c) {
                    '.' => {
                        return Token.Ellipsis;
                    },
                    else => {
                        try err_stream.print("invalid escape sequence\n", .{});
                        return error.Invalid;
                    },
                },
                .Minus => switch (c) {
                    '=' => {
                        return Token.MinusEqual;
                    },
                    else => {
                        it.i = start_index + 1;
                        return Token.Minus;
                    },
                },
                .Slash => switch (c) {
                    '/' => {
                        state = .SlashSlash;
                    },
                    '=' => {
                        return Token.SlashEqual;
                    },
                    else => {
                        it.i = start_index + 1;
                        return Token.Slash;
                    },
                },
                .SlashSlash => switch (c) {
                    '=' => {
                        return Token.SlashSlashEqual;
                    },
                    else => {
                        it.i = start_index + 2;
                        return Token.SlashSlash;
                    },
                },
                .Ampersand => switch (c) {
                    '=' => {
                        return Token.AmpersandEqual;
                    },
                    else => {
                        it.i = start_index + 1;
                        return Token.Ampersand;
                    },
                },
                .LineComment => switch (c) {
                    '\n', '\r' => {
                        it.i -= 1;
                        state = .Start;
                    },
                    else => {},
                },
                .Zero => switch (c) {
                    'b' => {
                        state = .BinaryNumber;
                    },
                    'o' => {
                        state = .OctalNumber;
                    },
                    'x' => {
                        state = .HexNumber;
                    },
                    '.' => {
                        state = .FloatFraction;
                    },
                    '0'...'9', 'a', 'c'...'f', 'A'...'F' => {
                        try err_stream.print("octal literals start with '0o'\n", .{});
                        return error.Invalid;
                    },
                    '_' => {
                        state = .Number;
                    },
                    else => {
                        it.i -= unicode.utf8CodepointSequenceLength(c) catch unreachable;
                        return Token{ .Number = it.bytes[start_index..it.i] };
                    },
                },
                .BinaryNumber => switch (c) {
                    '0', '1', '_' => {},
                    '2'...'9', 'a'...'f', 'A'...'F' => {
                        try err_stream.print("invalid digit in octal literal\n", .{});
                        return error.Invalid;
                    },
                    '.' => {
                        try err_stream.print("invalid base for floating point number\n", .{});
                        return error.Invalid;
                    },
                    else => {
                        it.i -= unicode.utf8CodepointSequenceLength(c) catch unreachable;
                        return Token{ .Number = it.bytes[start_index..it.i] };
                    },
                },
                .OctalNumber => switch (c) {
                    '0'...'7', '_' => {},
                    '8'...'9', 'a'...'f', 'A'...'F' => {
                        try err_stream.print("invalid digit in octal literal\n", .{});
                        return error.Invalid;
                    },
                    '.' => {
                        try err_stream.print("invalid base for floating point number\n", .{});
                        return error.Invalid;
                    },
                    else => {
                        it.i -= unicode.utf8CodepointSequenceLength(c) catch unreachable;
                        return Token{ .Number = it.bytes[start_index..it.i] };
                    },
                },
                .HexNumber => switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F', '_' => {},
                    '.' => {
                        try err_stream.print("invalid base for floating point number\n", .{});
                        return error.Invalid;
                    },
                    'p', 'P' => {
                        state = .FloatExponent;
                    },
                    else => {
                        it.i -= unicode.utf8CodepointSequenceLength(c) catch unreachable;
                        return Token{ .Number = it.bytes[start_index..it.i] };
                    },
                },
                .Number => switch (c) {
                    '0'...'9', '_' => {},
                    'a'...'d', 'f', 'A'...'F' => {
                        try err_stream.print("invalid digit in octal literal\n", .{});
                        return error.Invalid;
                    },
                    '.' => {
                        state = .FloatFraction;
                    },
                    'e' => {
                        state = .FloatExponent;
                    },
                    else => {
                        it.i -= unicode.utf8CodepointSequenceLength(c) catch unreachable;
                        return Token{ .Number = it.bytes[start_index..it.i] };
                    },
                },
                .FloatFraction => switch (c) {
                    '0'...'9', '_' => {},
                    'e' => {
                        state = .FloatExponent;
                    },
                    else => {
                        it.i -= unicode.utf8CodepointSequenceLength(c) catch unreachable;
                        return Token{ .Number = it.bytes[start_index..it.i] };
                    },
                },
                .FloatExponent => switch (c) {
                    '+', '-' => {
                        state = .FloatExponentDigits;
                    },
                    else => {
                        it.i -= unicode.utf8CodepointSequenceLength(c) catch unreachable;
                        state = .FloatExponentDigits;
                    },
                },
                .FloatExponentDigits => switch (c) {
                    '0'...'9' => {
                        counter += 1;
                    },
                    '_' => {},
                    else => {
                        if (counter == 0) {
                            try err_stream.print("invalid exponent\n", .{});
                            return error.Invalid;
                        }
                        it.i -= unicode.utf8CodepointSequenceLength(c) catch unreachable;
                        return Token{ .Number = it.bytes[start_index..it.i] };
                    },
                },
            }
        } else {
            switch (state) {
                .LineComment, .Start => return Token.Eof,
                .Identifier => {
                    const slice = it.bytes[start_index..];
                    // directly returning causes llvm error
                    const copy = Token.getKeyword(slice) orelse Token{ .Identifier = slice };
                    return copy;
                },

                .Cr,
                .BackSlash,
                .BackSlashCr,
                .Period2,
                .String,
                .EscapeSequence,
                .CrEscape,
                .HexEscape,
                .UnicodeStart,
                .UnicodeEscape,
                .UnicodeEnd,
                .FloatFraction,
                .FloatExponent,
                .FloatExponentDigits,
                .Bang,
                => {
                    try err_stream.print("unexpected eof\n", .{});
                    return error.Invalid;
                },

                .BinaryNumber,
                .OctalNumber,
                .HexNumber,
                .Number,
                .Zero,
                => return Token{ .Number = it.bytes[start_index..] },

                .Equal => return Token.Equal,
                .Minus => return Token.Minus,
                .Slash => return Token.Slash,
                .SlashSlash => return Token.SlashSlash,
                .Ampersand => return Token.Ampersand,
                .Period => return Token.Period,
                .Pipe => return Token.Pipe,
                .RArr => return Token.RArr,
                .RArrArr => return Token.RArrArr,
                .LArr => return Token.LArr,
                .LArrArr => return Token.LArrArr,
                .Plus => return Token.Plus,
                .Percent => return Token.Percent,
                .Caret => return Token.Caret,
                .Asterisk => return Token.Asterisk,
            }
        }
    }
};

fn expectTokens(source: []const u8, expected_tokens: []const Token) !void {
    var it = unicode.Utf8Iterator{
        .i = 0,
        .bytes = source,
    };
    for (expected_tokens) |expected_token_id| {
        const token = try Token.next(&it, std.io.null_out_stream);
        if (!std.meta.eql(token, expected_token_id)) {
            std.debug.panic("expected {}, found {}\n", .{ @tagName(expected_token_id), @tagName(token) });
        }
    }
    const last_token = try Token.next(&it, std.io.null_out_stream);
    std.testing.expect(last_token == .Eof);
}

test "operators" {
    try expectTokens(
        \\ != | |= = ==
        \\ ( ) { } [ ] . ...
        \\ ^ ^= + += - -=
        \\ * *= % %= / /= // //=
        \\ , & &= < <= <<
        \\ <<= > >= >> >>= ~
        \\
    , &[_]Token{
        .BangEqual,
        .Pipe,
        .PipeEqual,
        .Equal,
        .EqualEqual,
        .Nl,
        .LParen,
        .RParen,
        .LBrace,
        .RBrace,
        .LBracket,
        .RBracket,
        .Period,
        .Ellipsis,
        .Nl,
        .Caret,
        .CaretEqual,
        .Plus,
        .PlusEqual,
        .Minus,
        .MinusEqual,
        .Nl,
        .Asterisk,
        .AsteriskEqual,
        .Percent,
        .PercentEqual,
        .Slash,
        .SlashEqual,
        .SlashSlash,
        .SlashSlashEqual,
        .Nl,
        .Comma,
        .Ampersand,
        .AmpersandEqual,
        .LArr,
        .LArrEqual,
        .LArrArr,
        .Nl,
        .LArrArrEqual,
        .RArr,
        .RArrEqual,
        .RArrArr,
        .RArrArrEqual,
        .Tilde,
        .Nl,
    });
}

test "keywords" {
    try expectTokens(
        \\not　and or let continue break return if else false true for while match catch try error import
    , &[_]Token{
        .Keyword_not,
        .Keyword_and,
        .Keyword_or,
        .Keyword_let,
        .Keyword_continue,
        .Keyword_break,
        .Keyword_return,
        .Keyword_if,
        .Keyword_else,
        .Keyword_false,
        .Keyword_true,
        .Keyword_for,
        .Keyword_while,
        .Keyword_match,
        .Keyword_catch,
        .Keyword_try,
        .Keyword_error,
        .Keyword_import,
    });
}
