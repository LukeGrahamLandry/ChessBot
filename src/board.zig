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

    pub fn is(self: Piece, colour: Colour, kind: Kind) bool {
        return self.kind == kind and self.colour == colour;
    }
};

const ASCII_ZERO_CHAR: u8 = 48;
pub const INIT_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w";
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

    pub fn getFlag(self: *const BitBoardPair, colour: Colour) u64 {
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
    old_castling: CastlingRights,
    // TODO: remove
    debugPeicePositions: BitBoardPair,
    debugSimpleEval: i32
};

// Index with colour ordinal
const CastlingRights = struct { 
    right: [2] bool = .{true, true},
    left: [2] bool = .{true, true},
};

// TODO: Track en passant target squares. Count moves for draw. 
pub const Board = struct {
    squares: [64] Piece = std.mem.zeroes([64] Piece),
    peicePositions: BitBoardPair = .{},
    // TODO: make sure these are packed nicely
    simpleEval: i32 = 0,  // TODO: a test that recalculates
    blackKingIndex: u6 = 0,
    whiteKingIndex: u6 = 0,
    nextPlayer: Colour = .White,
    castling: CastlingRights = .{},

    pub fn blank() Board {
        return .{};
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

    pub fn initial() Board {
        return comptime try fromFEN(INIT_FEN);
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
        assert(self.hasCorrectPositionsBits());
        const thisMove: OldMove = .{ .move = move, .taken = self.squares[move.to], .original = self.squares[move.from], .old_castling = self.castling, .debugPeicePositions = self.peicePositions, .debugSimpleEval=self.simpleEval};
        assert(thisMove.original.colour == self.nextPlayer);
        const colour = thisMove.original.colour;
        self.simpleEval -= thisMove.taken.eval();
        
        self.peicePositions.unsetBit(move.from, colour);
        if (!thisMove.taken.empty()) self.peicePositions.unsetBit(move.to, thisMove.taken.colour);
        self.peicePositions.setBit(move.to, colour);
        if (thisMove.original.kind == .King) {
            switch (colour) {
                .Black => self.blackKingIndex = move.to,
                .White => self.whiteKingIndex = move.to,
            }

            // If you move your king, you can't castle on either side.
            const cI: usize = if (colour == .White) 0 else 1;
            self.castling.left[cI] = false;
            self.castling.right[cI] = false;
        }

        // If you move your rook, you can't castle on that side.
        if (thisMove.original.kind == .Rook) {
            const cI: usize = if (colour == .White) 0 else 1;
            if (move.from == 0 or move.from == (7*8)) {
                self.castling.left[cI] = false;
            }
            else if (move.from == 7 or move.from == (7*8 + 7)) {
                self.castling.right[cI] = false;
            }
        }

        // If you take a rook, they can't castle on that side.
        if (thisMove.taken.kind == .Rook) {
            const cI: usize = if (thisMove.taken.colour == .White) 0 else 1;
            if (move.to == 0 or move.to == (7*8)) {
                self.castling.left[cI] = false;
            }
            else if (move.to == 7 or move.to == (7*8 + 7)) {
                self.castling.right[cI] = false;
            }
        }
        
        switch (move.action) {
            .none => {
                self.squares[move.to] = thisMove.original;
                self.squares[move.from] = .{ .colour = undefined, .kind = .Empty };
            },
            .promote => |kind| {
                self.squares[move.to] = .{ .colour = colour, .kind = kind };
                self.squares[move.from] = .{ .colour = undefined, .kind = .Empty };
                self.simpleEval -= thisMove.original.eval();
                self.simpleEval += self.squares[move.to].eval();
            },
            .castle => |info| {
                self.squares[move.to] = thisMove.original;
                self.squares[move.from] = .{ .colour = undefined, .kind = .Empty };

                assert(thisMove.taken.empty());
                self.peicePositions.unsetBit(info.rookFrom, colour);
                self.peicePositions.setBit(info.rookTo, colour);
                assert(self.squares[info.rookTo].empty());
                assert(self.squares[info.rookFrom].is(colour, .Rook));
                self.squares[info.rookTo] = .{ .colour = colour, .kind = .Rook };
                self.squares[info.rookFrom] = .{ .colour = undefined, .kind = .Empty };
            }
        }

        assert(move.isCapture == (thisMove.taken.kind != .Empty));
        self.nextPlayer = self.nextPlayer.other();
        assert(self.hasCorrectPositionsBits());
        return thisMove;
    }

    // Thought this would be faster because less copying but almost no difference. 
    pub fn unplay(self: *Board, move: OldMove) void {
        assert(self.hasCorrectPositionsBits());
        const colour = move.original.colour;
        self.castling = move.old_castling;
        self.simpleEval += move.taken.eval();
        switch (move.move.action) {
            .none => {},
            .promote => |_| {
                self.simpleEval -= self.squares[move.move.to].eval();
                self.simpleEval += move.original.eval();
            },
            .castle => |info| {
                assert(self.squares[info.rookTo].is(colour, .Rook));
                assert(self.squares[info.rookFrom].empty());
                assert(self.squares[move.move.to].is(colour, .King));
                assert(self.squares[move.move.from].empty());

                self.peicePositions.setBit(info.rookFrom, colour);
                self.peicePositions.unsetBit(info.rookTo, colour);
                self.squares[info.rookTo] = .{ .colour = undefined, .kind = .Empty };
                self.squares[info.rookFrom] = .{ .colour = colour, .kind = .Rook };
            }
        }
        
        self.squares[move.move.to] = move.taken;
        self.squares[move.move.from] = move.original;

        self.peicePositions.setBit(move.move.from, colour);
        if (!move.taken.empty()) self.peicePositions.setBit(move.move.to, move.taken.colour);
        self.peicePositions.unsetBit(move.move.to, colour);
        if (move.original.kind == .King) {
            switch (colour) {
                .Black => self.blackKingIndex = move.move.from,
                .White => self.whiteKingIndex = move.move.from,
            }
        }
        
        self.nextPlayer = self.nextPlayer.other();
        assert(colour == self.nextPlayer);
        assert(std.meta.eql(move.debugPeicePositions, self.peicePositions));
        assert(self.hasCorrectPositionsBits());
        assert(self.simpleEval == move.debugSimpleEval);
    }

    pub fn copyPlay(self: *const Board, move: Move) Board {
        var board = self.*;
        _ = try board.play(move);
        return board;
    }

    // TODO: this rejects the extra data at the end because I can't store it yet. 
    pub fn fromFEN(fen: [] const u8) InvalidFenErr!Board {
        var self = Board.blank();
        var file: u8 = 0;
        var rank: u8 = 7;
        var i: usize = 0;
        for (fen) |letter| {
            defer i += 1;
            if (letter == ' ') break;

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

        // Extra info fields
        if (i != fen.len){
            switch (fen[i]) {
                'w' => self.nextPlayer = .White,
                'b' => self.nextPlayer = .Black,
                else => return error.InvalidFen,
            }
            i += 1;

            // Reject extra fields. TODO
            if (i != fen.len) return error.InvalidFen;

        } // TODO: else should probably be a hard error but for now specifing player to move is optional and defaults to white. 
         
        return self;
    }

    // Caller owns the returned string. 
    pub fn toFEN(self: *const Board, allocator: std.mem.Allocator) std.mem.Allocator.Error![] u8 {
        var letters = try std.ArrayList(u8).initCapacity(allocator, 64 + 8 + 2);
        errdefer letters.deinit();
        try self.appendFEN(&letters);
        return try letters.toOwnedSlice();
    }

    pub fn appendFEN(self: *const Board, letters: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
        for (0..8) |rank| {
            var empty: u8 = 0;
            for (0..8) |file| {
                const p = self.get(file, 7-rank);
                if (p.empty()) {
                    empty += 1;
                    continue;
                } 
                if (empty > 0) {
                    try letters.append(empty + ASCII_ZERO_CHAR);
                    empty = 0;
                }
                try letters.append(p.toChar());
            }
            if (empty > 0) {
                try letters.append(empty + ASCII_ZERO_CHAR);
            }
            if (rank < 7){
                try letters.append('/');
            }
        }
        try letters.append(' ');
        try letters.append(if (self.nextPlayer == .White) 'w' else 'b');
    }

    // Caller owns the returned string. 
    pub fn displayString(self: *const Board, allocator: std.mem.Allocator) ![] u8 {
        var letters = try std.ArrayList(u8).initCapacity(allocator, 64 + 8 + (64*3) + 64 + 8 + 8 + 2);
        try self.appendFEN(&letters);
        try letters.append('\n');

        for (0..8) |rank| {
            try letters.append('|');
            for (0..8) |file| {
                const char = self.get(file, 7 - rank).toUnicode();
                const remaining = letters.allocatedSlice()[letters.items.len..letters.capacity];
                const count = try std.unicode.utf8Encode(char, remaining);
                letters.items.len += count;
                try letters.append('|');
            }
            try letters.append('\n');
        }

        return try letters.toOwnedSlice();
    }

    pub fn debugPrint(self: *const Board) void {
        if (isWasm) return;
        var staticDebugBuffer: [500] u8 = undefined;
        var staticDebugAlloc = std.heap.FixedBufferAllocator.init(&staticDebugBuffer);
        const s = self.displayString(staticDebugAlloc.allocator()) catch @panic("Board.debugPrint buffer OOM.");
        std.debug.print("{s}\n", .{ s });
    }

    pub fn hasCorrectPositionsBits(board: *const Board) bool {
        const valid = v: {
            var flag: u64 = 1;
            for (board.squares) |piece| {
                defer flag = flag << 1;
                if (piece.kind == .Empty){
                    if ((board.peicePositions.white & flag) != 0) break :v false;
                    if ((board.peicePositions.black & flag) != 0) break :v false;
                } else {
                    if ((board.peicePositions.getFlag(piece.colour) & flag) == 0) break :v false;
                }
            }

            // TODO: this is broken until I detect checkmate
            // if (!board.squares[board.whiteKingIndex].is(.White, .King)) {
            //     if (board.whiteKingIndex == 0) std.debug.print("whiteKingIndex=0, maybe not set?\n", .{});
            //     break :v false;
            // }
            // if (!board.squares[board.blackKingIndex].is(.Black, .King)) {
            //     if (board.blackKingIndex == 0) std.debug.print("blackKingIndex=0, maybe not set?\n", .{});
            //     break :v false;
            // }
            break :v true;
        };

        if (!valid and !isWasm) {
            board.debugPrint();
            std.debug.print("white: {b}\nblack: {b}\neval={}. {} to move. kings: {} {}\n {}\n\n", .{board.peicePositions.white, board.peicePositions.black, board.simpleEval, board.nextPlayer, board.whiteKingIndex, board.blackKingIndex, board.castling});
        }
        return valid;
        
    }

    pub fn expectEqual(a: *const Board, b: *const Board) !void {
        for (a.squares, b.squares) |aSq, bSq| {
            if (aSq.empty() and bSq.empty()) continue;
            if (!std.meta.eql(aSq, bSq)) {
                if (!isWasm) {
                    std.debug.print("=====\n", .{});
                    a.debugPrint();
                    b.debugPrint();
                    std.debug.print("Expected boards above to be equal.\n", .{});
                }
                return error.TestExpectedEqual;
            }
        }
        var badMetaData = !a.hasCorrectPositionsBits() or !b.hasCorrectPositionsBits() 
                        or !std.meta.eql(a.castling, b.castling) or !std.meta.eql(a.simpleEval, b.simpleEval) 
                        or !std.meta.eql(a.nextPlayer, b.nextPlayer);
        if (badMetaData) {
            if (!isWasm) {
                std.debug.print("=====\n", .{});
                a.debugPrint();
                std.debug.print("white: {b}\nblack: {b}\neval={}. {} to move. kings: {} {}\n {}\n\n", .{a.peicePositions.white, a.peicePositions.black, a.simpleEval, a.nextPlayer, a.whiteKingIndex, a.blackKingIndex, a.castling});
                b.debugPrint();
                std.debug.print("white: {b}\nblack: {b}\neval={} {} to move. kings: {} {}\n {}\n\n", .{b.peicePositions.white, b.peicePositions.black, b.simpleEval, b.nextPlayer, b.whiteKingIndex, b.blackKingIndex, b.castling});
                std.debug.print("Expected boards above to be equal.\n", .{});
            }
            return error.TestExpectedEqual;
        }
    }
};

const isWasm = @import("builtin").target.isWasm();
