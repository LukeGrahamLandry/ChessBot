//! Generating the list of possible moves for a position.

const std = @import("std");
const Learned = @import("learned.zig");
const print = @import("common.zig").print;
const assert = @import("common.zig").assert;
const panic = @import("common.zig").panic;
const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;
const StratOpts = @import("search.zig").StratOpts;
const Move = @import("board.zig").Move;
const tables = &@import("precalc.zig").tables;

pub fn possibleMoves(board: *const Board, me: Colour, lists: *ListPool) !ListPool.List {
    var moves = try lists.get();
    const out: CollectMoves = .{ .moves = &moves, .filter = .Any };
    try genPossibleMoves(out, board, me);
    return moves;
}

// TODO: test this. 
// TODO: does the peace search need special handling for being in check? 
pub fn capturesOnlyMoves(board: *Board, me: Colour, lists: *ListPool) !ListPool.List {
    // For non-king pieces blockSingleCheck already acts as a filter for target squares so can reuse that for this as well. 
    // For peace search 3, filtering this way instead of gening all moves and skipping captures is 1.25x as fast.
    const realSlidingChecks = board.checks.blockSingleCheck;
    defer board.checks.blockSingleCheck = realSlidingChecks;
    const otherPieces = if (board.nextPlayer == .White) board.peicePositions.black else board.peicePositions.white;
    board.checks.blockSingleCheck &= otherPieces;
    board.checks.kingGetCapturesOnly = true;
    defer board.checks.kingGetCapturesOnly = false;

    var moves = try lists.get();
    const out: CollectMoves = .{ .moves = &moves, .filter = .Any };
    try genPossibleMoves(out, board, me);
    return moves;
}

pub fn collectOnePieceMoves(board: *const Board, i: usize, lists: *ListPool) !ListPool.List {
    var moves = try lists.get();
    const out: CollectMoves = .{ .moves = &moves, .filter = .Any };
    try genOnePieceMoves(out, board, i);
    return moves;
}

pub fn genPossibleMoves(out: anytype, board: *const Board, me: Colour) !void {
    var mySquares = board.peicePositions.getFlag(me);
    if (out.filter != .CurrentlyCalcChecks) assert(me == board.nextPlayer);

    if (out.filter != .CurrentlyCalcChecks and board.checks.doubleCheck) { // must move king.
        const kingIndex = if (me == .White) board.whiteKingIndex else board.blackKingIndex;
        try kingMove(out, board, kingIndex, board.nextPlayer);
        return;
    }

    while (mySquares != 0) {
        const offset = @ctz(mySquares);
        var flag = @as(u64, 1) << @intCast(offset);
        mySquares = mySquares ^ flag;
        try genOnePieceMoves(out, board, offset);
    }
}

// Using something like this is temping because I spend a lot of time putting things in lists and often only look at the first.
// But that's only cause pruning is working which relies partly on having all the moves and putting the best at the front.
pub const MoveIter = struct {
    targets: u64,
    board: *const Board,
    lists: *ListPool,

    pub fn of(board: *const Board, me: Colour, lists: *ListPool) @This() {
        assert(me == board.nextPlayer);
        if (!board.checks.doubleCheck) {
            return .{ .board = board, .targets = board.peicePositions.getFlag(me), .lists = lists };
        } else { // must move king.
            const kingIndex = if (me == .White) board.whiteKingIndex else board.blackKingIndex;
            return .{ .board = board, .targets = @as(u64, 1) << @intCast(kingIndex), .lists = lists };
        }
    }

    pub fn next(self: *@This()) !?ListPool.List {
        if (self.targets != 0) {
            const offset = @ctz(self.targets);
            var flag = @as(u64, 1) << @intCast(offset);
            self.targets = self.targets ^ flag;

            var moves = try self.lists.get();
            const out: CollectMoves = .{ .moves = &moves, .filter = .Any };
            try genOnePieceMoves(out, self.board, offset);
            return moves;
        } else {
            return null;
        }
    }
};

const MoveFilter = enum {
    Any,
    CurrentlyCalcChecks,
};

