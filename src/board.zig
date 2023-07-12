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

pub const Colour = enum(u1) { 
    White = 0, Black = 1, 

    pub fn other(self: Colour) Colour {
        return @enumFromInt(~@intFromEnum(self));
    }
};

// This is packed with explicit padding so I can cast boards to byte arrays and pass to js. 
pub const Piece = packed struct { 
    colour: Colour, 
    kind: Kind,
    _pad: u3 = 0,

    pub fn eval(self: Piece) i32 {
        return switch (self.colour) {
            .White => self.kind.material(),
            .Black => -self.kind.material(),
        };
    }

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
            .Black => letter + 6
        };
    }

    pub fn empty(self: Piece) bool {
        return self.kind == .Empty;
    }
};

const ASCII_ZERO_CHAR: u8 = 48;
pub const INIT_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR";
const InvalidFenErr = error { InvalidFen };

const BitBoardPair = packed struct {
    white: u64 = 0,
    black: u64 = 0,

    const one: u64 = 1;

    pub fn setBit(self: *BitBoardPair, index: u6, colour: Colour) void {
        switch (colour) {
            .White => self.white |= (one << index),
            .Black => self.black |= (one << index),
        }
    }

    pub fn unsetBit(self: *BitBoardPair, index: u6, colour: Colour) void {
        switch (colour) {
            .White => self.white ^= (one << index),
            .Black => self.black ^= (one << index),
        }
    }

    pub fn getFlag(self: *BitBoardPair, colour: Colour) u64 {
        return switch (colour) {
            .White => self.white,
            .Black => self.black
        };
    }
};

const OldMove = struct {
    move: Move,
    taken: Piece,
    original: Piece,
};

const BoardState = struct {
    targetedPositions: BitBoardPair = .{},
};

// TODO: flag for castling rights. Track en passant target squares. Count moves for draw. 
pub const Board = struct {
    squares: [64] Piece = std.mem.zeroes([64] Piece),
    peicePositions: BitBoardPair = .{},
    simpleEval: i32 = 0,
    blackKingIndex: u6 = 0,
    whiteKingIndex: u6 = 0,

    pub fn init(alloc: std.mem.Allocator) !Board {
        _ = alloc;
        var self: Board = .{ };
        return self;
    }

    pub fn deinit(self: *Board) void {
        _ = self;
    }

    pub fn set(self: *Board, file: u8, rank: u8, value: Piece) void {
        assert(self.emptyAt(file, rank));
        const index: u6 = @intCast(rank*8 + file);
        self.peicePositions.setBit(index, value.colour);
        self.simpleEval -= self.squares[index].eval();
        self.squares[index] = value;
        self.simpleEval += value.eval();
        if (value.kind == .King) switch (value.colour) {
            .White => self.whiteKingIndex = index,
            .Black => self.blackKingIndex = index, 
        };
    }

    pub fn get(self: *const Board, file: usize, rank: usize) Piece {
        return self.squares[rank*8 + file];
    }

    pub fn initial(alloc: std.mem.Allocator) Board {
        // TODO: I want this to be comptime but it needs an allocator
        return fromFEN(INIT_FEN, alloc) catch @panic("INIT_FEN is invalid.");
    }

    const one: u64 = 1;
    pub fn emptyAt(self: *const Board, file: usize, rank: usize) bool {
        const index: u6 = @intCast(rank*8 + file);
        const flag = one << index;
        const isEmpty = ((self.peicePositions.white & flag) | (self.peicePositions.black & flag)) == 0;   
        // assert(self.get(file, rank).empty() == isEmpty);
        return isEmpty;
    }

    const genAnyMove = @import("movegen.zig").MoveFilter.Any.get();
    pub fn play(self: *Board, move: Move) !OldMove {
        const thisMove: OldMove = .{ .move = move, .taken = self.squares[move.to], .original = self.squares[move.from]};
        self.simpleEval -= thisMove.taken.eval();
        
        self.peicePositions.unsetBit(move.from, thisMove.original.colour);
        if (!thisMove.taken.empty()) self.peicePositions.unsetBit(move.to, thisMove.taken.colour);
        self.peicePositions.setBit(move.to, thisMove.original.colour);
        if (thisMove.original.kind == .King) {
            switch (thisMove.original.colour) {
                .Black => self.blackKingIndex = move.to,
                .White => self.whiteKingIndex = move.to,
            }
        }
        
        switch (move.action) {
            .none => {
                self.squares[move.to] = thisMove.original;
                self.squares[move.from] = .{ .colour = undefined, .kind = .Empty };
            },
            .promote => |kind| {
                self.simpleEval -= thisMove.original.eval();
                self.squares[move.to] = .{ .colour = thisMove.original.colour, .kind = kind };
                self.simpleEval += self.squares[move.to].eval();
                self.squares[move.from] = .{ .colour = undefined, .kind = .Empty };
            }
        }

        return thisMove;
    }

    // Thought this would be faster because less copying but almost no difference. 
    pub fn unplay(self: *Board, move: OldMove) void {
        self.simpleEval += move.taken.eval();
        switch (move.move.action) {
            .none => {},
            .promote => |_| {
                self.simpleEval -= self.squares[move.move.to].eval();
                self.simpleEval += move.original.eval();
            }
        }
        
        self.squares[move.move.to] = move.taken;
        self.squares[move.move.from] = move.original;

        self.peicePositions.setBit(move.move.from, move.original.colour);
        if (!move.taken.empty()) self.peicePositions.setBit(move.move.to, move.taken.colour);
        self.peicePositions.unsetBit(move.move.to, move.original.colour);
        if (move.original.kind == .King) {
            switch (move.original.colour) {
                .Black => self.blackKingIndex = move.move.from,
                .White => self.whiteKingIndex = move.move.from,
            }
        }
    }

    // TODO: !!! this will break everything because aliased arraylist
    pub fn copyPlay(self: *const Board, move: Move) Board {
        _ = move;
        _ = self;
        @panic("TODO");
        // var board = self.*;
        // _ = board.play(move);
        // return board;
    }

    // TODO: this rejects the extra data at the end because I can't store it yet. 
    pub fn fromFEN(fen: [] const u8, alloc: std.mem.Allocator) !Board {
        var self = try Board.init(alloc);
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
    var b = Board.initial(tstAlloc);
    defer b.deinit();
    const fen = try b.toFEN(tstAlloc);
    defer tstAlloc.free(fen);
    try std.testing.expect(std.mem.eql(u8, fen, INIT_FEN));
}
