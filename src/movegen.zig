//! Generating the list of possible moves for a position.

const std = @import("std");
const Magic = @import("common.zig").Magic;
const print = @import("common.zig").print;
const assert = @import("common.zig").assert;
const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;
const StratOpts = @import("search.zig").StratOpts;
const Move = @import("board.zig").Move;

pub const MoveFilter = enum {
    Any,
    CapturesOnly,
    KingCapturesOnly, // TODO: write a test with this against reverseFromKingIsInCheck

    pub fn get(comptime self: MoveFilter) type {
        return struct {
            pub fn possibleMoves(board: *Board, me: Colour, alloc: std.mem.Allocator) ![]Move {
                assert(board.nextPlayer == me); // sanity. TODO: don't bother passing colour since the board knows?
                var moves = try std.ArrayList(Move).initCapacity(alloc, 50);
                const out: CollectMoves = .{ .moves=&moves, .filter=self };
                try genPossibleMoves(out, board, me, alloc);
                return try moves.toOwnedSlice();  // TODO: make sure this isn't reallocating
            }

            pub fn collectOnePieceMoves(moves: *std.ArrayList(Move), board: *Board, i: usize, file: usize, rank: usize) !void {
                const out: CollectMoves = .{ .moves=moves, .filter=self };
                try genOnePieceMoves(out, board, i, file, rank);
            }
        };
    }
};

// Caller owns the returned slice.
pub fn genPossibleMoves(out: anytype, board: *Board, me: Colour, alloc: std.mem.Allocator) !void {
    _ = alloc;
    const mySquares = board.peicePositions.getFlag(me);

    var flag: u64 = 1;
    for (0..64) |i| {
        defer flag <<= 1; // shift the bit over at the end of each iteration.
        if ((mySquares & flag) == 0) {
            assert(board.squares[i].empty() or board.squares[i].colour != me);
            continue;
        }
        assert(!board.squares[i].empty());
        assert(board.squares[i].colour == me);

        const file = i % 8;
        const rank = i / 8;
        try genOnePieceMoves(out, board, i, file, rank);
    }
}

pub fn genOnePieceMoves(out: anytype, board: *Board, i: usize, file: usize, rank: usize) !void {
    const piece = board.squares[i];
    switch (piece.kind) {
        .Pawn => try pawnMove(out, board, i, file, rank, piece),
        .Bishop => try bishopSlide(out, board, i, file, rank, piece),
        .Knight => try knightMove(out, board, i, file, rank, piece),
        .Rook => try rookSlide(out, board, i, file, rank, piece),
        .King => try kingMove(out, board, i, file, rank, piece),
        .Queen => {
            try rookSlide(out, board, i, file, rank, piece);
            try bishopSlide(out, board, i, file, rank, piece);
        },
        .Empty => unreachable,
    }
}

fn rookSlide(out: anytype, board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    inline for (directions[0..4]) |offset| {
        var checkFile = @as(isize, @intCast(file));
        var checkRank = @as(isize, @intCast(rank));
        while (true) {
            checkFile += offset[0];
            checkRank += offset[1];
            if (checkFile > 7 or checkRank > 7 or checkFile < 0 or checkRank < 0) break;
            if (try out.trySlide(board, i, @intCast(checkFile), @intCast(checkRank), piece)) break;
        }
    }
}

fn pawnMove(out: anytype, board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    const targetRank = switch (piece.colour) {
        // Asserts can't have a pawn at the end in real games because it would have promoted.
        .White => w: {
            assert(rank < 7);
            if (out.filter == .Any and rank == 1 and board.emptyAt(file, 2) and board.emptyAt(file, 3)) { // forward two
                try out.pawnForwardTwo(i, file, 3); // cant promote
            }
            break :w rank + 1;
        },
        .Black => b: {
            assert(rank > 0);
            if (out.filter == .Any and rank == 6 and board.emptyAt(file, 5) and board.emptyAt(file, 4)) { // forward two
                try out.pawnForwardTwo(i, file, 4); // cant promote
            }
            break :b rank - 1;
        },
    };

    if (out.filter == .Any and board.emptyAt(file, targetRank)) { // forward
        try out.maybePromote(board, i, file, targetRank, piece.colour);
    }
    if (file < 7) { // right
        try out.pawnAttack(board, i, file + 1, targetRank, piece.colour);
        try frenchMove(out, board, i, file + 1, targetRank, piece.colour);
    }
    if (file > 0) { // left
        try out.pawnAttack(board, i, file - 1, targetRank, piece.colour);
        try frenchMove(out, board, i, file - 1, targetRank, piece.colour);
    }
}