// TODO: is it faster to have a bit board of each type of piece so you can do each kind all at once? 
pub fn genOnePieceMoves(out: anytype, board: *const Board, i: usize) !void {
    const piece = board.squares[i];
    switch (piece.kind) {
        .Pawn => try pawnMove(out, board, i, i % 8, i / 8, piece),
        .Bishop => try bishopSlide(out, board, i, piece.colour),
        .Knight => try knightMove(out, board, i, piece.colour),
        .Rook => try rookSlide(out, board, i, piece.colour),
        .King => try kingMove(out, board, i, piece.colour),
        .Queen => {
            try rookSlide(out, board, i, piece.colour);
            try bishopSlide(out, board, i, piece.colour);
        },
        .Empty => unreachable,
    }
}

fn rookSlide(out: anytype, board: *const Board, i: usize, colour: Colour) !void {
    try sliderMoves(out, board, i, colour, true);
}

fn bishopSlide(out: anytype, board: *const Board, i: usize, colour: Colour) !void {
    try sliderMoves(out, board, i, colour, false);
}

fn sliderMoves(out: anytype, board: *const Board, i: usize, colour: Colour, comptime isRook: bool) !void {
    // These aren't really branches. The function is generic over that param.
    const masksTable = if (isRook) &tables.rookMasks else &tables.bishopMasks;
    const targetsTable = if (isRook) &tables.rooks else &tables.bishops;
    const myPinKind = if (isRook) board.checks.pinsByRook else board.checks.pinsByBishop;
    const otherPinKind = if (isRook) board.checks.pinsByBishop else board.checks.pinsByRook;

    // When calculating danger squares the king can't move to,
    // - defended pieces count as targetable
    // - the king doesn't count as a blocker
    // - you don't care about pins
    // This being simpler is a win from using the lookup to generate all targets at once.
    // TODO: this should be a seperate function.
    if (comptime (out.filter == .CurrentlyCalcChecks)) {
        var pieces = board.peicePositions.black | board.peicePositions.white;
        const kingFlag = @as(u64, 1) << @intCast(if (colour == .Black) board.whiteKingIndex else board.blackKingIndex);
        pieces &= ~kingFlag;
        const mask = pieces & masksTable[i];
        const targets = targetsTable[i].get(mask);
        out.bb |= targets;
        return;
    }

    // If pinned by the other type of piece, you can't move at all.
    const startFlag = @as(u64, 1) << @intCast(i);
    if ((otherPinKind & startFlag) != 0) return;

    var pieces = board.peicePositions.black | board.peicePositions.white;

    const mask = pieces & masksTable[i];
    const myPieces = board.peicePositions.getFlag(colour);
    var targets = targetsTable[i].get(mask) & (~myPieces) & board.checks.blockSingleCheck;

    // If pinned by the same type of piece, you need to stay on the pin lines
    if ((myPinKind & startFlag) != 0) targets &= myPinKind;

    try emitMoves(out, board, i, targets, colour);
}

fn pawnMove(out: anytype, board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    const startFlag = @as(u64, 1) << @intCast(i);
    const rookPinned = (board.checks.pinsByRook & startFlag) != 0 and out.filter != .CurrentlyCalcChecks;
    const bishopPinned = (board.checks.pinsByBishop & startFlag) != 0 and out.filter != .CurrentlyCalcChecks;

    const targetRank = switch (piece.colour) {
        // Asserts can't have a pawn at the end in real games because it would have promoted.
        .White => w: {
            assert(rank < 7);
            if (!bishopPinned and out.filter == .Any and rank == 1 and board.emptyAt(file, 2) and board.emptyAt(file, 3)) { // forward two
                try pawnForwardTwo(out.moves, board, i, file, 3); // cant promote
            }
            break :w rank + 1;
        },
        .Black => b: {
            assert(rank > 0);
            if (!bishopPinned and out.filter == .Any and rank == 6 and board.emptyAt(file, 5) and board.emptyAt(file, 4)) { // forward two
                try pawnForwardTwo(out.moves, board, i, file, 4); // cant promote
            }
            break :b rank - 1;
        },
    };

    if (out.filter == .Any and board.emptyAt(file, targetRank)) { // forward
        try out.maybePromote(board, i, file, targetRank, piece.colour);
    }

    if (rookPinned) return;

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
    if (out.filter == .CurrentlyCalcChecks) return; // dont care, cant take kings.

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

            try out.moves.append(.{ .from = @intCast(i), .to = @intCast(endIndex), .action = .{ .useFrenchMove = @intCast(captureIndex) }, .isCapture = true });
        },
    }
}

