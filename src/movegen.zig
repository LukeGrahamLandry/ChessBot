//! Generating the list of possible moves for a position.

const std = @import("std");
const Magic = @import("common.zig").Magic;
const print = @import("common.zig").print;
const assert = @import("common.zig").assert;
const panic = @import("common.zig").panic;
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
    CurrentlyCalcChecks,

    pub fn get(comptime self: MoveFilter) type {
        return struct {
            // Caller must return the list to the list pool. 
            pub fn possibleMoves(board: *Board, me: Colour, lists: *ListPool) !std.ArrayList(Move) {
                // assert(board.nextPlayer == me); // sanity. TODO: don't bother passing colour since the board knows?
                var moves = try lists.get();
                const out: CollectMoves = .{ .moves=&moves, .filter=self };
                try genPossibleMoves(out, board, me);

                if (@import("common.zig").debugCheckLegalMoves) {
                    for (moves.items) |move| {
                        const unMove = board.play(move);
                        if (board.slowInCheck(me)) {
                            board.unplay(unMove);
                            print("original position:\n", .{});
                            board.debugPrint();
                            panic("movegen gave illegal move {s}.", .{try move.text()});
                        } else {
                            board.unplay(unMove);
                        }
                    }
                }

                return moves;
            }

            pub fn collectOnePieceMoves(moves: *std.ArrayList(Move), board: *Board, i: usize, file: usize, rank: usize) !void {
                const out: CollectMoves = .{ .moves=moves, .filter=self };
                try genOnePieceMoves(out, board, i, file, rank);
            }
        };
    }
};

// Caller owns the returned slice.
pub fn genPossibleMoves(out: anytype, board: *Board, me: Colour) !void {
    const mySquares = board.peicePositions.getFlag(me);
    // TODO: should really be asserting this. problematic becasue the gen target squares uses these methods as part of creating the check info
    // assert(me == board.nextPlayer);

    if (out.filter != .CurrentlyCalcChecks and board.checks.doubleCheck) {  // must move king. 
        const kingIndex = if (me == .White) board.whiteKingIndex else board.blackKingIndex;
        try kingMove(out, board, kingIndex, kingIndex % 8, kingIndex / 8, board.squares[kingIndex]);
        return;
    }

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
    // If pinned by a bishop, you can't move straight. 
    const startFlag = @as(u64, 1) << @intCast(i);
    if (out.filter != .CurrentlyCalcChecks) {
        if ((board.checks.pinsByBishop & startFlag) != 0) return;
    }

    const startPinned = (board.checks.pinsByRook & startFlag) != 0;
    inline for (directions[0..4]) |offset| {
        var checkFile = @as(isize, @intCast(file));
        var checkRank = @as(isize, @intCast(rank));
        while (true) {
            checkFile += offset[0];
            checkRank += offset[1];
            if (checkFile > 7 or checkRank > 7 or checkFile < 0 or checkRank < 0) break;
            // TODO: can i check this once by direction?
            // If pinned by a rook, you need to stay on the pin lines
            if (out.filter != .CurrentlyCalcChecks) {
                const toFlag = @as(u64, 1) << @intCast(checkRank*8 + checkFile);
                const endPinned = (board.checks.pinsByRook & toFlag) != 0;
                if (startPinned and !endPinned) break;
                if ((board.checks.blockSingleCheck & toFlag) == 0) {
                    if (board.emptyAt(@intCast(checkFile), @intCast(checkRank))) {
                        continue;
                    } else {
                        break;
                    }
                }
            }
            // For calculating where the king isn't allowed to move, you need to keep going after hitting the king. 
            const skip = out.filter == .CurrentlyCalcChecks and board.get(@intCast(checkFile), @intCast(checkRank)).is(piece.colour.other(), .King);
            if (try out.trySlide(board, i, @intCast(checkFile), @intCast(checkRank), piece) and !skip) break;
        }
    }
}

