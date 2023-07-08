const std = @import("std");
const assert = std.debug.assert;
const Move = @import("moves.zig").Move;

// I don't care about the numbers but I like that a zeroed out piece is empty. 
pub const Kind = enum(u4) { Empty = 0, Pawn, Bishop, Knight, Rook, Queen, King };
// TODO: this could be one bit, the empty state is redundant. Is it helpful or does Piece need to be byte aligned in arrays anyway? 
pub const Colour = enum(u2) { 
    Empty = 0, Black, White, 

    pub fn other(self: Colour) Colour {
        return switch (self) {
            .White => .Black,
            .Black => .White,
            .Empty => unreachable,  // Must revisit all usages of this function if I make empty not a colour!
        };
    } 
};

pub const Piece = packed struct { 
    colour: Colour, 
    kind: Kind,

    pub fn fromChar(letter: u8) InvalidFenErr!Piece {
        return .{ 
            .colour = if (std.ascii.isUpper(letter)) Colour.White else Colour.Black, 
            // This cast is stupid. https://github.com/ziglang/zig/issues/13353
            .kind = @as(Kind, switch (std.ascii.toUpper(letter)) {
                'P' => .Pawn,
                'B' => .Bishop,
                'N' => .Knight,
                'R' => .Rook,
                'Q' => .Queen,
                'K' => .King,
                else => return error.InvalidFen,
            })
        };
    }

    pub fn toChar(self: Piece) u8 {
        const letter = @as(u8, switch (self.kind) {
            .Pawn => 'P',
            .Bishop => 'B',
            .Knight => 'N',
            .Rook => 'R',
            .King => 'K',
            .Queen => 'Q',
            .Empty => return ' ',
        });
        return switch (self.colour) {
            .White => letter,
            .Black => std.ascii.toLower(letter),
            .Empty => unreachable,
        };
    }

    pub fn empty(self: Piece) bool {
        return self.kind == .Empty;
    }
};

comptime {
    assert(@sizeOf(Piece) == 1);
}

const ASCII_ZERO_CHAR: u8 = 48;
pub const INIT_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR";
const InvalidFenErr = error { InvalidFen };

// TODO: flag for castling rights. Track en passant target squares. Count moves for draw. 
pub const Board = struct {
    squares: [64] Piece = std.mem.zeroes([64] Piece),

    pub fn set(self: *Board, file: u8, rank: u8, value: Piece) void {
        self.squares[rank*8 + file] = value;
    }

    pub fn get(self: *const Board, file: usize, rank: usize) Piece {
        return self.squares[rank*8 + file];
    }

    pub fn initial() Board {
        // This is kinda cool. It's a compile error if this fails to parse, so this function doesn't return an error union.
        return comptime try fromFEN(INIT_FEN);
    }

    pub fn play(self: *Board, move: Move) void {
        switch (move.target) {
            .to => |to| {
                self.squares[to] = self.squares[move.from];
                self.squares[move.from] = .{ .colour = .Empty, .kind = .Empty };
            },
            .promote => |kind| {
                const c = self.squares[move.from].colour;
                const file = move.from % 8;
                const rank: u8 = switch (c) {
                    .Black => 0,
                    .White => 7,
                    .Empty => unreachable,
                };
                self.set(file, rank, .{ .colour = c, .kind = kind });
                self.squares[move.from] = .{ .colour = .Empty, .kind = .Empty };
            }
        }
        
    }

    // TODO: this rejects the extra data at the end because I can't store it yet. 
    pub fn fromFEN(fen: [] const u8) InvalidFenErr!Board {
        var self = Board {};
        var file: u8 = 0;
        var rank: u8 = 7;
        for (fen) |letter| {
            if (std.ascii.isDigit(letter)) {
                const count = letter - ASCII_ZERO_CHAR;
                file += count;
            } else if (letter == '/') {
                if (file != 8) return error.InvalidFen;
                file = 0;
                if (rank == 0) return error.InvalidFen;  // This assumes no trailing '/'
                rank -= 1;
            } else {
                self.set(file, rank, try Piece.fromChar(letter));
                file += 1;
                if (rank > 8) return error.InvalidFen;
            }
        }
        
        if (file != 8) return error.InvalidFen;
        
        return self;
    }

    // Caller owns the returned string. 
    pub fn toFEN(self: *const Board, allocator: std.mem.Allocator) std.mem.Allocator.Error![] u8 {
        // This capacity gives space for a letter for each square and a slash after each row,
        // which is more than it can ever require, so using appendAssumeCapacity below is safe. 
        var letters = try std.ArrayList(u8).initCapacity(allocator, 64 + 8);
        errdefer letters.deinit();
        
        for (0..8) |rank| {
            var empty: u8 = 0;
            for (0..8) |file| {
                const p = self.get(file, 7-rank);
                if (p.empty()) {
                    empty += 1;
                    continue;
                } 
                if (empty > 0) {
                    letters.appendAssumeCapacity(empty + ASCII_ZERO_CHAR);
                    empty = 0;
                }
                letters.appendAssumeCapacity(p.toChar());
            }
            if (empty > 0) {
                letters.appendAssumeCapacity(empty + ASCII_ZERO_CHAR);
            }
            if (rank < 7){
                letters.appendAssumeCapacity('/');
            }
        }
        return try letters.toOwnedSlice();
    }

    // Caller owns the returned string. 
    pub fn displayString(self: *const Board, allocator: std.mem.Allocator) std.mem.Allocator.Error![] u8 {
        // Pre-allocate enough space for the string so appendAssumeCapacity is safe to use. 
        // 64 squares, a pipe before every square, a pipe before each line, and 8 line breaks. 
        var letters = try std.ArrayList(u8).initCapacity(allocator, 64*2 + 8 + 8);
        
        for (0..8) |rank| {
            letters.appendAssumeCapacity('|');
            for (0..8) |file| {
                letters.appendAssumeCapacity(self.get(file, 7 - rank).toChar());
                letters.appendAssumeCapacity('|');
            }
            letters.appendAssumeCapacity('\n');
        }

        // Since we're returning everything we allocated, don't need to deinit the list. 
        // Using toOwnedSlice would be fine but it offends me that it's technically allowed to reallocate. 
        assert(letters.items.len == letters.capacity);
        return letters.allocatedSlice();
    }
};

var tstAlloc = std.testing.allocator;

test "write fen" {
    const b = Board.initial();
    const fen = try b.toFEN(tstAlloc);
    defer tstAlloc.free(fen);
    try std.testing.expect(std.mem.eql(u8, fen, INIT_FEN));
}