fn kingMove(out: anytype, board: *const Board, i: usize, colour: Colour) !void {
    if (out.filter == .CurrentlyCalcChecks) {
        out.bb |= tables.kings[i];
        return;
    }

    // Kings can't be pinned or block pins, don't need to check.
    const myPieces = board.peicePositions.getFlag(colour);
    const targets = tables.kings[i] & (~myPieces) & (~board.checks.targetedSquares);
    if (board.checks.kingGetCapturesOnly){
        try emitMoves(out, board, i, targets & board.checks.blockSingleCheck, colour);
    } else {
        try emitMoves(out, board, i, targets, colour);
        try tryCastle(out, board, colour, true);
        try tryCastle(out, board, colour, false);
    }   
}

pub fn ff(i: anytype) u64 {
    return @as(u64, 1) << @as(u6, i);
}

// This wouldn't work for fisher random but that's not the universe we live in right now.
pub fn tryCastle(out: anytype, board: *const Board, colour: Colour, comptime goingLeft: bool) !void {
    if (out.filter == .CurrentlyCalcChecks) return;
    if (!board.castling.get(colour, goingLeft)) return;

    // Are there any pieces blocking us from castling?
    const shift: u6 = if (colour == .Black) 7 * 8 else 0;
    const leftNoChecks = comptime (ff(2) | ff(3) | ff(4));
    const rightNoChecks = comptime (ff(6) | ff(5) | ff(4));
    var pathFlag = (if (goingLeft) leftNoChecks else rightNoChecks) << shift;
    const leftNoPieces = comptime (ff(1) | ff(2) | ff(3));
    const rightNoPieces = comptime (ff(5) | ff(6));
    var emptyFlag = (if (goingLeft) leftNoPieces else rightNoPieces) << shift;
    const pieces = board.peicePositions.white | board.peicePositions.black;
    const bad = (pieces & emptyFlag) | (board.checks.targetedSquares & pathFlag);
    if (bad != 0) return;

    // Where would we be going?
    const kingFrom = shift + 4;
    const kingTo: u6 = shift + if (goingLeft) 2 else 6;
    const rookFrom: u6 = shift + if (goingLeft) 0 else 7;
    const rookTo: u6 = shift + if (goingLeft) 3 else 5;
    assert(board.squares[kingFrom].is(colour, .King));
    assert(board.squares[kingTo].empty());
    assert(board.squares[rookFrom].is(colour, .Rook));
    assert(board.squares[rookTo].empty());

    // Make the move.
    const move: Move = .{ .from = kingFrom, .to = kingTo, .action = .{ .castle = .{
        .rookFrom = rookFrom,
        .rookTo = rookTo,
    } }, .isCapture = false };
    try out.moves.append(move);
}

fn knightMove(out: anytype, board: *const Board, i: usize, colour: Colour) !void {
    if (out.filter == .CurrentlyCalcChecks) {
        out.bb |= tables.knights[i];
        return;
    }

    // Pinned knights can never move.
    const startFlag = @as(u64, 1) << @intCast(i);
    if (((board.checks.pinsByBishop | board.checks.pinsByRook) & startFlag) != 0) return;

    const myPieces = board.peicePositions.getFlag(colour);
    const targets = tables.knights[i] & (~myPieces) & board.checks.blockSingleCheck;

    try emitMoves(out, board, i, targets, colour);
}

fn emitMoves(out: anytype, board: *const Board, i: usize, _targets: u64, colour: Colour) !void {
    var targets = _targets;
    while (targets != 0) {
        const offset = @ctz(targets);
        var flag = @as(u64, 1) << @intCast(offset);
        targets = targets ^ flag;
        try addMoveOrdered(out.moves, board, @intCast(i), @intCast(offset), flag, colour);
    }
}