fn frenchMove(out: anytype, board: *const Board, i: usize, targetFile: usize, targetRank: usize, colour: Colour) !void {
    // TODO
    // Most of the time you can't en-passant so make that case as fast as possible.
    switch (board.frenchMove) {
        .none => return,
        .file => |validTargetFile| {
            if (targetFile != validTargetFile) return;
            if ((colour == .White and targetRank != 5) or (colour == .Black and targetRank != 2)) return;
            const endIndex = targetRank * 8 + targetFile;
            const captureIndex = ((if (colour == .White) targetRank - 1 else targetRank + 1) * 8) + targetFile;
            assert(board.squares[captureIndex].is(colour.other(), .Pawn));
            try out.appendPawn(.{ .from = @intCast(i), .to = @intCast(endIndex), .action = .{ .useFrenchMove = @intCast(captureIndex) }, .isCapture = true });
        },
    }
}

// TODO: This is suck!
fn bishopSlide(out: anytype, board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    inline for (directions[4..8]) |offset| {
        var checkFile = @as(isize, @intCast(file));
        var checkRank = @as(isize, @intCast(rank));
        while (true) {
            checkFile += offset[0];
            checkRank += offset[1];
            if (checkFile > 7 or checkRank > 7 or checkFile < 0 or checkRank < 0) break;
            if (try out.trySlide(board, i, @intCast(checkFile), @intCast(checkRank), piece)) break;
        }
    }
}

fn kingMove(out: anytype, board: *Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    // forward
    if (file < 7) {
        _ = try out.trySlide(board, i, file + 1, rank, piece);
        if (rank < 7) _ = try out.trySlide(board, i, file + 1, rank + 1, piece);
        if (rank > 0) _ = try out.trySlide(board, i, file + 1, rank - 1, piece);
    }
    // back
    if (file > 0) {
        _ = try out.trySlide(board, i, file - 1, rank, piece);
        if (rank < 7) _ = try out.trySlide(board, i, file - 1, rank + 1, piece);
        if (rank > 0) _ = try out.trySlide(board, i, file - 1, rank - 1, piece);
    }
    // horizontal
    if (rank < 7) _ = try out.trySlide(board, i, file, rank + 1, piece);
    if (rank > 0) _ = try out.trySlide(board, i, file, rank - 1, piece);

    try tryCastle(out, board, i, file, rank, piece.colour, true);
    try tryCastle(out, board, i, file, rank, piece.colour, false);
}

fn castlingIsLegal(board: *Board, i: usize, colour: Colour, comptime goingLeft: bool) !bool {
    if (board.inCheck(colour)) return false;
    const path = if (goingLeft) [_]usize{ i - 1, i - 2, i - 3 } else [_]usize{ i + 1, i + 2 };
    for (path) |sq| {
        // TODO: do this without playing the move? It annoys me that this makes getPossibleMoves take a mutable board pointer (would also be fixed by doing it later with other legal move checks).
        const move = ii(@intCast(i), @intCast(sq), false);
        const unMove = board.play(move);
        defer board.unplay(unMove);
        if (board.inCheck(colour)) return false;
    }
    return true;
}

