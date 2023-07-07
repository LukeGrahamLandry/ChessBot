const std = @import("std");
const assert = std.debug.assert;

pub const Kind = enum(u4) { Empty = 0, Pawn, Bishop, Knight, Rook, Queen, King };
pub const Colour = enum(u2) { Empty = 0, Black, White };

pub const Piece = packed struct { 
    colour: Colour, 
    kind: Kind,

    pub fn fromFEN(letter: u8) InvalidFenErr!Piece {
        return .{ 
            .colour = if (std.ascii.isUpper(letter)) Colour.White else Colour.Black, 
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

pub const Board = struct {
    squares: [64] Piece = std.mem.zeroes([64] Piece),

    pub fn set(self: *Board, file: u8, rank: u8, value: Piece) void {
        self.squares[file*8 + rank] = value;
    }

    pub fn get(self: *const Board, file: usize, rank: usize) Piece {
        return self.squares[file*8 + rank];
    }

    pub fn initial() Board {
        return comptime try fromFEN(INIT_FEN);
    }

    pub fn fromFEN(fen: [] const u8) InvalidFenErr!Board {
        var self = Board {};
        var file: u8 = 0;
        var rank: u8 = 0;
        for (fen) |letter| {
            if (std.ascii.isDigit(letter)) {
                const count = letter - ASCII_ZERO_CHAR;
                file += count;
            } else if (letter == '/') {
                file = 0;
                rank += 1;
            } else {
                self.set(file, rank, try Piece.fromFEN(letter));
                file += 1;
            }
        }
        
        return self;
    }

    pub fn toFEN(self: *const Board, allocator: std.mem.Allocator) std.mem.Allocator.Error![] u8 {
        var letters = try std.ArrayList(u8).initCapacity(allocator, 64);
        
        for (0..8) |rank| {
            var empty: u8 = 0;
            for (0..8) |file| {
                const p = self.get(file, rank);
                if (p.empty()) {
                    empty += 1;
                } else {
                    if (empty > 0) {
                        assert(empty <= 8);
                        letters.appendAssumeCapacity(empty + ASCII_ZERO_CHAR);
                        empty = 0;
                        continue;
                    }
                    const letter = @as(u8, switch (p.kind) {
                        .Pawn => 'P',
                        .Bishop => 'B',
                        .Knight => 'N',
                        .Rook => 'R',
                        .King => 'K',
                        .Queen => 'Q',
                        else => unreachable,
                    });
                    switch (p.colour) {
                        .White => {
                            letters.appendAssumeCapacity(letter);
                        },
                        .Black => {
                            letters.appendAssumeCapacity(std.ascii.toLower(letter));
                        },
                        .Empty => unreachable,
                    }
                }
            }
            if (empty > 0) {
                assert(empty <= 8);
                letters.appendAssumeCapacity(empty + ASCII_ZERO_CHAR);
            }
            if (rank < 7){
                letters.appendAssumeCapacity('/');
            }
            
        }
        return try letters.toOwnedSlice();
    }
};



var tstAlloc = std.testing.allocator;

test "write fen" {
    const b = Board.initial();
    const fen = try b.toFEN(tstAlloc);
    defer tstAlloc.free(fen);
    try std.testing.expect(std.mem.eql(u8, fen, INIT_FEN));
}