// The new lookup move gen doesn't need to be told when to stop sliders so this method can be simpler.
// This does not do any validation. The piece moving must not be a king and the target square must be legal.
// All this does is make the move and do the ordering trick of prefering captures.
// TODO: try just making the list and doing more complicated ordering like prefer capture string pieces with weak ones.
fn addMoveOrdered(moves: *ListPool.List, board: *const Board, fromIndex: u6, toIndexx: u6, toFlag: u64, colour: Colour) !void {
    const enemyPieces = if (colour == .White) board.peicePositions.black else board.peicePositions.white;

    if ((toFlag & enemyPieces) == 0) { // moving to empty square
        try moves.append(ii(fromIndex, toIndexx, false));
    } else { // taking an enemy piece. do move ordering for better prune.
        var toPush = ii(fromIndex, toIndexx, true);

        // Have this be a comptime param that gets passed down so I can easily benchmark.
        // This is a capture, we like that, put it first. Capturing more valuable pieces is also good.
        for (moves.items, 0..) |move, index| {
            const holding = board.squares[toPush.to].kind.material();
            const lookingAt = board.squares[move.to].kind.material();
            if (holding == 0) break;
            if (holding > lookingAt) {
                moves.items[index] = toPush;
                toPush = move;
            }
        }

        try moves.append(toPush);
        return;
    }
}

pub fn pawnForwardTwo(moves: *ListPool.List, board: *const Board, fromIndex: usize, toFile: usize, toRank: usize) !void {
    const toFlag = @as(u64, 1) << @intCast(toRank * 8 + toFile);
    const fromFlag = @as(u64, 1) << @intCast(fromIndex);
    if ((board.checks.blockSingleCheck & toFlag) == 0) return;
    if ((board.checks.pinsByRook & fromFlag) != 0 and (board.checks.pinsByRook & toFlag) == 0) return;

    const move: Move = .{ .from = @intCast(fromIndex), .to = @intCast(toRank * 8 + toFile), .action = .allowFrenchMove, .isCapture = false };
    try moves.append(move);
}

const directions = [8][2]isize{
    [2]isize{ 1, 0 },
    [2]isize{ -1, 0 },
    [2]isize{ 0, 1 },
    [2]isize{ 0, -1 },
    [2]isize{ 1, 1 },
    [2]isize{ 1, -1 },
    [2]isize{ -1, 1 },
    [2]isize{ -1, -1 },
};

// TODO: goal of the movegen adventure is get rid of this complicated struct because the functions know that one is just rying to colelct the bit map and they can deal with that more efficiently

const CollectMoves = struct {
    moves: *ListPool.List,
    comptime filter: MoveFilter = .Any,

    pub fn pawnAttack(self: CollectMoves, board: *const Board, fromIndex: usize, toFile: usize, toRank: usize, colour: Colour) !void {
        if (!board.emptyAt(toFile, toRank) and board.get(toFile, toRank).colour != colour) try self.maybePromote(board, fromIndex, toFile, toRank, colour);
    }

    // TODO: make sure queen goes first in list? test that
    fn maybePromote(self: CollectMoves, board: *const Board, fromIndex: usize, toFile: usize, toRank: usize, colour: Colour) !void {
        const toFlag = @as(u64, 1) << @intCast(toRank * 8 + toFile);
        if ((board.checks.blockSingleCheck & toFlag) == 0) return;
        const fromFlag = @as(u64, 1) << @intCast(fromIndex);

        // TODO: no and. can both be crushed it together into one bit thing?
        const rookPinned = (board.checks.pinsByRook & fromFlag) != 0;
        const bishopPinned = (board.checks.pinsByBishop & fromFlag) != 0;
        if (rookPinned and (board.checks.pinsByRook & toFlag) == 0) return;
        if (bishopPinned and (board.checks.pinsByBishop & toFlag) == 0) return;

        // TODO: including promotions on fast path should be seperate option
        const check = board.get(toFile, toRank);

        if ((colour == .Black and toRank == 0) or (colour == .White and toRank == 7)) {
            var move: Move = .{ .from = @intCast(fromIndex), .to = @intCast(toRank * 8 + toFile), .action = .{ .promote = .Queen }, .isCapture = !check.empty() and check.colour != colour };
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
            try addMoveOrdered(self.moves, board, @intCast(fromIndex), @intCast(toRank * 8 + toFile), toFlag, colour);
        }
    }
};