fn pawnMove(out: anytype, board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    const startFlag = @as(u64, 1) << @intCast(i);
    const rookPinned = (board.checks.pinsByRook & startFlag) != 0 and out.filter != .CurrentlyCalcChecks;
    const bishopPinned = (board.checks.pinsByBishop & startFlag) != 0 and out.filter != .CurrentlyCalcChecks;

    // TODO: rook pin
    const targetRank = switch (piece.colour) {
        // Asserts can't have a pawn at the end in real games because it would have promoted.
        .White => w: {
            assert(rank < 7);
            if (!bishopPinned and out.filter == .Any and rank == 1 and board.emptyAt(file, 2) and board.emptyAt(file, 3)) { // forward two
                try out.pawnForwardTwo(board, i, file, 3); // cant promote
            }
            break :w rank + 1;
        },
        .Black => b: {
            assert(rank > 0);
            if (!bishopPinned and out.filter == .Any and rank == 6 and board.emptyAt(file, 5) and board.emptyAt(file, 4)) { // forward two
                try out.pawnForwardTwo(board, i, file, 4); // cant promote
            }
            break :b rank - 1;
        },
    };

    // TODO: rook pin
    if (out.filter == .Any and board.emptyAt(file, targetRank)) { // forward
        try out.maybePromote(board, i, file, targetRank, piece.colour);
    }

    if (rookPinned) return;
    
    // TODO: bishop pin
    if (file < 7) { // right
        try out.pawnAttack(board, i, file + 1, targetRank, piece.colour);
        // TODO: are these right?
        if (board.emptyAt(file + 1, targetRank)) try frenchMove(out, board, i, file + 1, targetRank, piece.colour);
    }
    if (file > 0) { // left
        try out.pawnAttack(board, i, file - 1, targetRank, piece.colour);
        if (board.emptyAt(file - 1, targetRank)) try frenchMove(out, board, i, file - 1, targetRank, piece.colour);
    }
}

fn frenchMove(out: anytype, board: *const Board, i: usize, targetFile: usize, targetRank: usize, colour: Colour) !void {
    // Most of the time you can't en-passant so make that case as fast as possible.
    switch (board.frenchMove) {
        .none => return,
        .file => |validTargetFile| {
            if (targetFile != validTargetFile) return;
            if ((colour == .White and targetRank != 5) or (colour == .Black and targetRank != 2)) return;
            const endIndex = targetRank * 8 + targetFile;
            const captureIndex = ((if (colour == .White) targetRank - 1 else targetRank + 1) * 8) + targetFile;
            if (!board.squares[captureIndex].is(colour.other(), .Pawn)) return; // TODO: why isnt this always true?
            const toFlag = @as(u64, 1) << @intCast(endIndex);
            const captureFlag = @as(u64, 1) << @intCast(captureIndex);
            // Works because block**Single**Check so only one thing will be attacking. 
            if ((board.checks.blockSingleCheck & toFlag) == 0 and (board.checks.blockSingleCheck & captureFlag) == 0) return;
            const fromFlag = @as(u64, 1) << @intCast(i);
            
            // TODO: no and. can both be crushed it together into one bit thing? 

            // Normal pins
            const rookPinned = (board.checks.pinsByRook & fromFlag) != 0;
            const bishopPinned = (board.checks.pinsByBishop & fromFlag) != 0;
            if (rookPinned and (board.checks.pinsByRook & toFlag) == 0) return;
            if (bishopPinned and (board.checks.pinsByBishop & toFlag) == 0) return;

            // Fancy pins        
            const frenchRookPinned = (board.checks.frenchPinByRook & captureFlag) != 0;
            const frenchBishopPinned = (board.checks.frenchPinByBishop & captureFlag) != 0;
            if (frenchRookPinned and (board.checks.frenchPinByRook & toFlag) == 0) return;
            if (frenchBishopPinned and (board.checks.frenchPinByBishop & toFlag) == 0) return;

            // assert(board.squares[captureIndex].is(colour.other(), .Pawn));
            try out.appendPawn(.{ .from = @intCast(i), .to = @intCast(endIndex), .action = .{ .useFrenchMove = @intCast(captureIndex) }, .isCapture = true });
        },
    }
}