// TODO: do all the offsets on i instead of on (x, y) since we know rooks/king are in start pos so can't wrap around board.
pub fn tryCastle(out: anytype, board: *Board, i: usize, file: usize, rank: usize, colour: Colour, comptime goingLeft: bool) !void {
    const cI: usize = if (colour == .White) 0 else 1;
    if (i != 4 + (cI * 8 * 7)) return; // TODO: redundant
    if (board.castling.get(colour, goingLeft)) {
        // TODO: can be a hard coded mask
        const pathClear = if (goingLeft)
            (board.emptyAtI(i - 1) and board.emptyAtI(i - 2) and board.emptyAtI(i - 3))
        else
            (board.emptyAtI(i + 1) and board.emptyAtI(i + 2));

        if (pathClear) {
            // TODO: do this later like other check checks. That way don't need to do the expensive check if it gets pruned out. Probably won't save much since you generally want to castle anyway.
            if (!try castlingIsLegal(board, i, colour, goingLeft)) return;

            const kingFrom: u6 = @intCast(rank * 8 + file);
            const kingTo: u6 = if (goingLeft) @intCast(rank * 8 + (file - 2)) else @intCast(rank * 8 + (file + 2));
            const rookFrom: u6 = if (goingLeft) @intCast(rank * 8) else @intCast((rank + 1) * 8 - 1);
            const rookTo: u6 = if (goingLeft) @intCast(rank * 8 + (file - 1)) else @intCast(rank * 8 + (file + 1));
            assert(board.squares[kingFrom].is(colour, .King));
            assert(board.squares[kingTo].empty());
            assert(board.squares[rookFrom].is(colour, .Rook));
            assert(board.squares[rookTo].empty());
            const move: Move = .{ .from = kingFrom, .to = kingTo, .action = .{ .castle = .{
                .rookFrom = rookFrom,
                .rookTo = rookTo,
            } }, .isCapture = false };
            try out.append(move);
        }
    }
}

fn knightMove(out: anytype, board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    if (rank < 6) {
        if (file < 7) try out.tryHop(board, i, file + 1, rank + 2, piece);
        if (file > 0) try out.tryHop(board, i, file - 1, rank + 2, piece);
    }
    if (rank > 1) {
        if (file < 7) try out.tryHop(board, i, file + 1, rank - 2, piece);
        if (file > 0) try out.tryHop(board, i, file - 1, rank - 2, piece);
    }

    if (file < 6) {
        if (rank < 7) try out.tryHop(board, i, file + 2, rank + 1, piece);
        if (rank > 0) try out.tryHop(board, i, file + 2, rank - 1, piece);
    }
    if (file > 1) {
        if (rank < 7) try out.tryHop(board, i, file - 2, rank + 1, piece);
        if (rank > 0) try out.tryHop(board, i, file - 2, rank - 1, piece);
    }
}

const directions = [8] [2] isize {
    [2] isize { 1, 0 },
    [2] isize { -1, 0 },
    [2] isize { 0, 1 },
    [2] isize { 0, -1 },
    [2] isize { 1, 1 },
    [2] isize { 1, -1 },
    [2] isize { -1, 1 },
    [2] isize { -1, -1 },
};