fn toMask(f: usize, r: usize) u64 {
    const i = r * 8 + f;
    return @as(u64, 1) << @intCast(i);
}

pub const GetAttackSquares = struct {
    /// Includes your own peices when they could be taken back. Places the other king can't move.
    bb: u64 = 0,
    comptime filter: MoveFilter = .CurrentlyCalcChecks,

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
    doubleCheck: bool = false, // 64 bit boolean sad padding noises but we never put this in an array
    // Where the enemy can attack. The king may not move here.
    // Note: this might not include captures that can't take kings like french move.
    targetedSquares: u64 = 0,

    // Pin lines like above but for enemy pawn that could have be captured en-passant but might reveal a check.
    frenchPinByBishop: u64 = 0,
    frenchPinByRook: u64 = 0,
    kingGetCapturesOnly: bool = false,
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
            const checkIndex = checkRank * 8 + checkFile;
            const kind = game.squares[@intCast(checkIndex)].kind;
            const isEnemy = (otherSquares & checkFlag) != 0;
            wipFlag |= checkFlag;
            if (isEnemy) {
                const isSlider = (kind == .Queen or ((dir < 4 and kind == .Rook) or (dir >= 4 and kind == .Bishop)));
                if (isSlider) {
                    if (lookingForPin) { // Found a pin. Can't move the friend from before.
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
                if (lookingForPin) break; // Two friendly in a row means we're safe
                // This piece might be pinned, so keep looking for an enemy behind us.
                lookingForPin = true;
            }
        }
    }

    // Knights. Can't be blocked, they just take up one square in the flag and must be captured.
    // This is the same speed as the loop but it looks simpler. 
    const knightTargets = tables.knights[myKingIndex] & game.knights.getFlag(defendingPlayer.other());
    if (knightTargets != 0 and (result.blockSingleCheck != 0 or @popCount(knightTargets) > 1)) {
        result.doubleCheck = true;
    }
    result.blockSingleCheck |= knightTargets; 

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

    result.targetedSquares = getTargetedSquares(game, defendingPlayer.other());

    if (result.doubleCheck) { // Must move king.
        result.blockSingleCheck = 0;
    } else {
        // Don't need to bother doing this if we we're in double check because king must move.
        switch (game.frenchMove) {
            .none => {
                // No french available so don't care.
            },
            .file => |file| {
                // It feels like you could also avoid this by checking if enemy is targeting thier own pawn but since a pawn from both sides moves it doesn't work.
                // TODO: could check bit map two out on either side and need to do more work if any of those hit.

                // If we don't have a pawn in position to take, there's no need to do more work to check if its pinned.
                const capturedPawnRank = if (defendingPlayer == .White) @as(usize, 4) else @as(usize, 3);
                const hasLeft = file > 0 and (game.get(file - 1, capturedPawnRank).is(defendingPlayer, .Pawn));
                const hasRight = file < 7 and (game.get(file + 1, capturedPawnRank).is(defendingPlayer, .Pawn));
                if (hasLeft or hasRight) {
                    getFrenchPins(game, defendingPlayer, file, &result);
                }
            },
        }

        if (result.blockSingleCheck == 0) { // Not in check.
            result.blockSingleCheck = ~result.blockSingleCheck;
        }
    }

    return result;
}