fn bishopSlide(out: anytype, board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    // If pinned by a rook, you can't move diagnally. 
    const startFlag = @as(u64, 1) << @intCast(i);
    if (out.filter != .CurrentlyCalcChecks) {
        if ((board.checks.pinsByRook & startFlag) != 0) return;
    }

    const startPinned = (board.checks.pinsByBishop & startFlag) != 0;
    inline for (directions[4..8]) |offset| {
        var checkFile = @as(isize, @intCast(file));
        var checkRank = @as(isize, @intCast(rank));
        while (true) {
            checkFile += offset[0];
            checkRank += offset[1];
            if (checkFile > 7 or checkRank > 7 or checkFile < 0 or checkRank < 0) break;
            // TODO: can i check this once by direction?
            // If pinned by a pishop, you need to stay on the pin lines
            if (out.filter != .CurrentlyCalcChecks) {
                const toFlag = @as(u64, 1) << @intCast(checkRank*8 + checkFile);
                const endPinned = (board.checks.pinsByBishop & toFlag) != 0;
                if (startPinned and !endPinned) break;
                if ((board.checks.blockSingleCheck & toFlag) == 0) {
                    if (board.emptyAt(@intCast(checkFile), @intCast(checkRank))) {
                        continue;
                    } else {
                        break;
                    }
                }
            }
            // For calculating where the king isn't allowed to move, you need to keep going after hitting the king. 
            const skip = out.filter == .CurrentlyCalcChecks and board.get(@intCast(checkFile), @intCast(checkRank)).is(piece.colour.other(), .King);
            if (try out.trySlide(board, i, @intCast(checkFile), @intCast(checkRank), piece) and !skip) break;
        }
    }
}

fn trySlideKing(out: anytype, board: *Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    const endFlag = @as(u64, 1) << @intCast(rank*8 + file);
    if (out.filter != .CurrentlyCalcChecks and (board.checks.targetedSquares & endFlag) != 0) return;
    _ = try out.trySlide(board, i, file, rank, piece);
}

// TODO: This is suck!
fn kingMove(out: anytype, board: *Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    // forward
    if (file < 7) {
        try trySlideKing(out, board, i, file + 1, rank, piece);
        if (rank < 7) try trySlideKing(out, board, i, file + 1, rank + 1, piece);
        if (rank > 0) try trySlideKing(out, board, i, file + 1, rank - 1, piece);
    }
    // back
    if (file > 0) {
        try trySlideKing(out, board, i, file - 1, rank, piece);
        if (rank < 7) try trySlideKing(out, board, i, file - 1, rank + 1, piece);
        if (rank > 0 )try trySlideKing(out, board, i, file - 1, rank - 1, piece);
    }
    // horizontal
    if (rank < 7) try trySlideKing(out, board, i, file, rank + 1, piece);
    if (rank > 0) try trySlideKing(out, board, i, file, rank - 1, piece);

    try tryCastle(out, board, i, file, rank, piece.colour, true);
    try tryCastle(out, board, i, file, rank, piece.colour, false);
}

// TODO: move this into tryCastle and use the same mask for checking empty squares
fn castlingIsLegal(out: anytype, board: *Board, i: usize, colour: Colour, comptime goingLeft: bool) !bool {
    _ = colour;
    if (out.filter == .CurrentlyCalcChecks) return false;
    // Note this test doesn't go all the way to the rook on the left, its allowed to go through check!
    // TODO: THIS SHOULD NOT HAVE JUMPS. just build the mask, we know where the king is if it can castle!
    const path = if (goingLeft) [_]u64{ i, i - 1, i - 2 } else [_]u64{ i, i + 1, i + 2 };
    var flag: u64 = 0;
    for (path) |sq| {
        flag |= @as(u64, 1) << @intCast(sq);
    }
    return (board.checks.targetedSquares & flag) == 0;
}