const CollectMoves = struct {
    moves: *std.ArrayList(Move),
    comptime filter: MoveFilter = .Any,

    fn tryHop(self: CollectMoves, board: *const Board, i: usize, checkFile: usize, checkRank: usize, piece: Piece) !void {
        const check = board.get(checkFile, checkRank);
        switch (self.filter) {
            .Any => {},
            .CapturesOnly => if (check.empty()) return,
            .KingCapturesOnly => if (check.kind != .King) return,
        }

        if (check.empty() or check.colour != piece.colour) {
            try self.moves.append(irf(i, checkFile, checkRank, !check.empty()));
        }
    }

    // Returns true if this move was a capture or blocked by self so loop should break.
    fn trySlide(self: CollectMoves, board: *const Board, i: usize, checkFile: usize, checkRank: usize, piece: Piece) !bool {
        return trySlide2(self, board, @intCast(i), @intCast(checkRank*8 + checkFile), piece);
    }

    fn trySlide2(self: CollectMoves, board: *const Board, fromIndex: u6, toIndexx: u6, piece: Piece) !bool {
        switch (self.filter) {
            .Any => {},
            .CapturesOnly => if (board.squares[toIndexx].empty() or board.squares[toIndexx].colour == piece.colour) return !board.squares[toIndexx].empty(),
            .KingCapturesOnly => if (board.squares[toIndexx].kind != .King) return !board.squares[toIndexx].empty(),
        }

        var mine: u64 = undefined;
        var other: u64 = undefined;
        switch (piece.colour) {
            .White => {
                mine = board.peicePositions.white;
                other = board.peicePositions.black;
            },
            .Black => {
                mine = board.peicePositions.black;
                other = board.peicePositions.white;
            },
        }

        const toFlag = @as(u64, 1) << toIndexx;
        if ((toFlag & mine) != 0) { // trying to move onto my piece
            return true;
        }

        if ((toFlag & other) != 0) { // taking an enemy piece
            var toPush = ii(fromIndex, toIndexx, true);

            // Have this be a comptime param that gets passed down so I can easily benchmark.
            // This is a capture, we like that, put it first. Capturing more valuable pieces is also good.
            for (self.moves.items, 0..) |move, index| {
                const holding = board.squares[toPush.to].kind.material();
                const lookingAt = board.squares[move.to].kind.material();
                if (holding == 0) break;
                if (holding > lookingAt) {
                    self.moves.items[index] = toPush;
                    toPush = move;
                }
            }

            try self.moves.append(toPush);
            return true;
        }

        // moving to empty square
        try self.moves.append(ii(fromIndex, toIndexx, false));
        return false;
    }

    pub fn pawnForwardTwo(self: CollectMoves, fromIndex: usize, toFile: usize, toRank: usize) !void {
        // std.debug.assert(fromIndex < 64 and toFile < 8 and toRank < 8);
        const move: Move = .{ .from = @intCast(fromIndex), .to = @intCast(toRank * 8 + toFile), .action = .allowFrenchMove, .isCapture = false, .bonus = Magic.PUSH_PAWN * 2 };
        try self.moves.append(move);
    }

    pub fn append(self: CollectMoves, move: Move) !void {
        try self.moves.append(move);
    }

    pub fn appendPawn(self: CollectMoves, move: Move) !void {
        try self.moves.append(move);
    }

    pub fn pawnAttack(self: CollectMoves, board: *const Board, fromIndex: usize, toFile: usize, toRank: usize, colour: Colour) !void {
        if (!board.emptyAt(toFile, toRank) and board.get(toFile, toRank).colour != colour) try self.maybePromote(board, fromIndex, toFile, toRank, colour);
    }

    fn maybePromote(self: CollectMoves, board: *const Board, fromIndex: usize, toFile: usize, toRank: usize, colour: Colour) !void {
        // TODO: including promotions on fast path should be seperate option
        const check = board.get(toFile, toRank);

        switch (self.filter) {
            .Any => {},
            .CapturesOnly => if (check.kind == .Empty or check.colour == colour) return,
            .KingCapturesOnly => if (check.kind != .King or check.colour == colour) return,
        }

        if ((colour == .Black and toRank == 0) or (colour == .White and toRank == 7)) {
            var move: Move = .{ .from = @intCast(fromIndex), .to = @intCast(toRank * 8 + toFile), .action = .{ .promote = .Queen }, .isCapture = !check.empty() and check.colour != colour, .bonus = Magic.PUSH_PAWN };
            // Queen promotions are so good that we don't even care about preserving order of the old stuff.
            // TODO: that's wrong cause mate
            if (self.moves.items.len > 0) {
                try self.moves.append(self.moves.items[0]);
                self.moves.items[0] = move;
            } else {
                try self.moves.append(move);
            }

            // Technically you might want a knight but why ever anything else? For correctness (avoiding draws?) still want to consider everything.
            const options = [_]Kind{ .Knight, .Rook, .Bishop };
            for (options) |k| {
                move.action = .{ .promote = k };
                try self.moves.append(move);
            }
        } else {
            try self.moves.append(irfPawn(fromIndex, toFile, toRank, !check.empty() and check.colour != colour));
        }
    }
};