// TODO: this doesnt include french move because this used to just be for detecting checks.
pub fn getTargetedSquares(game: *Board, attacker: Colour) u64 {
    var out: GetAttackSquares = .{};
    // Can't fail because this consumer doesn't allocate memory
    genPossibleMoves(&out, game, attacker) catch @panic("unreachable alloc");
    return out.bb;
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
            const checkIndex = checkRank * 8 + checkFile;
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
                    if (kind == .Pawn) {
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

// TODO: barely used. just write the code.

pub fn irf(fromIndex: usize, toFile: usize, toRank: usize, isCapture: bool) Move {
    // std.debug.assert(fromIndex < 64 and toFile < 8 and toRank < 8);
    return .{ .from = @intCast(fromIndex), .to = @intCast(toRank * 8 + toFile), .action = .none, .isCapture = isCapture };
}

pub fn ii(fromIndex: u6, toIndex: u6, isCapture: bool) Move {
    return .{ .from = fromIndex, .to = toIndex, .action = .none, .isCapture = isCapture };
}

pub fn printBitBoard(bb: u64) void {
    print("{b}\n", .{bb});

    for (0..8) |i| {
        print("|", .{});
        for (0..8) |j| {
            const rank = 7 - i;
            const file = j;
            const mask: u64 = @as(u64, 1) << @intCast(rank * 8 + file);
            const char: u8 = if ((mask & bb) != 0) 'X' else ' ';
            print("{c}|", .{char});
        }
        print("\n", .{});
    }
}

pub const ListPool = AnyListPool(Move);
pub const BE_EVIL = true;
const ListType = if (BE_EVIL) UnsafeList else std.ArrayList;
const LIST_SIZE = 512;

pub fn AnyListPool(comptime element: type) type {
    return struct {
        lists: ListType(List),
        alloc: std.mem.Allocator,

        pub const List = ListType(element);
        const POOL_SIZE = 512;
        comptime { assert(!BE_EVIL or POOL_SIZE <= LIST_SIZE); }

        pub fn init(alloc: std.mem.Allocator) !@This() {
            var self: @This() = .{ .lists = try ListType(List).initCapacity(alloc, POOL_SIZE), .alloc = alloc };
            for (0..POOL_SIZE) |_| { // pre-allocate enough lists that we'll probably never need to make a new one. should be > the expected depth number.
                // If all 16 of your pieces were somehow a queen in the middle of the board with no other pieces blocking
                // (maybe they're magic 4th dimensional queens, idk), that's still only 448 moves. So 512 will never overflow.
                // I'm sure there's a smaller upper bound than that but also nobody cares.
                try self.lists.append(try List.initCapacity(self.alloc, LIST_SIZE));
            }
            return self;
        }

        /// Do not deinit the list! Return it to the pool with release
        pub fn get(self: *@This()) !List {
            if (BE_EVIL) {
                const hushdebugmode = self.lists.items[self.lists.items.len - 1];
                self.lists.items.len -= 1;
                return hushdebugmode;
            } else {
                if (self.lists.popOrNull()) |list| {
                    return list;
                } else {
                    return try List.initCapacity(self.alloc, LIST_SIZE);
                }
            }
        }

        // TODO: do i need to errdefer this in functions that return one or is it already too messed up to recover if an allocation fails.
        // Can't defer a 'try' so returning an error here is really annoying. 
        pub fn release(self: *@This(), list: List) void {
            self.lists.append(list) catch @panic("OOM releasing list."); // If this fails you made like way too many lists.
            self.lists.items[self.lists.items.len - 1].clearRetainingCapacity();
        }

        pub fn copyOf(self: *@This(), other: *const List) List {
            var new = try self.get();
            new.items.len = other.items.len;
            @memcpy(new.items, other.items);
            return new;
        }

        pub fn noneLost(self: @This()) bool {
            return self.lists.items.len == POOL_SIZE;
        }
    };
}

// This is a terrible idea but its also like 15% faster and probably fine.
// Very disappointing. Clearly a sign that I shouldn't be putting so many things in lists
// but not sure how to do that and still get move ordering.
// I also don't really understand how the overhead of ArrayList could be that makes a difference. 
// The capacity check should be the most predictable of branches. 
// TODO: Maybe cause its bigger so copying more when using the pool? 
fn UnsafeList(comptime element: type) type {
    return struct {
        items: []element,

        pub fn initCapacity(alloc: std.mem.Allocator, num: usize) !@This() {
            var self: @This() = .{ .items = try alloc.alloc(element, num) };
            self.clearRetainingCapacity();
            return self;
        }

        pub fn append(self: *@This(), e: element) !void {
            self.items.len += 1;
            self.items[self.items.len - 1] = e;
        }

        pub fn clearRetainingCapacity(self: *@This()) void {
            self.items.len = 0;
        }
    };
}
