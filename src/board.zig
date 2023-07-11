const std = @import("std");
const assert = std.debug.assert;
const Move = @import("moves.zig").Move;

// Numbers matter because js sees them. 
pub const Kind = enum(u4) { 
    Empty = 0, Pawn = 1, Bishop = 2, Knight = 3, Rook = 4, Queen = 5, King = 6, 

    pub fn material(self: Kind) i32 {
        return switch (self) {
            .Pawn => 100,
            .Bishop => 300,
            .Knight => 300,
            .Rook => 500,
            .King => 100000,
            .Queen => 900,
            .Empty => 0,
        };
    }
};

// TODO: this could be one bit, the empty state is redundant. Is it helpful or does Piece need to be byte aligned in arrays anyway? 
pub const Colour = enum(u2) { 
    Empty = 0, Black = 1, White = 2, 

    pub fn other(self: Colour) Colour {
        return switch (self) {
            .White => .Black,
            .Black => .White,
            .Empty => unreachable,  // Must revisit all usages of this function if I make empty not a colour!
        };
    } 
};

// This is packed with explicit padding so I can cast boards to byte arrays and pass to js. 
pub const Piece = packed struct { 
    colour: Colour, 
    kind: Kind,
    _pad: u2 = 0,

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

    pub fn toUnicode(self: Piece) u21 {
        const letter = @as(u21, switch (self.kind) {
            .Pawn => '♙',
            .Bishop => '♗',
            .Knight => '♘',
            .Rook => '♖',
            .King => '♔',
            .Queen => '♕',
            .Empty => return ' ',
        });
        return switch (self.colour) {
            .White => letter,
            .Black => letter + 6,
            .Empty => unreachable,
        };
    }

    pub fn empty(self: Piece) bool {
        return self.kind == .Empty;
    }
};

const ASCII_ZERO_CHAR: u8 = 48;
pub const INIT_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR";
const InvalidFenErr = error { InvalidFen };

const OldMove = struct {
    move: Move,
    taken: Piece,
    original: Piece,
};

// TODO: flag for castling rights. Track en passant target squares. Count moves for draw. 
pub const Board = struct {
    squares: [64] Piece = std.mem.zeroes([64] Piece),
    // Just these being here makes it slower
    whitePeicePositions: u64 = 0,
    blackPeicePositions: u64 = 0,

    pub fn set(self: *Board, file: u8, rank: u8, value: Piece) void {
        const index: u64 = @intCast(rank*8 + file);
        self.setBit(index, value.colour);
        self.squares[index] = value;
    }

    pub fn get(self: *const Board, file: usize, rank: usize) Piece {
        return self.squares[rank*8 + file];
    }

    pub fn initial() Board {
        // This is kinda cool. It's a compile error if this fails to parse, so this function doesn't return an error union.
        return comptime try fromFEN(INIT_FEN);
    }

    const one: u64 = 1;
    pub fn setBit(self: *Board, index: u6, colour: Colour) void {
        switch (colour) {
            .White => self.whitePeicePositions |= (one << index),
            .Black => self.blackPeicePositions |= (one << index),
            .Empty => {},
        }
    }

    pub fn unsetBit(self: *Board, index: u6, colour: Colour) void {
        switch (colour) {
            .White => self.whitePeicePositions ^= (one << index),
            .Black => self.blackPeicePositions ^= (one << index),
            .Empty => {},
        }
    }

    pub fn emptyAt(self: *const Board, file: usize, rank: usize) bool {
        const index: u6 = @intCast(rank*8 + file);
        const flag = one << index;
        const isEmpty = ((self.whitePeicePositions & flag) | (self.blackPeicePositions & flag)) == 0;   
        if (isEmpty) assert(self.get(file, rank).empty());
        return isEmpty;
    }

    pub fn play(self: *Board, move: Move) OldMove {
        const thisMove: OldMove = .{ .move = move, .taken = self.squares[move.to], .original = self.squares[move.from]};
        self.unsetBit(move.from, thisMove.original.colour);
        self.unsetBit(move.to, thisMove.taken.colour);
        self.setBit(move.to, thisMove.original.colour);
        
        switch (move.action) {
            .none => {
                self.squares[move.to] = thisMove.original;
                self.squares[move.from] = .{ .colour = .Empty, .kind = .Empty };
            },
            .promote => |kind| {
                self.squares[move.to] = .{ .colour = thisMove.original.colour, .kind = kind };
                self.squares[move.from] = .{ .colour = .Empty, .kind = .Empty };
            }
        }
        return thisMove;
    }

    // Thought this would be faster because less copying but almost no difference. 
    pub fn unplay(self: *Board, move: OldMove) void {
        self.squares[move.move.to] = move.taken;
        self.squares[move.move.from] = move.original;
        
        self.setBit(move.move.from, move.original.colour);
        self.setBit(move.move.to, move.taken.colour);
        self.unsetBit(move.move.to, move.original.colour);
    }

    pub fn copyPlay(self: *const Board, move: Move) Board {
        var board = self.*;
        _ = board.play(move);
        return board;
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
    pub fn displayString(self: *const Board, allocator: std.mem.Allocator) ![] u8 {
        // Pre-allocate enough space for the string so appendAssumeCapacity is safe to use. 
        // 64 squares, a pipe before every square, a pipe before each line, and 8 line breaks. 
        var letters = try std.ArrayList(u8).initCapacity(allocator, (64*3) + 64 + 8 + 8);
        
        for (0..8) |rank| {
            letters.appendAssumeCapacity('|');
            for (0..8) |file| {
                const char = self.get(file, 7 - rank).toUnicode();
                const remaining = letters.allocatedSlice()[letters.items.len..letters.capacity];
                const count = try std.unicode.utf8Encode(char, remaining);
                letters.items.len += count;
                letters.appendAssumeCapacity('|');
            }
            letters.appendAssumeCapacity('\n');
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
