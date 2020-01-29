const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const Allocator = mem.Allocator;
const TypeId = @import("value.zig").TypeId;
const ast = @import("ast.zig");
const Tree = ast.Tree;
const Node = ast.Node;
const NodeList = ast.NodeList;
const TokenList = ast.TokenList;
const TokenIndex = ast.TokenIndex;

/// root : (stmt NL)* EOF
pub fn parse(tree: *Tree, start_index: usize) ParseError!void {
    var parser = Parser{
        .arena = &tree.arena_allocator.allocator,
        .it = tree.tokens.iterator(start_index),
        .tree = tree,
    };
    while (true) {
        if (parser.eatToken(.Eof, true)) |_| break;
        try tree.nodes.push(try parser.stmt());
        _ = parser.eatToken(.Nl, false) orelse {
            _ = try parser.expectToken(.Eof, true);
            break;
        };
    }
}

pub const ParseError = error{ParseError} || Allocator.Error;

pub const Parser = struct {
    it: TokenList.Iterator,
    tree: *Tree,
    arena: *Allocator,

    /// stmt : let | expr.l
    fn stmt(parser: *Parser) ParseError!*Node {
        if (try parser.let()) |node| return node;
        return parser.expr(false);
    }

    /// let : "let" unwrap "=" expr
    fn let(parser: *Parser) ParseError!?*Node {
        const tok = parser.eatToken(.Keyword_let, false) orelse return null;
        const unwrapped = try parser.unwrap();
        const eq_tok = try parser.expectToken(.Equal, true);
        parser.skipNl();
        const body = try parser.expr(false);
        const node = try parser.arena.create(Node.Let);
        node.* = .{
            .let_tok = tok,
            .unwrap = unwrapped,
            .eq_tok = eq_tok,
            .body = body,
        };
        return &node.base;
    }

    /// unwrap
    ///     : IDENTIFIER
    ///     | "{" ((expr ":")? (unwrap | "_") ",")* ((expr ":")? (unwrap | "_"))?"}"
    ///     | "(" ((unwrap | "_") ",")* (unwrap | "_")? ")"
    ///     | "[" ((unwrap | "_") ",")* (unwrap | "_")? "]"
    ///     | "error" "(" (unwrap | "_") ")"
    fn unwrap(parser: *Parser) ParseError!*Node {
        if (parser.eatToken(.Identifier, true)) |tok| {
            const node = try parser.arena.create(Node.SingleToken);
            node.* = .{
                .base = .{ .id = .Identifier },
                .tok = tok,
            };
            return &node.base;
        }
        const node = try parser.arena.create(Node.Unwrap);
        node.base = .{ .id = .Unwrap };
        if (parser.eatToken(.LBrace, true)) |tok| {
            node.r_tok = tok;
            @panic("TODO");

            // node.l_tok = try parser.expectToken(.RBrace, true);
        } else if (parser.eatToken(.LParen, true)) |tok| {
            node.r_tok = tok;
            node.op.Tuple = NodeList.init(parser.arena);
            node.l_tok = try parser.unwrapList(&node.op.Tuple, .RParen);
        } else if (parser.eatToken(.LBracket, true)) |tok| {
            node.r_tok = tok;
            node.op.List = NodeList.init(parser.arena);
            node.l_tok = try parser.unwrapList(&node.op.List, .RBracket);
        } else if (parser.eatToken(.Keyword_error, true)) |tok| {
            node.r_tok = tok;
            _ = try parser.expectToken(.LParen, true);
            node.op = .{ .Error = try parser.unwrap() };
            node.l_tok = try parser.expectToken(.RParen, true);
        } else return parser.reportErr(.Unwrap, parser.it.peek().?);
        return &node.base;
    }

    fn discard(parser: *Parser) ParseError!?*Node {
        const tok = parser.eatToken(.Underscore, true) orelse return null;
        const node = try parser.arena.create(Node.SingleToken);
        node.* = .{
            .base = .{ .id = .Discard },
            .tok = tok,
        };
        return &node.base;
    }

    /// ((unwrap | "_") ",")* (unwrap | "_")?
    fn unwrapList(parser: *Parser, list: *NodeList, l_tok_id: Token.Id) ParseError!TokenIndex {
        var end = false;
        while (true) {
            if (parser.eatToken(l_tok_id, true)) |tok| {
                return tok;
            } else if (end) {
                return parser.expectToken(l_tok_id, true);
            }
            try list.push(if (try parser.discard()) |node| node else try parser.expr(true));
            if (parser.eatToken(.Comma, true) == null) end = true;
        }
    }

    /// expr
    ///     : fn
    ///     | jump_expr
    ///     | bool_expr assign?
    fn expr(parser: *Parser, skip_nl: bool) ParseError!*Node {
        if (try parser.func(skip_nl)) |node| return node;
        if (try parser.jumpExpr()) |node| return node;
        return parser.assign(try parser.boolExpr(skip_nl), skip_nl);
    }

    /// fn : "fn" "(" (unwrap ",")* unwrap? ")" expr
    fn func(parser: *Parser, skip_nl: bool) ParseError!?*Node {
        const tok = parser.eatToken(.Keyword_fn, skip_nl) orelse return null;
        const node = try parser.arena.create(Node.Fn);
        node.* = .{
            .fn_tok = tok,
            .params = NodeList.init(parser.arena),
            .r_paren = undefined,
            .body = undefined,
        };
        _ = try parser.expectToken(.LParen, true);
        var end = false;
        while (true) {
            if (parser.eatToken(.RParen, true)) |r_tok| {
                node.r_paren = r_tok;
                break;
            } else if (end) {
                node.r_paren = try parser.expectToken(.RParen, true);
                break;
            }
            try node.params.push(try parser.unwrap());
            if (parser.eatToken(.Comma, true) == null) end = true;
        }
        node.r_paren = try parser.expectToken(.RParen, true);
        parser.skipNl();
        node.body = try parser.expr(false);
        return &node.base;
    }

    /// jump_expr : "return" expr? | "break" expr? | "continue"
    fn jumpExpr(parser: *Parser) ParseError!?*Node {
        const tok = parser.eatTokenId(.Keyword_return, false) orelse
            parser.eatTokenId(.Keyword_break, false) orelse
            parser.eatTokenId(.Keyword_continue, false) orelse
            return null;
        const peek = parser.it.peek().?;
        const res = if (tok.id != .Keyword_continue and switch (peek.id) {
            .Nl, .RParen, .RBrace, .RBracket, .Keyword_else, .Comma, .Colon => false,
            else => true,
        })
            try parser.expr(false)
        else
            null;
        const node = try parser.arena.create(Node.Jump);
        node.* = .{
            .tok = tok.index,
            .op = switch (tok.id) {
                .Keyword_return => .{ .Return = res },
                .Keyword_break => .{ .Break = res },
                .Keyword_continue => .Continue,
                else => unreachable,
            },
        };
        return &node.base;
    }

    /// bool_expr
    ///     : "not" comparision_expr
    ///     | comparision_expr ("or" comparision_expr)*
    ///     | comparision_expr ("and" comparision_expr)*
    fn boolExpr(parser: *Parser, skip_nl: bool) ParseError!*Node {
        if (parser.eatToken(.Keyword_not, skip_nl)) |tok| {
            parser.skipNl();
            const node = try parser.arena.create(Node.Prefix);
            node.* = .{
                .op = .BoolNot,
                .rhs = try parser.comparisionExpr(skip_nl),
                .tok = tok,
            };
            return &node.base;
        }
        var lhs = try parser.comparisionExpr(skip_nl);

        // TODO improve
        if (parser.eatToken(.Keyword_or, skip_nl)) |t| {
            var tok = t;
            while (true) {
                parser.skipNl();
                const node = try parser.arena.create(Node.Infix);
                node.* = .{
                    .lhs = lhs,
                    .tok = tok,
                    .op = .BoolOr,
                    .rhs = try parser.comparisionExpr(skip_nl),
                };
                lhs = &node.base;
                if (parser.eatToken(.Keyword_or, skip_nl)) |tt| tok = tt else break;
            }
        } else {
            while (parser.eatToken(.Keyword_and, skip_nl)) |tok| {
                parser.skipNl();
                const node = try parser.arena.create(Node.Infix);
                node.* = .{
                    .lhs = lhs,
                    .tok = tok,
                    .op = .BoolAnd,
                    .rhs = try parser.comparisionExpr(skip_nl),
                };
                lhs = &node.base;
            }
        }
        return lhs;
    }

    /// comparision_expr
    ///     : range_expr (("<" | "<=" | ">" | ">="| "==" | "!=" | "in") range_expr)?
    ///     | range_expr ("is" type_name)?
    fn comparisionExpr(parser: *Parser, skip_nl: bool) ParseError!*Node {
        var lhs = try parser.rangeExpr(skip_nl);

        if (parser.eatTokenId(.LArr, skip_nl) orelse
            parser.eatTokenId(.LArrEqual, skip_nl) orelse
            parser.eatTokenId(.RArr, skip_nl) orelse
            parser.eatTokenId(.RArrEqual, skip_nl) orelse
            parser.eatTokenId(.EqualEqual, skip_nl) orelse
            parser.eatTokenId(.BangEqual, skip_nl) orelse
            parser.eatTokenId(.Keyword_in, skip_nl)) |tok|
        {
            parser.skipNl();
            const node = try parser.arena.create(Node.Infix);
            node.* = .{
                .lhs = lhs,
                .tok = tok.index,
                .op = switch (tok.id) {
                    .LArr => .LessThan,
                    .LArrEqual => .LessThanEqual,
                    .RArr => .GreaterThan,
                    .RArrEqual => .GreaterThanEqual,
                    .EqualEqual => .Equal,
                    .BangEqual => .NotEqual,
                    .Keyword_in => .In,
                    else => unreachable,
                },
                .rhs = try parser.rangeExpr(skip_nl),
            };
            lhs = &node.base;
        } else if (parser.eatToken(.Keyword_is, skip_nl)) |tok| {
            const node = try parser.arena.create(Node.TypeInfix);
            node.* = .{
                .lhs = lhs,
                .tok = tok + 1,
                .op = .Is,
                .type_tok = try parser.typeName(),
            };
            lhs = &node.base;
        }
        return lhs;
    }

    /// type_name : "none" | "int" | "num" | "bool" | "str" | "tuple" | "map" | "list" | "error" | "range" | "fn"
    fn typeName(parser: *Parser) ParseError!TokenIndex {
        return parser.eatToken(.Keyword_error, true) orelse
            parser.eatToken(.Keyword_fn, true) orelse
            parser.eatToken(.Identifier, true) orelse
            parser.reportErr(.TypeName, parser.it.peek().?);
    }

    /// range_expr : bit_expr ("..." bit_expr)?
    fn rangeExpr(parser: *Parser, skip_nl: bool) ParseError!*Node {
        var lhs = try parser.bitExpr(skip_nl);

        if (parser.eatToken(.Ellipsis, skip_nl)) |tok| {
            parser.skipNl();
            const node = try parser.arena.create(Node.Infix);
            node.* = .{
                .lhs = lhs,
                .tok = tok,
                .op = .Range,
                .rhs = try parser.bitExpr(skip_nl),
            };
            lhs = &node.base;
        }
        return lhs;
    }

    /// bit_expr : shift_expr (("&" shift_expr)* | ("|" shift_expr)* | ("|" shift_expr)*) | ("catch" ("let" unwrap ":")? expr)
    fn bitExpr(parser: *Parser, skip_nl: bool) ParseError!*Node {
        var lhs = try parser.shiftExpr(skip_nl);

        // TODO improve
        if (parser.eatToken(.Ampersand, skip_nl)) |t| {
            // &
            var tok = t;
            while (true) {
                parser.skipNl();
                const node = try parser.arena.create(Node.Infix);
                node.* = .{
                    .lhs = lhs,
                    .tok = tok,
                    .op = .BitAnd,
                    .rhs = try parser.shiftExpr(skip_nl),
                };
                lhs = &node.base;
                if (parser.eatToken(.Keyword_or, skip_nl)) |tt| tok = tt else break;
            }
        } else if (parser.eatToken(.Pipe, skip_nl)) |t| {
            // |
            var tok = t;
            while (true) {
                parser.skipNl();
                const node = try parser.arena.create(Node.Infix);
                node.* = .{
                    .lhs = lhs,
                    .tok = tok,
                    .op = .BitOr,
                    .rhs = try parser.shiftExpr(skip_nl),
                };
                lhs = &node.base;
                if (parser.eatToken(.Pipe, skip_nl)) |tt| tok = tt else break;
            }
        } else if (parser.eatToken(.Caret, skip_nl)) |t| {
            // ^
            var tok = t;
            while (true) {
                parser.skipNl();
                const node = try parser.arena.create(Node.Infix);
                node.* = .{
                    .lhs = lhs,
                    .tok = tok,
                    .op = .BitXor,
                    .rhs = try parser.shiftExpr(skip_nl),
                };
                lhs = &node.base;
                if (parser.eatToken(.Caret, skip_nl)) |tt| tok = tt else break;
            }
        } else if (parser.eatToken(.Keyword_catch, skip_nl)) |tok| {
            // catch
            const node = try parser.arena.create(Node.Catch);
            node.* = .{
                .tok = tok,
                .lhs = lhs,
                .unwrap = null,
                .colon = null,
                .rhs = undefined,
            };
            if (parser.eatToken(.Keyword_let, true)) |_| {
                node.unwrap = try parser.unwrap();
                node.colon = try parser.expectToken(.Colon, true);
            }
            parser.skipNl();
            node.rhs = try parser.expr(skip_nl);
            lhs = &node.base;
        }
        return lhs;
    }

    /// shift_expr : add_expr (("<<" | ">>") add_expr)
    fn shiftExpr(parser: *Parser, skip_nl: bool) ParseError!*Node {
        var lhs = try parser.addExpr(skip_nl);

        if (parser.eatTokenId(.LArrArr, skip_nl) orelse
            parser.eatTokenId(.RArrArr, skip_nl)) |tok|
        {
            parser.skipNl();
            const node = try parser.arena.create(Node.Infix);
            node.* = .{
                .lhs = lhs,
                .tok = tok.index,
                .op = if (tok.id == .LArrArr) .LShift else .RShift,
                .rhs = try parser.addExpr(skip_nl),
            };
            lhs = &node.base;
        }
        return lhs;
    }

    /// add_expr : mul_expr (("-" | "+") mul_expr)*
    fn addExpr(parser: *Parser, skip_nl: bool) ParseError!*Node {
        var lhs = try parser.mulExpr(skip_nl);

        while (parser.eatTokenId(.Minus, skip_nl) orelse
            parser.eatTokenId(.Plus, skip_nl)) |tok|
        {
            parser.skipNl();
            const node = try parser.arena.create(Node.Infix);
            node.* = .{
                .lhs = lhs,
                .tok = tok.index,
                .op = if (tok.id == .Minus) .Sub else .Add,
                .rhs = try parser.mulExpr(skip_nl),
            };
            lhs = &node.base;
        }
        return lhs;
    }

    /// mul_expr : cast_expr (("*" | "/" | "//" | "%") cast_expr)*
    fn mulExpr(parser: *Parser, skip_nl: bool) ParseError!*Node {
        var lhs = try parser.castExpr(skip_nl);

        while (parser.eatTokenId(.Asterisk, skip_nl) orelse
            parser.eatTokenId(.Slash, skip_nl) orelse
            parser.eatTokenId(.SlashSlash, skip_nl) orelse
            parser.eatTokenId(.Percent, skip_nl)) |tok|
        {
            parser.skipNl();
            const node = try parser.arena.create(Node.Infix);
            node.* = .{
                .lhs = lhs,
                .tok = tok.index,
                .op = switch (tok.id) {
                    .Asterisk => .Mul,
                    .Slash => .Div,
                    .SlashSlash => .DivFloor,
                    .Percent => .Mod,
                    else => unreachable,
                },
                .rhs = try parser.castExpr(skip_nl),
            };
            lhs = &node.base;
        }

        return lhs;
    }

    /// cast_expr : prefix_expr ("as" type_name)?
    fn castExpr(parser: *Parser, skip_nl: bool) ParseError!*Node {
        var lhs = try parser.prefixExpr(skip_nl);

        if (parser.eatToken(.Keyword_as, skip_nl)) |tok| {
            const node = try parser.arena.create(Node.TypeInfix);
            node.* = .{
                .lhs = lhs,
                .tok = tok + 1,
                .op = .As,
                .type_tok = try parser.typeName(),
            };
            lhs = &node.base;
        }

        return lhs;
    }

    /// power_expr : primary_expr suffix_expr* ("**" power_expr)?
    fn prefixExpr(parser: *Parser, skip_nl: bool) ParseError!*Node {
        if (parser.eatTokenId(.Keyword_try, skip_nl) orelse
            parser.eatTokenId(.Minus, skip_nl) orelse
            parser.eatTokenId(.Plus, skip_nl) orelse
            parser.eatTokenId(.Tilde, skip_nl)) |tok|
        {
            parser.skipNl();
            const node = try parser.arena.create(Node.Prefix);
            node.* = .{
                .op = switch (tok.id) {
                    .Keyword_try => .Try,
                    .Minus => .Minus,
                    .Plus => .Plus,
                    .Tilde => .BitNot,
                    else => unreachable,
                },
                .tok = tok.index,
                .rhs = try parser.powerExpr(skip_nl),
            };
            return &node.base;
        }
        return try parser.powerExpr(skip_nl);
    }

    /// power_expr : primary_expr suffix_expr* ("**" power_expr)?
    fn powerExpr(parser: *Parser, skip_nl: bool) ParseError!*Node {
        var primary = try parser.primaryExpr(skip_nl);
        primary = try parser.suffixExpr(primary, skip_nl);
        if (parser.eatToken(.AsteriskAsterisk, skip_nl)) |tok| {
            parser.skipNl();
            const node = try parser.arena.create(Node.Infix);
            node.* = .{
                .lhs = primary,
                .tok = tok,
                .op = .Pow,
                .rhs = try parser.powerExpr(skip_nl),
            };
            return &node.base;
        }
        return primary;
    }

    /// suffix_expr
    ///     : "[" expr "]"
    ///     | "(" (expr ",")* expr? ")"
    ///     | "." IDENTIFIER
    fn suffixExpr(parser: *Parser, primary: *Node, skip_nl: bool) ParseError!*Node {
        var lhs = primary;
        while (true) {
            if (parser.eatToken(.LBracket, skip_nl)) |tok| {
                parser.skipNl();
                const node = try parser.arena.create(Node.Suffix);
                node.* = .{
                    .lhs = lhs,
                    .l_tok = tok,
                    .op = .{ .ArrAccess = try parser.expr(true) },
                    .r_tok = try parser.expectToken(.RBracket, true),
                };
                lhs = &node.base;
            } else if (parser.eatToken(.LParen, skip_nl)) |tok| {
                parser.skipNl();
                const node = try parser.arena.create(Node.Suffix);
                node.* = .{
                    .lhs = lhs,
                    .l_tok = tok,
                    .op = .{ .Call = NodeList.init(parser.arena) },
                    .r_tok = undefined,
                };
                var end = false;
                while (true) {
                    if (parser.eatToken(.RParen, true)) |r_tok| {
                        node.r_tok = r_tok;
                        break;
                    } else if (end) {
                        node.r_tok = try parser.expectToken(.RParen, true);
                        break;
                    }
                    try node.op.Call.push(try parser.expr(true));
                    if (parser.eatToken(.Comma, true) == null) end = true;
                }
                lhs = &node.base;
            } else if (parser.eatToken(.Period, skip_nl)) |tok| {
                parser.skipNl();
                const node = try parser.arena.create(Node.Suffix);
                node.* = .{
                    .lhs = lhs,
                    .l_tok = tok,
                    .op = .Member,
                    .r_tok = try parser.expectToken(.Identifier, true),
                };
                lhs = &node.base;
            } else {
                return lhs;
            }
        }
    }

    /// assign
    ///     : "=" expr
    ///     | ("+=" | "-=" | "*=" | "**=" | "/=" | "//=" | "%=" | "<<=" | ">>=" | "&=" | "|=" | "^=") bit_expr
    fn assign(parser: *Parser, lhs: *Node, skip_nl: bool) ParseError!*Node {
        // assignment cannot happen in places where NL is not necessary
        if (parser.eatTokenId(.Equal, false) orelse
            parser.eatTokenId(.PlusEqual, false) orelse
            parser.eatTokenId(.MinusEqual, false) orelse
            parser.eatTokenId(.AsteriskEqual, false) orelse
            parser.eatTokenId(.AsteriskAsteriskEqual, false) orelse
            parser.eatTokenId(.SlashEqual, false) orelse
            parser.eatTokenId(.SlashSlashEqual, false) orelse
            parser.eatTokenId(.PercentEqual, false) orelse
            parser.eatTokenId(.LArrArrEqual, false) orelse
            parser.eatTokenId(.RArrArrEqual, false) orelse
            parser.eatTokenId(.AmpersandEqual, false) orelse
            parser.eatTokenId(.PipeEqual, false) orelse
            parser.eatTokenId(.CaretEqual, false)) |tok|
        {
            parser.skipNl();
            const node = try parser.arena.create(Node.Infix);
            node.* = .{
                .lhs = lhs,
                .tok = tok.index,
                .op = switch (tok.id) {
                    .Equal => .Assign,
                    .PlusEqual => .AddAssign,
                    .MinusEqual => .SubAssign,
                    .AsteriskEqual => .MulAssign,
                    .AsteriskAsteriskEqual => .PowAssign,
                    .SlashEqual => .DivAssign,
                    .SlashSlashEqual => .DivFloorAssign,
                    .PercentEqual => .ModAssign,
                    .LArrArrEqual => .LShiftAssign,
                    .RArrArrEqual => .RShfitAssign,
                    .AmpersandEqual => .BitAndAssign,
                    .PipeEqual => .BitOrAssign,
                    .CaretEqual => .BitXOrAssign,
                    else => unreachable,
                },
                .rhs = if (tok.id == .Equal)
                    try parser.expr(skip_nl)
                else
                    try parser.bitExpr(skip_nl),
            };
            return &node.base;
        }

        return lhs;
    }

    /// primary_expr
    ///     : IDENTIFIER
    ///     | STRING
    ///     | NUMBER
    ///     | "true"
    ///     | "false"
    ///     | "(" expr ")"
    ///     | "(" (expr ",")+ expr? ")"
    ///     | "{" (expr ":" expr ",")* (expr ":" expr)? "}"
    ///     | "[" (expr ",")* expr? "]"
    ///     | "error" "(" expr ")"
    ///     | "import" "(" STRING ")"
    ///     | block
    ///     | if
    ///     | while
    ///     | for
    ///     | match
    fn primaryExpr(parser: *Parser, skip_nl: bool) ParseError!*Node {
        if (parser.eatTokenId(.Number, skip_nl) orelse
            parser.eatTokenId(.Integer, skip_nl) orelse
            parser.eatTokenId(.String, skip_nl) orelse
            parser.eatTokenId(.Keyword_true, skip_nl) orelse
            parser.eatTokenId(.Keyword_false, skip_nl)) |tok|
        {
            const node = try parser.arena.create(Node.Literal);
            node.* = .{
                .tok = tok.index,
                .kind = switch (tok.id) {
                    .Number => .Num,
                    .Integer => .Int,
                    .String => .Str,
                    .Keyword_true => .True,
                    .Keyword_false => .False,
                    else => unreachable,
                },
            };
            return &node.base;
        }
        if (parser.eatToken(.Identifier, skip_nl)) |tok| {
            const node = try parser.arena.create(Node.SingleToken);
            node.* = .{
                .base = .{ .id = .Identifier },
                .tok = tok,
            };
            return &node.base;
        }
        if (parser.eatToken(.Keyword_error, skip_nl)) |tok| {
            _ = try parser.expectToken(.LParen, true);
            const node = try parser.arena.create(Node.Error);
            node.* = .{
                .tok = tok,
                .value = try parser.expr(true),
                .r_paren = try parser.expectToken(.RParen, true),
            };
            return &node.base;
        }
        if (parser.eatToken(.Keyword_import, skip_nl)) |tok| {
            _ = try parser.expectToken(.LParen, true);
            const node = try parser.arena.create(Node.Import);
            node.* = .{
                .tok = tok,
                .str_tok = try parser.expectToken(.String, true),
            };
            _ = try parser.expectToken(.RParen, true);
            return &node.base;
        }
        if (parser.eatToken(.LParen, skip_nl)) |tok| {
            if (parser.eatToken(.RParen, true)) |rparen| {
                const node = try parser.arena.create(Node.Literal);
                node.* = .{
                    .tok = rparen,
                    .kind = .None,
                };
                return &node.base;
            } else {
                const first = try parser.expr(true);
                if (parser.eatToken(.RParen, true)) |r_tok| {
                    const node = try parser.arena.create(Node.Grouped);
                    node.* = .{
                        .l_tok = tok,
                        .expr = first,
                        .r_tok = r_tok,
                    };
                    return &node.base;
                }
                const node = try parser.arena.create(Node.ListTupleMapBlock);
                node.* = .{
                    .base = .{ .id = .Tuple },
                    .l_tok = tok,
                    .values = NodeList.init(parser.arena),
                    .r_tok = undefined,
                };
                try node.values.push(first);
                _ = try parser.expectToken(.Comma, true);
                var end = false;
                while (true) {
                    if (parser.eatToken(.RParen, true)) |r_tok| {
                        node.r_tok = r_tok;
                        return &node.base;
                    } else if (end) {
                        node.r_tok = try parser.expectToken(.RBrace, true);
                        break;
                    }
                    try node.values.push(try parser.expr(true));
                    if (parser.eatToken(.Comma, true) == null) end = true;
                }
            }
        }
        if (parser.eatToken(.LBrace, skip_nl)) |tok| {
            if (parser.eatToken(.Nl, false)) |_| {
                // block
                return try parser.block(tok);
            } else {
                // map
                const node = try parser.arena.create(Node.ListTupleMapBlock);
                node.* = .{
                    .base = .{ .id = .Map },
                    .l_tok = tok,
                    .values = NodeList.init(parser.arena),
                    .r_tok = undefined,
                };
                var end = false;
                while (true) {
                    if (parser.eatToken(.RBrace, true)) |r_tok| {
                        node.r_tok = r_tok;
                        break;
                    } else if (end) {
                        node.r_tok = try parser.expectToken(.RBrace, true);
                        break;
                    }
                    var key: ?*Node = null;
                    var value = try parser.expr(true);
                    var colon: ?TokenIndex = null;
                    if (parser.eatToken(.Colon, true)) |col| {
                        colon = col;
                        key = value;
                        value = try parser.expr(true);
                    }
                    const item = try parser.arena.create(Node.MapItem);
                    item.* = .{
                        .key = key,
                        .colon = colon,
                        .value = value,
                    };
                    try node.values.push(&item.base);
                    if (parser.eatToken(.Comma, true) == null) end = true;
                }
            }
        }
        if (parser.eatToken(.LBracket, skip_nl)) |tok| {
            // list
            parser.skipNl();
            const node = try parser.arena.create(Node.ListTupleMapBlock);
            node.* = .{
                .base = .{ .id = .List },
                .l_tok = tok,
                .values = NodeList.init(parser.arena),
                .r_tok = undefined,
            };
            var end = false;
            while (true) {
                if (parser.eatToken(.RBracket, true)) |r_tok| {
                    node.r_tok = r_tok;
                    break;
                } else if (end) {
                    node.r_tok = try parser.expectToken(.RBracket, true);
                    break;
                }
                try node.values.push(try parser.expr(true));
                if (parser.eatToken(.Comma, true) == null) end = true;
            }
            return &node.base;
        }
        if (try parser.ifExpr(skip_nl)) |res| return res;
        if (try parser.whileExpr(skip_nl)) |res| return res;
        if (try parser.forExpr(skip_nl)) |res| return res;
        if (try parser.matchExpr(skip_nl)) |res| return res;
        return parser.reportErr(.PrimaryExpr, parser.it.peek().?);
    }

    /// block : "{" (NL stmt)+ "}"
    fn block(parser: *Parser, l_tok: TokenIndex) ParseError!*Node {
        const node = try parser.arena.create(Node.ListTupleMapBlock);
        node.* = .{
            .base = .{ .id = .Block },
            .values = NodeList.init(parser.arena),
            .l_tok = l_tok,
            .r_tok = undefined,
        };
        while (true) {
            try node.values.push(try parser.stmt());
            _ = try parser.expectToken(.Nl, false);
            if (parser.eatToken(.RBrace, true)) |tok| {
                node.r_tok = tok;
                return &node.base;
            }
        }
    }

    /// if : "if" "(" ("let" unwrap "=") bool_expr ")" expr ("else" expr)?
    fn ifExpr(parser: *Parser, skip_nl: bool) ParseError!?*Node {
        const tok = parser.eatToken(.Keyword_if, skip_nl) orelse return null;
        _ = try parser.expectToken(.LParen, true);
        const unwrapped = if (parser.eatToken(.Keyword_let, true)) |_|
            try parser.unwrap()
        else
            null;
        const node = try parser.arena.create(Node.If);
        node.* = .{
            .if_tok = tok,
            .unwrap = unwrapped,
            .eq_tok = if (unwrapped != null) try parser.expectToken(.Equal, true) else null,
            .cond = try parser.boolExpr(true),
            .r_paren = try parser.expectToken(.RParen, true),
            .if_body = try parser.expr(skip_nl),
            .else_tok = parser.eatToken(.Keyword_else, skip_nl),
            .else_body = null,
        };
        if (node.else_tok != null) {
            node.else_body = try parser.expr(skip_nl);
        }
        return &node.base;
    }

    /// while : "while" "(" ("let" unwrap "=") bool_expr ")" expr
    fn whileExpr(parser: *Parser, skip_nl: bool) ParseError!?*Node {
        const tok = parser.eatToken(.Keyword_while, skip_nl) orelse return null;
        _ = try parser.expectToken(.LParen, true);
        const unwrapped = if (parser.eatToken(.Keyword_let, true)) |_|
            try parser.unwrap()
        else
            null;
        const node = try parser.arena.create(Node.While);
        node.* = .{
            .while_tok = tok,
            .unwrap = unwrapped,
            .eq_tok = if (unwrapped != null) try parser.expectToken(.Equal, true) else null,
            .cond = try parser.boolExpr(true),
            .r_paren = try parser.expectToken(.RParen, true),
            .body = try parser.expr(skip_nl),
        };
        return &node.base;
    }

    /// for : "for" "(" ("let" unwrap "in") range_expr ")" expr
    fn forExpr(parser: *Parser, skip_nl: bool) ParseError!?*Node {
        const tok = parser.eatToken(.Keyword_for, skip_nl) orelse return null;
        _ = try parser.expectToken(.LParen, true);
        const unwrapped = if (parser.eatToken(.Keyword_let, true)) |_|
            try parser.unwrap()
        else
            null;
        const node = try parser.arena.create(Node.For);
        node.* = .{
            .for_tok = tok,
            .unwrap = unwrapped,
            .in_tok = if (unwrapped != null) try parser.expectToken(.Keyword_in, true) else null,
            .cond = try parser.rangeExpr(true),
            .r_paren = try parser.expectToken(.RParen, true),
            .body = try parser.expr(skip_nl),
        };
        return &node.base;
    }

    /// match : "match" "(" bool_expr ")" "{" (NL match_case)+ NL "}"
    fn matchExpr(parser: *Parser, skip_nl: bool) ParseError!?*Node {
        const tok = parser.eatToken(.Keyword_match, skip_nl) orelse return null;
        _ = try parser.expectToken(.LParen, true);
        const node = try parser.arena.create(Node.Match);
        node.* = .{
            .match_tok = tok,
            .expr = try parser.boolExpr(true),
            .r_paren = try parser.expectToken(.RParen, true),
            .body = NodeList.init(parser.arena),
            .body_r_brace = undefined,
        };
        _ = try parser.expectToken(.LBrace, true);
        _ = try parser.expectToken(.Nl, false);
        while (true) {
            try node.body.push(try parser.matchCase());
            _ = try parser.expectToken(.Nl, false);
            if (parser.eatToken(.RBrace, true)) |r_tok| {
                node.body_r_brace = r_tok;
                break;
            }
        }
        return &node.base;
    }

    /// match_case
    ///     : "let" unwrap ":" expr
    ///     | "_" ":" expr
    ///     | expr ("," expr)* ","? ":" expr
    fn matchCase(parser: *Parser) ParseError!*Node {
        if (parser.eatToken(.Underscore, false)) |tok| {
            return parser.finishCatchAll(tok);
        } else if (parser.eatToken(.Keyword_let, false)) |_| {
            if (parser.eatToken(.Identifier, true)) |tok| {
                return parser.finishCatchAll(tok);
            }
            const unwrapped = try parser.unwrap();
            std.debug.assert(unwrapped.id == .Unwrap);
            _ = try parser.expectToken(.Colon, true);
            const node = try parser.arena.create(Node.MatchLet);
            node.* = .{
                .unwrap = @fieldParentPtr(Node.Unwrap, "base", unwrapped),
                .expr = try parser.expr(false),
            };
            return &node.base;
        } else {
            const node = try parser.arena.create(Node.MatchCase);
            node.* = .{
                .lhs = NodeList.init(parser.arena),
                .colon = undefined,
                .expr = undefined,
            };
            while (true) {
                try node.lhs.push(try parser.expr(true));
                if (parser.eatToken(.Comma, true) == null) break;
            }
            node.colon = try parser.expectToken(.Colon, true);
            node.expr = try parser.expr(false);
            return &node.base;
        }
    }

    fn finishCatchAll(parser: *Parser, tok: TokenIndex) ParseError!*Node {
        _ = try parser.expectToken(.Colon, true);
        const node = try parser.arena.create(Node.MatchCatchAll);
        node.* = .{
            .tok = tok,
            .expr = try parser.expr(false),
        };
        return &node.base;
    }

    fn reportErr(parser: *Parser, kind: ast.ErrorMsg.Kind, tok: *Token) ParseError {
        try parser.tree.errors.push(.{
            .kind = kind,
            .index = tok.start,
        });
        return error.ParseError;
    }

    fn skipNl(parser: *Parser) void {
        _ = parser.eatToken(.Nl, true);
    }

    const TokAndId = struct {
        index: TokenIndex,
        id: Token.Id,
        tok: *Token,
    };

    fn eatTokenId(parser: *Parser, id: Token.Id, skip_nl: bool) ?TokAndId {
        var next_tok = parser.it.next().?;
        while (next_tok.id == .Comment)
            next_tok = parser.it.next().?;
        if (skip_nl and next_tok.id == .Nl)
            next_tok = parser.it.next().?;
        if (next_tok.id == id) {
            return TokAndId{
                .index = @intCast(TokenIndex, parser.it.index - 1),
                .id = id,
                .tok = next_tok,
            };
        } else {
            _ = parser.it.prev();
            return null;
        }
    }

    fn eatToken(parser: *Parser, id: Token.Id, skip_nl: bool) ?TokenIndex {
        const wrapped = parser.eatTokenId(id, skip_nl) orelse return null;
        return wrapped.index;
    }

    fn expectToken(parser: *Parser, id: Token.Id, skip_nl: bool) !TokenIndex {
        if (parser.eatToken(id, skip_nl)) |tok| return tok;
        return parser.reportErr(.UnexpectedToken, parser.it.peek().?);
    }
};