fn toMask(f: usize, r: usize) u64 {
    const i = r*8 + f;
    return @as(u64, 1) << @intCast(i);
}


test "attacking" {
    var out: GetAttackSquares = .{};
    var game = Board.initial();
    try genPossibleMoves(&out, &game, .White, std.testing.failing_allocator);
    printBitBoard(out.bb);
}

pub const GetAttackSquares = struct {
    bb: u64 = 0,
    comptime filter: MoveFilter = .Any,  // TODO: remove
    
    // This masks out your own squares. 
    pub fn getBB(self: *GetAttackSquares, board: *const Board, colour: Colour) u64 {
        return self.bb & ~board.peicePositions.getFlag(colour);
    }

    fn tryHop(self: *GetAttackSquares, board: *const Board, i: usize, checkFile: usize, checkRank: usize, piece: Piece) !void {
        _ = piece;
        _ = i;
        _ = board;
        self.bb |= toMask(checkFile, checkRank);
    }

    // Returns true if this move was a capture or blocked by self so loop should break.
    fn trySlide(self: *GetAttackSquares, board: *const Board, i: usize, checkFile: usize, checkRank: usize, piece: Piece) !bool {
        _ = piece;
        _ = i;
        self.bb |= toMask(checkFile, checkRank);
        return !board.emptyAt(checkFile, checkRank);
    }

    fn trySlide2(self: *GetAttackSquares, board: *const Board, fromIndex: u6, toIndexx: u6, piece: Piece) !bool {
        _ = piece;
        _ = fromIndex;
        self.bb |= @as(u64, 1) << toIndexx;
        return !board.emptyAtI(toIndexx);
    }

    pub fn pawnForwardTwo(self: *GetAttackSquares, fromIndex: usize, toFile: usize, toRank: usize) !void {
        _ = toRank;
        _ = toFile;
        _ = fromIndex;
        _ = self;
    }

    pub fn append(self: *GetAttackSquares, move: Move) !void {
        self.bb |= @as(u64, 1) << move.to;
    }

    pub fn appendPawn(self: *GetAttackSquares, move: Move) !void {
        if (@mod(move.to, 8) == @mod(move.from, 8)) return;
        self.bb |= @as(u64, 1) << move.to;
    }

    pub fn pawnAttack(self: *GetAttackSquares, board: *const Board, fromIndex: usize, toFile: usize, toRank: usize, colour: Colour) !void {
        _ = fromIndex;
        _ = colour;
        _ = board;
        self.bb |= toMask(toFile, toRank);
    }

    fn maybePromote(self: *GetAttackSquares, board: *const Board, fromIndex: usize, toFile: usize, toRank: usize, colour: Colour) !void {
        _ = colour;
        _ = board;
        if (toFile == (@mod(fromIndex, 8))) return;
        self.bb |= toMask(toFile, toRank);
    }
};

pub fn slidingChecksBB(game: *Board, attackingPlayer: Colour) u64 {
    const mySquares = game.peicePositions.getFlag(attackingPlayer);
    const allSquares = game.peicePositions.white | game.peicePositions.black;
    const otherKingIndex = if (attackingPlayer == .White) game.blackKingIndex else game.whiteKingIndex;

    var resultFlag: u64 = 0;
    var flag: u64 = 1;
    for (0..64) |i| {
        defer flag <<= 1; 
        if ((flag & mySquares) == 0) continue;
        const kind = game.squares[i].kind;
        if (kind == .Pawn or kind == .King or kind == .Knight) continue;
        inline for (directions[0..8], 0..) |offset, dir| {
            const valid = !((dir < 4 and kind == .Bishop) or (dir >= 4 and kind == .Rook));
            if (valid) {
                var checkFile = @as(isize, @intCast(i % 8));
                var checkRank = @as(isize, @intCast(i / 8));
                var wipFlag: u64 = flag;
                while (true) {
                    checkFile += offset[0];
                    checkRank += offset[1];
                    if (checkFile > 7 or checkRank > 7 or checkFile < 0 or checkRank < 0) break;
                    const checkFlag = toMask(@intCast(checkFile), @intCast(checkRank));
                    const checkIndex = checkRank*8 + checkFile;
                    if (checkIndex == otherKingIndex) {
                        resultFlag |= wipFlag;
                        break;
                    }
                    if ((checkFlag & allSquares) != 0) break;
                    wipFlag |= checkFlag;
                }
            }
        }
    }

    return if (resultFlag == 0) ~resultFlag else resultFlag;
}

