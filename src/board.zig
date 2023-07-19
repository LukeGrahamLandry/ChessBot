const std = @import("std");
const Magic = @import("magic.zig");
const print = if (@import("builtin").target.isWasm()) @import("web.zig").consolePrint else std.debug.print;

const assert = std.debug.assert;
// inline fn assert(val: bool) void {
//     std.debug.assert(val);
//     // _ = val;
// }

// Calling hasCorrectPositionsBits doesn't get optimised out in release mode when passed to std assert. But it does if passed to a function that discards it.
// I think even this and inlining both doesn't fix that
inline fn assertSlow(val: bool) void {
    // std.debug.assert(val);
    _ = val;
}

// Numbers matter because js sees them.
pub const Kind = enum(u4) {
    Empty = 0,
    Pawn = 6,
    Bishop = 3,
    Knight = 4,
    Rook = 5,
    Queen = 2,
    King = 1,

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
    White = 0,
    Black = 1,

    pub fn other(self: Colour) Colour {
        return @enumFromInt(~@intFromEnum(self));
    }

    pub inline fn dir(self: Colour) i32 {
        // 0 -> 1, 1 -> -1
        return 1 - 2 * @as(i32, @intFromEnum(self));
    }
};

// This is packed with explicit padding so I can cast boards to byte arrays and pass to js.
pub const Piece = packed struct {
    colour: Colour,
    kind: Kind,
    _pad: u3 = 0,

    // An empty square is all zeros (not just kind=Empty and undefined colour). This means a raw byte array can be used in board's hash/eql.
    pub const EMPTY: Piece = .{ .kind = .Empty, .colour = .White };

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
            }),
        };
    }

    pub fn toChar(self: Piece) u8 {
        const letters = [_]u8{ ' ', 'K', 'Q', 'B', 'N', 'R', 'P' };
        const letter = letters[@intFromEnum(self.kind)];
        return switch (self.colour) {
            .White => letter,
            .Black => std.ascii.toLower(letter),
        };
    }

    pub fn toUnicode(self: Piece) u21 {
        const letters = [_]u21{ ' ', '♔', '♕', '♗', '♘', '♖', '♙' };
        const letter = letters[@intFromEnum(self.kind)];
        return switch (self.colour) {
            .White => letter,
            .Black => letter + 6,
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
const InvalidFenErr = error{InvalidFen};

const BitBoardPair = packed struct {
    white: u64 = 0,
    black: u64 = 0,

    pub fn setBit(self: *BitBoardPair, index: u6, colour: Colour) void {
        switch (colour) {
            .White => self.white |= (@as(u64, 1) << index),
            .Black => self.black |= (@as(u64, 1) << index),
        }
    }

    pub fn unsetBit(self: *BitBoardPair, index: u6, colour: Colour) void {
        switch (colour) {
            .White => self.white ^= (@as(u64, 1) << index),
            .Black => self.black ^= (@as(u64, 1) << index),
        }
    }

    pub fn getFlag(self: *const BitBoardPair, colour: Colour) u64 {
        return switch (colour) {
            .White => self.white,
            .Black => self.black,
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
    debugSimpleEval: i32,
    frenchMove: FrenchMove,
    oldHalfMoveDraw: u32 = 0,
};

const CastlingRights = packed struct(u8) {
    whiteLeft: bool = true,
    whiteRight: bool = true,
    blackLeft: bool = true,
    blackRight: bool = true,
    _fuck: u4 = 0,

    // TODO: goingLeft should be an enum
    pub fn get(self: CastlingRights, colour: Colour, comptime goingLeft: bool) bool {
        switch (colour) {
            .White => return if (goingLeft) self.whiteLeft else self.whiteRight,
            .Black => return if (goingLeft) self.blackLeft else self.blackRight,
        }
    }

    pub fn set(self: *CastlingRights, colour: Colour, comptime goingLeft: bool, value: bool) void {
        switch (colour) {
            .White => return if (goingLeft) {
                self.whiteLeft = value;
            } else {
                self.whiteRight = value;
            },
            .Black => return if (goingLeft) {
                self.blackLeft = value;
            } else {
                self.blackRight = value;
            },
        }
    }

    pub fn any(self: CastlingRights) bool {
        return @as(u8, @bitCast(self)) != 0;
    }
};

comptime {
    std.debug.assert(@sizeOf(CastlingRights) == 1);
}

const FrenchMove = union(enum) { none, file: u4 };
const slowTrackAllMoves = false;

// TODO: Count moves for draw.
pub const Board = struct {
    // TODO: this could be a PackedIntArray if I remove padding from Piece and deal with re-encoding to bytes before sending to js. is that better?
    squares: [64]Piece = std.mem.zeroes([64]Piece),
    peicePositions: BitBoardPair = .{},
    // TODO: make sure these are packed nicely
    simpleEval: i32 = 0, // TODO: a test that recalculates
    blackKingIndex: u6 = 0,
    whiteKingIndex: u6 = 0,
    frenchMove: FrenchMove = .none,
    nextPlayer: Colour = .White,
    castling: CastlingRights = .{},
    halfMoveDraw: u32 = 0,
    fullMoves: u32 = 0,
    line: if (slowTrackAllMoves) std.BoundedArray(OldMove, 100) else void = if (slowTrackAllMoves) std.BoundedArray(OldMove, 100).init(0) catch @panic("Overflow line.") else {}, // inefficient but useful for debugging.

    pub fn blank() Board {
        return .{};
    }

    pub fn set(self: *Board, file: u8, rank: u8, value: Piece) void {
        assert(self.emptyAt(file, rank));
        const index: u6 = @intCast(rank * 8 + file);
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
        return self.squares[rank * 8 + file];
    }

    pub fn initial() Board {
        // This is kinda cool. It's a compile error if this fails to parse, so the function doesn't return an error union.
        return comptime try fromFEN(INIT_FEN);
    }

    pub fn emptyAt(self: *const Board, file: usize, rank: usize) bool {
        const index: u6 = @intCast(rank * 8 + file);
        const flag = @as(u64, 1) << index;
        const isEmpty = ((self.peicePositions.white & flag) | (self.peicePositions.black & flag)) == 0;
        // assert(self.get(file, rank).empty() == isEmpty);
        return isEmpty;
    }

    pub fn emptyAtI(self: *const Board, index: usize) bool {
        const i: u6 = @intCast(index);
        const flag = @as(u64, 1) << i;
        const isEmpty = ((self.peicePositions.white & flag) | (self.peicePositions.black & flag)) == 0;
        return isEmpty;
        // return self.squares[index].kind == .Empty;
    }

    /// This assumes that <move> is legal.
    pub fn play(self: *Board, move: Move) OldMove {
        assert(move.from != move.to);
        assertSlow(self.hasCorrectPositionsBits());
        const thisMove: OldMove = .{ .move = move, .taken = self.squares[move.to], .original = self.squares[move.from], .old_castling = self.castling, .debugPeicePositions = self.peicePositions, .debugSimpleEval = self.simpleEval, .frenchMove = self.frenchMove, .oldHalfMoveDraw = self.halfMoveDraw };
        assert(thisMove.original.colour == self.nextPlayer);
        const colour = thisMove.original.colour;
        self.simpleEval -= thisMove.taken.eval();
        self.frenchMove = .none;
        self.simpleEval += move.bonus * colour.dir();

        self.peicePositions.unsetBit(move.from, colour);
        if (!thisMove.taken.empty()) self.peicePositions.unsetBit(move.to, thisMove.taken.colour);
        self.peicePositions.setBit(move.to, colour);

        if (colour == .Black) self.fullMoves += 1;
        self.halfMoveDraw += 1;
        if (move.isCapture) self.halfMoveDraw = 0;
        switch (thisMove.original.kind) {
            .King => {
                switch (colour) {
                    .Black => self.blackKingIndex = move.to,
                    .White => self.whiteKingIndex = move.to,
                }
            },
            .Pawn => {
                self.halfMoveDraw = 0;
            },
            else => {},
        }

        // Most of the time, nobody can castle. Handle that case in the fewest branches.
        // TODO: punish for loosing castling rights
        if (self.castling.any()) {
            if (thisMove.original.kind == .King) {
                // If you move your king, you can't castle on either side.
                self.castling.set(colour, true, false);
                self.castling.set(colour, false, false);
            }

            // If you move your rook, you can't castle on that side.
            if (thisMove.original.kind == .Rook) {
                if (move.from == 0 or move.from == (7 * 8)) {
                    self.castling.set(colour, true, false);
                } else if (move.from == 7 or move.from == (7 * 8 + 7)) {
                    self.castling.set(colour, false, false);
                }
            }

            // If you take a rook, they can't castle on that side.
            if (thisMove.taken.kind == .Rook) {
                assert(thisMove.taken.colour == colour.other());
                if (move.to == 0 or move.to == (7 * 8)) {
                    self.castling.set(colour.other(), true, false);
                } else if (move.to == 7 or move.to == (7 * 8 + 7)) {
                    self.castling.set(colour.other(), false, false);
                }
            }
        }

        switch (move.action) {
            .none => {
                assert(move.isCapture == (thisMove.taken.kind != .Empty));
                self.squares[move.to] = thisMove.original;
                self.squares[move.from] = Piece.EMPTY;
            },
            .promote => |kind| {
                self.squares[move.to] = .{ .colour = colour, .kind = kind };
                self.squares[move.from] = Piece.EMPTY;
                self.simpleEval -= thisMove.original.eval();
                self.simpleEval += self.squares[move.to].eval();
                assert(move.isCapture == (thisMove.taken.kind != .Empty));
            },
            .castle => |info| {
                assert(self.squares[move.from].is(colour, .King));
                self.squares[move.to] = thisMove.original;
                self.squares[move.from] = Piece.EMPTY;

                assert(thisMove.taken.empty());
                self.peicePositions.unsetBit(info.rookFrom, colour);
                self.peicePositions.setBit(info.rookTo, colour);
                assert(self.squares[info.rookTo].empty());
                assert(self.squares[info.rookFrom].is(colour, .Rook));
                self.squares[info.rookTo] = .{ .colour = colour, .kind = .Rook };
                self.squares[info.rookFrom] = Piece.EMPTY;
                assert(!move.isCapture and (thisMove.taken.kind == .Empty));
                self.simpleEval += Magic.CASTLE_REWARD * colour.dir();
            },
            .allowFrenchMove => {
                assert(self.squares[move.from].is(colour, .Pawn));
                self.squares[move.to] = thisMove.original;
                self.squares[move.from] = Piece.EMPTY;
                self.frenchMove = .{ .file = @intCast(@rem(move.to, 8)) };
                assert(!move.isCapture and (thisMove.taken.kind == .Empty));
            },
            .useFrenchMove => |captureIndex| {
                assert(self.squares[move.from].is(colour, .Pawn));
                assert(self.squares[move.to].empty());
                assert(self.squares[captureIndex].is(colour.other(), .Pawn));
                self.squares[move.to] = thisMove.original;
                self.squares[move.from] = Piece.EMPTY;
                self.simpleEval -= self.squares[captureIndex].eval();
                self.squares[captureIndex] = Piece.EMPTY;
                assert(move.isCapture and thisMove.taken.kind == .Empty); // confusing
                self.squares[captureIndex] = Piece.EMPTY;
                self.peicePositions.unsetBit(captureIndex, colour.other());
            },
        }

        self.nextPlayer = self.nextPlayer.other();
        assertSlow(self.hasCorrectPositionsBits());
        // self.line.append(thisMove) catch @panic("Overflow line.");
        return thisMove;
    }

    // Thought this would be faster because less copying but almost no difference (at the time. TODO: check again).
    /// <move> must be the value returned from playing the most recent move.
    pub fn unplay(self: *Board, move: OldMove) void {
        // assert(std.meta.eql(self.line.pop(), move));
        assertSlow(self.hasCorrectPositionsBits());
        const colour = move.original.colour;
        self.castling = move.old_castling;
        self.frenchMove = move.frenchMove;
        self.simpleEval += move.taken.eval();
        self.halfMoveDraw = move.oldHalfMoveDraw;
        self.simpleEval -= move.move.bonus * colour.dir();
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
                self.squares[info.rookTo] = .{ .colour = .White, .kind = .Empty };
                self.squares[info.rookFrom] = .{ .colour = colour, .kind = .Rook };
                self.simpleEval -= Magic.CASTLE_REWARD * colour.dir();
            },
            .allowFrenchMove => {},
            .useFrenchMove => |captureIndex| {
                self.squares[captureIndex] = .{ .kind = .Pawn, .colour = colour.other() };
                self.simpleEval += self.squares[captureIndex].eval();
                self.peicePositions.setBit(captureIndex, colour.other());
            },
        }

        self.squares[move.move.to] = move.taken;
        self.squares[move.move.from] = move.original;

        self.peicePositions.setBit(move.move.from, colour);
        if (!move.taken.empty()) self.peicePositions.setBit(move.move.to, move.taken.colour);
        self.peicePositions.unsetBit(move.move.to, colour);
        if (colour == .Black) self.fullMoves -= 1;

        switch (move.original.kind) {
            .King => {
                switch (colour) {
                    .Black => self.blackKingIndex = move.move.from,
                    .White => self.whiteKingIndex = move.move.from,
                }
            },
            else => {},
        }

        self.nextPlayer = self.nextPlayer.other();
        assert(colour == self.nextPlayer);
        assert(std.meta.eql(move.debugPeicePositions, self.peicePositions));
        assertSlow(self.hasCorrectPositionsBits());
        assert(self.simpleEval == move.debugSimpleEval);
    }

    pub fn copyPlay(self: *const Board, move: Move) Board {
        var board = self.*;
        _ = board.play(move);
        return board;
    }

    // TODO: allow for extra spaces
    pub fn fromFEN(fen: []const u8) InvalidFenErr!Board {
        var self = Board.blank();
        var file: u8 = 0;
        var rank: u8 = 7;
        var i: usize = 0;

        // Pieces
        for (fen) |letter| {
            defer i += 1;
            if (letter == ' ') break;

            if (std.ascii.isDigit(letter)) {
                const count = letter - ASCII_ZERO_CHAR;
                file += count;
            } else if (letter == '/') {
                if (file != 8) return error.InvalidFen;
                file = 0;
                if (rank == 0) return error.InvalidFen; // This assumes no trailing '/'
                rank -= 1;
            } else {
                self.set(file, rank, try Piece.fromChar(letter));
                file += 1;
                if (rank > 8) return error.InvalidFen;
            }
        }

        if (file != 8) return error.InvalidFen;
        if (i == fen.len) return error.InvalidFen;

        // Whose turn?
        switch (fen[i]) {
            'w' => self.nextPlayer = .White,
            'b' => self.nextPlayer = .Black,
            else => return error.InvalidFen,
        }
        i += 1;

        if (i == fen.len) return self; // Missing fields could be an error but I'm feeling chill today.
        if (fen[i] != ' ') return error.InvalidFen;
        i += 1;

        // TODO: parse the rest
        // Castling

        // En-passant

        // Half moves

        // Full moves

        return self;
    }

    // Caller owns the returned string.
    pub fn toFEN(self: *const Board, allocator: std.mem.Allocator) AppendErr![]u8 {
        var letters = try std.ArrayList(u8).initCapacity(allocator, 64 + 8 + 30); // Bad idea!
        errdefer letters.deinit();
        try self.appendFEN(&letters);
        return try letters.toOwnedSlice();
    }

    // letters: pointer to ArrayList or BoundedArray
    pub fn appendFEN(self: *const Board, letters: anytype) AppendErr!void {
        for (0..8) |rank| {
            var empty: u8 = 0;
            for (0..8) |file| {
                const p = self.get(file, 7 - rank);
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
            if (rank < 7) {
                try letters.append('/');
            }
        }
        try letters.append(' ');

        try letters.append(if (self.nextPlayer == .White) 'w' else 'b');
        try letters.append(' ');

        // Order matters! Stockfish gets confused by qk.
        if (self.castling.whiteRight) try letters.append('K');
        if (self.castling.whiteLeft) try letters.append('Q');
        if (self.castling.blackRight) try letters.append('k');
        if (self.castling.blackLeft) try letters.append('q');
        if (!self.castling.any()) try letters.append('-');
        try letters.append(' ');

        try letters.append('-'); // TODO: french move
        try letters.append(' ');

        // TODO: ugly. want it to work on bounded + list
        const half = std.fmt.formatIntBuf(letters.unusedCapacitySlice(), self.halfMoveDraw, 10, .lower, .{});
        if (@hasField(@TypeOf(letters.*), "len")) letters.len += @intCast(half) else letters.items.len += half;
        try letters.append(' ');

        const full = std.fmt.formatIntBuf(letters.unusedCapacitySlice(), self.fullMoves, 10, .lower, .{});
        if (@hasField(@TypeOf(letters.*), "len")) letters.len += @intCast(full) else letters.items.len += full;
    }

    // Caller owns the returned string.
    pub fn displayString(self: *const Board, allocator: std.mem.Allocator) ![]u8 {
        var letters = try std.ArrayList(u8).initCapacity(allocator, 64 + 8 + (64 * 3) + 64 + 8 + 8 + 2);
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
        var staticDebugBuffer: [500]u8 = undefined;
        var staticDebugAlloc = std.heap.FixedBufferAllocator.init(&staticDebugBuffer);
        const s = self.displayString(staticDebugAlloc.allocator()) catch @panic("Board.debugPrint buffer OOM.");
        print("{s}\n", .{s});
    }

    // Asserts to this don't get compiled out in release mode! It's like 10x faster with this commented out.
    pub inline fn hasCorrectPositionsBits(board: *const Board) bool {
        _ = board;

        // const valid = v: {
        //     var flag: u64 = 1;
        //     for (board.squares) |piece| {
        //         defer flag = flag << 1;
        //         if (piece.kind == .Empty){
        //             if ((board.peicePositions.white & flag) != 0) break :v false;
        //             if ((board.peicePositions.black & flag) != 0) break :v false;
        //         } else {
        //             if ((board.peicePositions.getFlag(piece.colour) & flag) == 0) break :v false;
        //         }
        //     }

        //     // TODO: this is broken until I detect checkmate
        //     // if (!board.squares[board.whiteKingIndex].is(.White, .King)) {
        //     //     if (board.whiteKingIndex == 0) print("whiteKingIndex=0, maybe not set?\n", .{});
        //     //     break :v false;
        //     // }
        //     // if (!board.squares[board.blackKingIndex].is(.Black, .King)) {
        //     //     if (board.blackKingIndex == 0) print("blackKingIndex=0, maybe not set?\n", .{});
        //     //     break :v false;
        //     // }
        //     if (board.simpleEval != @import("movegen.zig").MoveFilter.Any.get().slowSimpleEval(board)) break :v false;
        //     break :v true;
        // };

        // // if (!valid and !isWasm) {
        // //     board.debugPrint();
        // //     print("white: {b}\nblack: {b}\neval={}. {} to move. kings: {} {}\n {}\n\n", .{board.peicePositions.white, board.peicePositions.black, board.simpleEval, board.nextPlayer, board.whiteKingIndex, board.blackKingIndex, board.castling});
        // // }
        // return valid;
        return true;
    }

    pub fn expectEqual(a: *const Board, b: *const Board) !void {
        for (a.squares, b.squares) |aSq, bSq| {
            if (aSq.empty() and bSq.empty()) continue;
            if (!std.meta.eql(aSq, bSq)) {
                if (!isWasm) {
                    print("=====\n", .{});
                    a.debugPrint();
                    b.debugPrint();
                    print("Expected boards above to be equal.\n", .{});
                }
                return error.TestExpectedEqual;
            }
        }
        var badMetaData = !a.hasCorrectPositionsBits() or !b.hasCorrectPositionsBits() or !std.meta.eql(a.castling, b.castling) or !std.meta.eql(a.simpleEval, b.simpleEval) or !std.meta.eql(a.nextPlayer, b.nextPlayer);
        if (badMetaData) {
            if (!isWasm) {
                print("=====\n", .{});
                a.debugPrint();
                print("white: {b}\nblack: {b}\neval={}. {} to move. kings: {} {}\n {}\n\n", .{ a.peicePositions.white, a.peicePositions.black, a.simpleEval, a.nextPlayer, a.whiteKingIndex, a.blackKingIndex, a.castling });
                b.debugPrint();
                print("white: {b}\nblack: {b}\neval={} {} to move. kings: {} {}\n {}\n\n", .{ b.peicePositions.white, b.peicePositions.black, b.simpleEval, b.nextPlayer, b.whiteKingIndex, b.blackKingIndex, b.castling });
                print("Expected boards above to be equal.\n", .{});
            }
            return error.TestExpectedEqual;
        }
    }
};

pub const AppendErr = error{Overflow} || std.mem.Allocator.Error;

// !!!Compiler bug!!! https://github.com/ziglang/zig/issues/16392
pub const CastleMove = packed struct { rookFrom: u6, rookTo: u6, fuck: u4 = 0 };

// TODO: this seems much too big (8 bytes?). castling info is redunant cause other side can infer if king moves 2 squares, bool field is evil and redundant
pub const Move = struct {
    from: u6,
    to: u6,
    isCapture: bool, // french move says true but to square isnt the captured one
    action: union(enum(u3)) {
        none,
        promote: Kind,
        castle: CastleMove,
        allowFrenchMove,
        useFrenchMove: u6, // capture index
    },
    bonus: i8 = 0, // positive is good for the player moving.
    // evalGuess: i32 = 0,

    /// This assumes they are made in the same position.
    pub fn eql(a: Move, b: Move) bool {
        return a.from == b.from and a.to == b.to;
    }

    pub fn text(self: Move) ![5] u8 {
        return try @import("uci.zig").writeAlgebraic(self);
    }
};

// TODO: report in ui
pub const GameOver = enum { Continue, Stalemate, FiftyMoveDraw, WhiteWins, BlackWins };

const isWasm = @import("builtin").target.isWasm();

pub const InferMoveErr = error{IllegalMove} || @import("search.zig").MoveErr;

// TODO: don't like that im hard coding strategies here
const genAllMoves = @import("movegen.zig").MoveFilter.Any.get();
const search = @import("search.zig").default;
pub fn inferPlayMove(board: *Board, fromIndex: u32, toIndex: u32, alloc: std.mem.Allocator) InferMoveErr!OldMove {
    const colour = board.nextPlayer;
    if (board.squares[fromIndex].empty()) {
        print("Tried to move from empty square. {}\n", .{board.squares[fromIndex]});
        return error.IllegalMove;
    }
    if (board.squares[fromIndex].colour != colour) {
        print("Tried to move wrong colour. {}\n", .{board.squares[fromIndex]});
        return error.IllegalMove;
    }

    const isCapture = !board.squares[toIndex].empty() and board.squares[toIndex].colour != colour;
    var move: Move = .{ .from = @intCast(fromIndex), .to = @intCast(toIndex), .action = .none, .isCapture = isCapture };
    // TODO: ui should know when promoting so it can let you choose which piece to make.
    if (board.squares[fromIndex].kind == .Pawn) {
        // TODO: factor out some canPromote function so magic numbers live in one place
        const isPromote = (colour == .Black and toIndex <= 7) or (colour == .White and toIndex > (64 - 8));
        if (isPromote) {
            move.action = .{ .promote = .Queen };
        } else {
            const toRank = @divFloor(toIndex, 8);
            const fromRank = @divFloor(fromIndex, 8);
            const isForwardTwo = (colour == .Black and toRank == 4 and fromRank == 6) or (colour == .White and toRank == 3 and fromRank == 1);
            if (isForwardTwo) {
                move.action = .allowFrenchMove;
            } else {
                const toFile = @mod(toIndex, 8);
                const fromFile = @mod(fromIndex, 8);
                if (toFile != fromFile and !move.isCapture) { // this will include invalid moves but that's checked below
                    move.isCapture = true;
                    const captureIndex = ((if (colour == .White) toRank - 1 else toRank + 1) * 8) + toFile;
                    move.action = .{ .useFrenchMove = @intCast(captureIndex) };
                }
            }
        }
    } else if (board.squares[fromIndex].kind == .King) {
        var castles = std.ArrayList(Move).init(alloc);
        defer castles.deinit();
        const file: usize = @rem(fromIndex, 8);
        const rank: usize = @divFloor(fromIndex, 8);
        try genAllMoves.tryCastle(&castles, board, @intCast(fromIndex), file, rank, colour, true);
        try genAllMoves.tryCastle(&castles, board, @intCast(fromIndex), file, rank, colour, false);
        assert(castles.items.len <= 2);
        if (castles.items.len > 0 and castles.items[0].to == toIndex) {
            move = castles.items[0];
        } else if (castles.items.len > 1 and castles.items[1].to == toIndex) {
            move = castles.items[1];
        }
    }

    // Check if this is a legal move by the current player.
    const allMoves = try genAllMoves.possibleMoves(board, colour, alloc);
    defer alloc.free(allMoves);
    var realMove: Move = undefined;
    for (allMoves) |m| {
        // TODO: this is all you need, dont bother with all that shit above. just use <m> below
        if (std.meta.eql(move.from, m.from) and std.meta.eql(move.to, m.to)) {
            realMove = m;
            break;
        }
    } else {
        return error.IllegalMove;
    }

    const unMove = board.play(realMove);
    if (try search.inCheck(board, colour, alloc)) {
        board.unplay(unMove);
        return error.IllegalMove;
    }

    return unMove;
}