// TODO: do all the offsets on i instead of on (x, y) since we know rooks/king are in start pos so can't wrap around board.
pub fn tryCastle(out: anytype, board: *Board, i: usize, file: usize, rank: usize, colour: Colour, comptime goingLeft: bool) !void {
    if (out.filter == .CurrentlyCalcChecks) return;
    const cI: usize = if (colour == .White) 0 else 1;
    if (i != 4 + (cI * 8 * 7)) return; // TODO: redundant
    if (board.castling.get(colour, goingLeft)) {
        // TODO: can be a hard coded mask
        const pathClear = if (goingLeft)
            (board.emptyAtI(i - 1) and board.emptyAtI(i - 2) and board.emptyAtI(i - 3))
        else
            (board.emptyAtI(i + 1) and board.emptyAtI(i + 2));

        if (pathClear) {
            if (!try castlingIsLegal(out, board, i, colour, goingLeft)) return;

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
    // Pinned knights can never move. 
    if (out.filter != .CurrentlyCalcChecks) {  // TODO: get rid of this check everywhere by setting the checks info to 0/1 so it gets ignored 
        const flag = @as(u64, 1) << @intCast(i);
        if (((board.checks.pinsByBishop | board.checks.pinsByRook) & flag) != 0) return;
    }

    inline for (knightOffsets) |x| {
        inline for (knightOffsets) |y| {
            if (x != y and x != -y) {
                var checkFile = @as(isize, @intCast(file)) + x;
                var checkRank = @as(isize, @intCast(rank)) + y;
                const invalid = checkFile > 7 or checkRank > 7 or checkFile < 0 or checkRank < 0;
                if (!invalid) {
                    const toFlag = @as(u64, 1) << @intCast(checkRank*8 + checkFile);
                    const skip = out.filter != .CurrentlyCalcChecks and (board.checks.blockSingleCheck & toFlag) == 0;
                    if (!skip) try out.tryHop(board, i, @intCast(checkFile), @intCast(checkRank), piece);
                }
            }
        }
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

const knightOffsets = [4] isize { 1, -1, 2, -2 };

const CollectMoves = struct {
    moves: *std.ArrayList(Move),
    filter: MoveFilter = .Any,

    fn tryHop(self: CollectMoves, board: *const Board, i: usize, checkFile: usize, checkRank: usize, piece: Piece) !void {
        const check = board.get(checkFile, checkRank);
        switch (self.filter) {
            .Any, .CurrentlyCalcChecks => {},
            .CapturesOnly => if (check.empty()) return,
            .KingCapturesOnly => if (check.kind != .King) return,
        }

        const toFlag = @as(u64, 1) << @intCast(checkRank*8 + checkFile);
        if (self.filter != .CurrentlyCalcChecks and (board.checks.blockSingleCheck & toFlag) == 0) return;

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
            .Any, .CurrentlyCalcChecks => {},
            .CapturesOnly => if (board.squares[toIndexx].empty() or board.squares[toIndexx].colour == piece.colour) return !board.squares[toIndexx].empty(),
            .KingCapturesOnly => if (board.squares[toIndexx].kind != .King) return !board.squares[toIndexx].empty(),
        }

        const anyPieces = board.peicePositions.white | board.peicePositions.black;
        const toFlag = @as(u64, 1) << toIndexx;
        // TODO: king should call other method so no branch
        if (self.filter != .CurrentlyCalcChecks) {
            if (piece.kind != .King and (board.checks.blockSingleCheck & toFlag) == 0) {
                return (anyPieces & toFlag) != 0;
            }
            if (piece.kind == .King and (board.checks.targetedSquares & toFlag) != 0) return (anyPieces & toFlag) != 0;
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

    pub fn pawnForwardTwo(self: CollectMoves, board: *const Board, fromIndex: usize, toFile: usize, toRank: usize) !void {
        // std.debug.assert(fromIndex < 64 and toFile < 8 and toRank < 8);
        const toFlag = @as(u64, 1) << @intCast(toRank*8 + toFile);
        const fromFlag = @as(u64, 1) << @intCast(fromIndex);
        if ((board.checks.blockSingleCheck & toFlag) == 0) return;
        if ((board.checks.pinsByRook & fromFlag) != 0 and (board.checks.pinsByRook & toFlag) == 0) return;
        
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
        if (self.filter != .CurrentlyCalcChecks) {
            const toFlag = @as(u64, 1) << @intCast(toRank*8 + toFile);
            if ((board.checks.blockSingleCheck & toFlag) == 0) return;
            const fromFlag = @as(u64, 1) << @intCast(fromIndex);

            // TODO: no and. can both be crushed it together into one bit thing? 
            const rookPinned = (board.checks.pinsByRook & fromFlag) != 0;
            const bishopPinned = (board.checks.pinsByBishop & fromFlag) != 0;
            if (rookPinned and (board.checks.pinsByRook & toFlag) == 0) return;
            if (bishopPinned and (board.checks.pinsByBishop & toFlag) == 0) return;
        }

        // TODO: including promotions on fast path should be seperate option
        const check = board.get(toFile, toRank);

        switch (self.filter) {
            .Any, .CurrentlyCalcChecks => {},
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

pub const GetAttackSquares = struct {
    /// Includes your own peices when they could be taken back. Places the other king can't move. 
    bb: u64 = 0,
    comptime filter: MoveFilter = .CurrentlyCalcChecks,

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

    pub fn pawnForwardTwo(self: *GetAttackSquares, board: *const Board, fromIndex: usize, toFile: usize, toRank: usize) !void {
        _ = board;
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

pub const ChecksInfo = struct { 
    // If not in check: all ones. 
    // If in single check: a piece must move TO one of these squares OR the king must move to a safe square. 
    // Includes the enemy (even a single knight) because capturing is fine. 
    blockSingleCheck: u64 = 0, 
    // Your peices may not move FROM these squares because they will reveal a check from an enemy slider. 
    // Directions must be tracked seperatly because you can move along the pin axis. It works out so they never overlaop and let you move between pins.
    pinsByRook: u64 = 0,
    pinsByBishop: u64 = 0,
    // If true, the king must move to a safe square, because multiple enemies can't be blocked/captured. 
    doubleCheck: bool = false,
    // Where the enemy can attack. The king may not move here. 
    targetedSquares: u64 = 0,

    // Pin lines like above but for enemy pawn that could have be captured en-passant but might reveal a check. 
    frenchPinByBishop: u64 = 0,
    frenchPinByRook: u64 = 0,
};

// TODO: This is super branchy. Maybe I could do better if I had bit boards of each piece type. 
// TODO: It would be very nice if I could update this iterativly as moves were made instead of recalculating every time. Feels almost possible? 
// TODO: split into more manageable functions. 
// TODO: dont call this on the leaf nodes fo the tree. the hope was that even if its slower, it moves the work up the tree a level. 
pub fn getChecksInfo(game: *Board, defendingPlayer: Colour) ChecksInfo {
    const mySquares = game.peicePositions.getFlag(defendingPlayer);
    const otherSquares = game.peicePositions.getFlag(defendingPlayer.other());
    const myKingIndex = if (defendingPlayer == .White) game.whiteKingIndex else game.blackKingIndex;

    var result: ChecksInfo = .{};

    // Queens, Rooks, Bishops and any resulting pins. 
    inline for (directions[0..8], 0..) |offset, dir| outer: {
        var checkFile = @as(isize, @intCast(myKingIndex % 8));
        var checkRank = @as(isize, @intCast(myKingIndex / 8));
        var wipFlag: u64 = 0;
        var lookingForPin = false;
        while (true) {
            checkFile += offset[0];
            checkRank += offset[1];
            if (checkFile > 7 or checkRank > 7 or checkFile < 0 or checkRank < 0) break;
            const checkFlag = toMask(@intCast(checkFile), @intCast(checkRank));
            const checkIndex = checkRank*8 + checkFile;
            const kind = game.squares[@intCast(checkIndex)].kind;
            const isEnemy = (otherSquares & checkFlag) != 0;
            wipFlag |= checkFlag;
            if (isEnemy) {
                const isSlider = (kind == .Queen or ((dir < 4 and kind == .Rook) or (dir >= 4 and kind == .Bishop)));
                if (isSlider) {
                    if (lookingForPin) {  // Found a pin. Can't move the friend from before.  
                        if (dir < 4) {
                            result.pinsByRook |= wipFlag;
                        } else {
                            result.pinsByBishop |= wipFlag;
                        }
                    } else {
                        if (result.blockSingleCheck != 0) {
                            result.doubleCheck = true; 
                            // Don't care about any other checks or pins. Just need to move king. 
                            break :outer;
                        }
                        result.blockSingleCheck |= wipFlag;
                    }
                }

                // Don't need to look for pins of enemy pieces. We're done this dir!
                break;
            }
            const isFriend = (mySquares & checkFlag) != 0;
            if (isFriend) {
                if (lookingForPin) break;  // Two friendly in a row means we're safe
                // This piece might be pinned, so keep looking for an enemy behind us.
                lookingForPin = true;
            }
        }
    }
    
    // Knights. Can't be blocked, they just take up one square in the flag and must be captured. 
    inline for (knightOffsets) |x| {
        inline for (knightOffsets) |y| {
            if (comptime (x != y and x != -y)) {
                var checkFile = @as(isize, @intCast(@mod(myKingIndex, 8))) + x;
                var checkRank = @as(isize, @intCast(@divFloor(myKingIndex, 8))) + y;
                const invalid = checkFile > 7 or checkRank > 7 or checkFile < 0 or checkRank < 0;
                if (!invalid){
                    const checkIndex = checkRank*8 + checkFile;
                    const p = game.squares[@intCast(checkIndex)];
                    if (p.colour == defendingPlayer.other() and p.kind == .Knight) {
                        if (result.blockSingleCheck == 0) {
                            result.blockSingleCheck |= @as(u64, 1) << @as(u6, @intCast(checkIndex));
                        } else {
                            result.doubleCheck = true;
                            // Want to break here but compiler seg faults. Not allowed in inline loops i guess? 
                        }
                    }
                }
            }
        }
    }

    // Pawns. Don't care about going forward or french move because those can't capture a king. 
    // They only move one so can't be blocked. 
    // TODO: this is kinda copy-paste-y
    var kingRank = @as(usize, @intCast(myKingIndex / 8));
    var kingFile = @as(usize, @intCast(myKingIndex % 8));
    const onEdge = if (defendingPlayer == .White) kingRank == 7 else kingRank == 0;
    if (!onEdge) {
        const targetRank = switch (defendingPlayer) {
            .White => w: {
                break :w kingRank + 1;
            },
            .Black => b: {
                break :b kingRank - 1;
            },
        };

        if (kingFile < 7 and game.get(kingFile + 1, targetRank).kind == .Pawn and game.get(kingFile + 1, targetRank).colour != defendingPlayer) { // right
            if (result.blockSingleCheck == 0) {
                const pawnIndex = targetRank * 8 + (kingFile + 1);
                result.blockSingleCheck |= @as(u64, 1) << @intCast(pawnIndex);
            } else {
                result.doubleCheck = true;
            }
        }
        if (kingFile > 0 and game.get(kingFile - 1, targetRank).kind == .Pawn and game.get(kingFile - 1, targetRank).colour != defendingPlayer) {
            if (result.blockSingleCheck == 0) {
                const pawnIndex = targetRank * 8 + (kingFile - 1);
                result.blockSingleCheck |= @as(u64, 1) << @intCast(pawnIndex);
            } else {
                result.doubleCheck = true;
            }
        }
    }

    // Can never be in check from the other king. Don't need to consider it. 


    var out: GetAttackSquares = .{};
    // Can't fail because this consumer doesn't allocate memory 
    genPossibleMoves(&out, game, defendingPlayer.other()) catch @panic("unreachable alloc");
    result.targetedSquares = out.bb;

    if (result.doubleCheck){  // Must move king. 
        result.blockSingleCheck = 0;
    } else {
        // Don't need to bother doing this if we we're in double check because king must move. 
        switch (game.frenchMove) {
            .none => {
                // No french available so don't care. 
            },
            .file => |file| {
                // TODO: another easy check to avoid work is see if the enemy is targeting its french pawn
                getFrenchPins(game, defendingPlayer, file, &result);
            }
        }

        if (result.blockSingleCheck == 0) {  // Not in check. 
            result.blockSingleCheck = ~result.blockSingleCheck;
        }
    }

    return result;
}

// TODO: This is fricken branch town. Is there a better way to do this? 
pub fn getFrenchPins(game: *Board, defendingPlayer: Colour, frenchFile: u4, result: *ChecksInfo) void {
    const mySquares = game.peicePositions.getFlag(defendingPlayer);
    const otherSquares = game.peicePositions.getFlag(defendingPlayer.other());
    const myKingIndex = if (defendingPlayer == .White) game.whiteKingIndex else game.blackKingIndex;
    const capturedPawnRank = if (defendingPlayer == .White) @as(u64, 4) else @as(u64, 3);

    // TODO: checking all directions seems silly, should only look towards the pawn. 
    // TODO: before the loop, check if I have any pawns in the right squares to capture. because it actually happening is rare 
    inline for (directions[0..8], 0..) |offset, dir| {
        var checkFile = @as(isize, @intCast(myKingIndex % 8));
        var checkRank = @as(isize, @intCast(myKingIndex / 8));
        var wipFlag: u64 = 0;
        var lookingForPin = false;
        var sawAPotentialFrenchFriend = false;
        while (true) {
            checkFile += offset[0];
            checkRank += offset[1];
            if (checkFile > 7 or checkRank > 7 or checkFile < 0 or checkRank < 0) break;
            const checkFlag = toMask(@intCast(checkFile), @intCast(checkRank));
            const checkIndex = checkRank*8 + checkFile;
            const kind = game.squares[@intCast(checkIndex)].kind;
            const isEnemy = (otherSquares & checkFlag) != 0;
            wipFlag |= checkFlag;
            if (isEnemy) {
                if (lookingForPin) {
                    const isSlider = (kind == .Queen or ((dir < 4 and kind == .Rook) or (dir >= 4 and kind == .Bishop)));
                    if (isSlider) { 
                        // ok heck, we're pinned! 
                        if (dir < 4) {
                            result.frenchPinByRook |= wipFlag;
                        } else {
                            result.frenchPinByBishop |= wipFlag;
                        }
                    } else {
                        // hit something that blocks but can't slide so don't care any move
                        break;
                    }
                } else {
                    if (kind == .Pawn){
                        if (checkRank == capturedPawnRank and checkFile == frenchFile) {
                            lookingForPin = true;
                            // this is the pawn we care about and we didn't see anything blocking line of sight so keep looking for sliders. 
                            continue;
                        } else { 
                            // wrong pawn. dont care
                            break;
                        }
                    } else {
                        // We didn't hit the french target pawn so don't care. 
                        break;
                    }
                }
            }
            const isFriend = (mySquares & checkFlag) != 0;
            if (isFriend) {
                const isLeft = frenchFile > 0 and (frenchFile - 1 == checkFile);
                const isRight = frenchFile < 7 and (frenchFile + 1 == checkFile);

                if (kind == .Pawn and checkRank == capturedPawnRank and (isLeft or isRight)) {
                    // this is our pawn that would move
                    if (sawAPotentialFrenchFriend) { // this is our second time here, we block ourselves, so its fine
                        break;
                    } else {
                        sawAPotentialFrenchFriend = true;
                        // need to keep looking to see if we're pinned
                        continue;
                    }
                } else {
                    // otherwise, it can't be a french pin, dont care. 
                    break;  
                }
            }
        }
    }
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
   
    for (0..8) |i| {
        print("|", .{});
        for (0..8) |j| {
            const rank = 7-i;
            const file = j;
            const mask: u64 = @as(u64, 1) << @intCast(rank*8+file);
            const char: u8 = if ((mask & bb) != 0) 'X' else ' ';
            print("{c}|", .{ char });
        }
       print("\n", .{});
    }
}

pub const ListPool = struct {
    lists: std.ArrayList(std.ArrayList(Move)),
    alloc: std.mem.Allocator,
    count: usize = 0,

    pub fn init(alloc: std.mem.Allocator) !ListPool {
        var self: ListPool = .{ .lists = std.ArrayList(std.ArrayList(Move)).init(alloc), .alloc=alloc };
        for (0..10) |_| { // pre-allocate enough lists that we'll probably never need to make a new one. should be the expected depth number. 
            try self.lists.append(try std.ArrayList(Move).initCapacity(self.alloc, 128));
            self.count += 1;
        }
        return self;
    }

    // Do not deinit the list! Return it to the pool with release
    pub fn get(self: *ListPool) !std.ArrayList(Move) {
        // TODO: if i made a more confident upper bound up front I wouldn't need this check. 
        if (self.lists.popOrNull()) |list| {
            return list;
        } else {
            print("Make new list for pool. {}\n", .{ self.count });
            self.count += 1;
            return try std.ArrayList(Move).initCapacity(self.alloc, 128);  // this could be bigger
        }
    }

    pub fn release(self: *ListPool, list: std.ArrayList(Move)) void {
        self.lists.append(list) catch @panic("OOM releasing list.");
        self.lists.items[self.lists.items.len - 1].clearRetainingCapacity();
    }
};