// TODO: this is bascilly a copy paste from the other one. could have all the move functions be generic over a function to call when you get each move.
pub fn reverseFromKingIsInCheck(game: *Board, me: Colour) bool {
    const i = if (me == .Black) (game.blackKingIndex) else (game.whiteKingIndex);
    const file = i % 8;
    const rank = i / 8;

    const isInCheck = check: {
        // Move like a rook
        if (file < 7) {
            for ((file + 1)..8) |checkFile| {
                if (!game.emptyAt(checkFile, rank)) {
                    const p = game.get(checkFile, rank);
                    if (p.colour == me) break;
                    if (p.kind == .Queen or p.kind == .Rook) {
                        break :check true;
                    } else break;
                }
            }
        }

        if (file > 0) {
            for (1..(file + 1)) |checkFile| {
                if (!game.emptyAt(file - checkFile, rank)) {
                    const p = game.get(file - checkFile, rank);
                    if (p.colour == me) break;
                    if (p.kind == .Queen or p.kind == .Rook) {
                        break :check true;
                    } else break;
                }
            }
        }

        if (rank < 7) {
            for ((rank + 1)..8) |checkRank| {
                if (!game.emptyAt(file, checkRank)) {
                    const p = game.get(file, checkRank);
                    if (p.colour == me) break;
                    if (p.kind == .Queen or p.kind == .Rook) {
                        break :check true;
                    } else break;
                }
            }
        }

        if (rank > 0) {
            for (1..(rank + 1)) |checkRank| {
                if (!game.emptyAt(file, rank - checkRank)) {
                    const p = game.get(file, rank - checkRank);
                    if (p.colour == me) break;
                    if (p.kind == .Queen or p.kind == .Rook) {
                        break :check true;
                    } else break;
                }
            }
        }

        // Move like a bishop
        {
            var checkFile = file;
            var checkRank = rank;
            while (checkFile < 7 and checkRank < 7) {
                checkFile += 1;
                checkRank += 1;
                if (!game.emptyAt(checkFile, checkRank)) {
                    const p = game.get(checkFile, checkRank);
                    if (p.colour == me) break;
                    if (p.kind == .Queen or p.kind == .Bishop) {
                        break :check true;
                    } else break;
                }
            }
        }

        {
            var checkFile = file;
            var checkRank = rank;
            while (checkFile > 0 and checkRank < 7) {
                checkFile -= 1;
                checkRank += 1;
                if (!game.emptyAt(checkFile, checkRank)) {
                    const p = game.get(checkFile, checkRank);
                    if (p.colour == me) break;
                    if (p.kind == .Queen or p.kind == .Bishop) {
                        break :check true;
                    } else break;
                }
            }
        }

        {
            var checkFile = file;
            var checkRank = rank;
            while (checkFile < 7 and checkRank > 0) {
                checkFile += 1;
                checkRank -= 1;
                if (!game.emptyAt(checkFile, checkRank)) {
                    const p = game.get(checkFile, checkRank);
                    if (p.colour == me) break;
                    if (p.kind == .Queen or p.kind == .Bishop) {
                        break :check true;
                    } else break;
                }
            }
        }

        {
            var checkFile = file;
            var checkRank = rank;
            while (checkFile > 0 and checkRank > 0) {
                checkFile -= 1;
                checkRank -= 1;
                if (!game.emptyAt(checkFile, checkRank)) {
                    const p = game.get(checkFile, checkRank);
                    if (p.colour == me) break; // my piece is safe and blocks
                    if (p.kind == .Queen or p.kind == .Bishop) { // your slider can attack me
                        break :check true;
                    } else break; // your non-slider keeps me safe from other sliders
                }
            }
        }

        // The other king
        const iOther = if (me == .Black) (game.whiteKingIndex) else (game.blackKingIndex);
        const fileOther = iOther % 8;
        const rankOther = iOther / 8;
        const fileDiff = @as(i32, @intCast(file)) - @as(i32, @intCast(fileOther));
        const rankDiff = @as(i32, @intCast(rank)) - @as(i32, @intCast(rankOther));
        if (fileDiff * fileDiff <= 1 and rankDiff * rankDiff <= 1) break :check true;

        // Pawns
        // Dont care about forward moves becasue they can't take.
        const onEdge = if (me == .White) rank == 7 else rank == 0;
        if (!onEdge) {
            const targetRank = switch (me) {
                .White => w: {
                    break :w rank + 1;
                },
                .Black => b: {
                    break :b rank - 1;
                },
            };

            if (file < 7 and game.get(file + 1, targetRank).kind == .Pawn and game.get(file + 1, targetRank).colour != me) { // right
                break :check true;
            }
            if (file > 0 and game.get(file - 1, targetRank).kind == .Pawn and game.get(file - 1, targetRank).colour != me) {
                break :check true;
            }
        }

        // Knights!

        if (rank < 6) {
            if (file < 7) {
                const p = game.get(file + 1, rank + 2);
                if (p.kind == .Knight and p.colour != me) break :check true;
            }

            if (file > 0) {
                const p = game.get(file - 1, rank + 2);
                if (p.kind == .Knight and p.colour != me) break :check true;
            }
        }
        if (rank > 1) {
            if (file < 7) {
                const p = game.get(file + 1, rank - 2);
                if (p.kind == .Knight and p.colour != me) break :check true;
            }

            if (file > 0) {
                const p = game.get(file - 1, rank - 2);
                if (p.kind == .Knight and p.colour != me) break :check true;
            }
        }

        if (file < 6) {
            if (rank < 7) {
                const p = game.get(file + 2, rank + 1);
                if (p.kind == .Knight and p.colour != me) break :check true;
            }

            if (rank > 0) {
                const p = game.get(file + 2, rank - 1);
                if (p.kind == .Knight and p.colour != me) break :check true;
            }
        }
        if (file > 1) {
            if (rank < 7) {
                const p = game.get(file - 2, rank + 1);
                if (p.kind == .Knight and p.colour != me) break :check true;
            }

            if (rank > 0) {
                const p = game.get(file - 2, rank - 1);
                if (p.kind == .Knight and p.colour != me) break :check true;
            }
        }

        break :check false;
    };
    return isInCheck;
}

// TODO: method that factors out bounds check from try methods then calls this? make sure not to do twice in slide loops.
pub fn irf(fromIndex: usize, toFile: usize, toRank: usize, isCapture: bool) Move {
    // std.debug.assert(fromIndex < 64 and toFile < 8 and toRank < 8);
    return .{ .from = @intCast(fromIndex), .to = @intCast(toRank * 8 + toFile), .action = .none, .isCapture = isCapture };
}

pub fn irfPawn(fromIndex: usize, toFile: usize, toRank: usize, isCapture: bool) Move {
    // std.debug.assert(fromIndex < 64 and toFile < 8 and toRank < 8);
    return .{ .from = @intCast(fromIndex), .to = @intCast(toRank * 8 + toFile), .action = .none, .isCapture = isCapture, .bonus = Magic.PUSH_PAWN };
}

pub fn ii(fromIndex: u6, toIndex: u6, isCapture: bool) Move {
    return .{ .from = fromIndex, .to = toIndex, .action = .none, .isCapture = isCapture };
}

pub fn printBitBoard(bb: u64) void {
    print("{b}\n", .{bb});
    var mask: u64 = @as(u64, 1) << 63;
    for (0..8) |_| {
        print("|", .{});
        for (0..8) |_| {
            const char: u8 = if ((mask & bb) != 0) 'X' else ' ';
            print("{c}|", .{ char });
            mask >>= 1;
        }
       print("\n", .{});
    }
}
