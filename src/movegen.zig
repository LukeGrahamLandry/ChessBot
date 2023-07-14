const std = @import("std");
// const assert = std.debug.assert;

fn assert(val: bool) void {
    // if (val) @panic("lol nope");
    std.debug.assert(val);
}

const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;
const StratOpts = @import("moves.zig").StratOpts;
const Move = @import("moves.zig").Move;

pub const MoveFilter = enum {
    Any, CapturesOnly, KingCapturesOnly,

    pub fn get(comptime self: MoveFilter) type {
        return MoveGenStrategy(self);
    }
};

pub fn MoveGenStrategy(comptime filter: MoveFilter) type {
    return struct {  // Start Strategy. 

/// Positive means white is winning. 
pub fn simpleEval(game: *const Board) i32 {
    // TODO: Calls to this function are clearly not optimised away, idk what's going on. 
    // assert(game.simpleEval == slowSimpleEval(game));
    return game.simpleEval;
}

pub fn slowSimpleEval(game: *const Board) i32 {
    var result: i32 = 0;
    for (game.squares) |piece| {
        switch (piece.colour) {
            .White => result += piece.kind.material(),
            else => result -= piece.kind.material(),
        }
    }
    return result;
}

fn toIndex(file: usize, rank: usize) u6  {
    return @intCast(rank*8 + file);
}

const one: u64 = 1;
// Caller owns the returned slice.
pub fn possibleMoves(board: *Board, me: Colour, alloc: std.mem.Allocator) ![] Move {
    assert(board.nextPlayer == me);  // sanity. TODO: don't bother passing colour since the board knows?
    var moves = try std.ArrayList(Move).initCapacity(alloc, 50);
    const mySquares = switch (me) {
            .White => board.peicePositions.white,
            .Black => board.peicePositions.black,
        };
    
    assert(board.hasCorrectPositionsBits());
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
        try collectOnePieceMoves(&moves, board, i, file, rank);
    }

    // TODO: make sure this isn't reallocating 
    return try moves.toOwnedSlice();
}

pub fn collectOnePieceMoves(moves: *std.ArrayList(Move), board: *Board, i: usize, file: usize, rank: usize) !void {
    const piece = board.squares[i];
    switch (piece.kind) {
        .Pawn => try pawnMove(moves, board, i, file, rank, piece),
        .Bishop => try bishopSlide(moves, board, i, file, rank, piece),
        .Knight => try knightMove(moves, board, i, file, rank, piece),
        .Rook => try rookSlide(moves, board, i, file, rank, piece),
        .King => try kingMove(moves, board, i, file, rank, piece),
        .Queen => {
            try rookSlide(moves, board, i, file, rank, piece);
            try bishopSlide(moves, board, i, file, rank, piece);
        },
        .Empty => unreachable,
    }
}

fn rookSlide(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    _ = file;

    inline for (. { 8, -8 }) |dir| {
        var pos: i32 = @intCast(i);
        for (0..8) |_| {
            pos += dir;
            if (pos < 0 or pos > 63) break;
            if (try trySlide2(moves, board, @intCast(i), @intCast(pos), piece)) break;
        }
    }

    const min = rank * 8;
    const max = (rank + 1) * 8;
    inline for ( .{ 1, -1 }) |dir| {
        var pos: i32 = @intCast(i);
        for (0..8) |_| {
            pos += dir;
            if (pos < min or pos >= max) break;
            if (try trySlide2(moves, board, @intCast(i), @intCast(pos), piece)) break;
        }
    }
}

pub fn pawnForwardTwo(fromIndex: usize, toFile: usize, toRank: usize, isCapture: bool) Move {
    // std.debug.assert(fromIndex < 64 and toFile < 8 and toRank < 8);
    return .{
        .from=@intCast(fromIndex),
        .to = @intCast(toRank*8 + toFile),
        .action = .allowFrenchMove,
        .isCapture=isCapture
    };
}

fn pawnMove(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    const targetRank = switch (piece.colour) {
        // Asserts can't have a pawn at the end in real games because it would have promoted. 
        .White => w: {
            assert(rank < 7);  
            if (filter == .Any and rank == 1 and board.emptyAt(file, 2) and board.emptyAt(file, 3)) {  // forward two
                try moves.append(pawnForwardTwo(i, file, 3, false));  // cant promote
            }
            break :w rank + 1;
        },
        .Black => b: {
            assert(rank > 0);
            if (filter == .Any and rank == 6 and board.emptyAt(file, 5) and board.emptyAt(file, 4)) {  // forward two
                try moves.append(pawnForwardTwo(i, file, 4, false));  // cant promote
            }
            break :b rank - 1;
        }
    };

    if (filter == .Any and board.emptyAt(file, targetRank)) {  // forward
        try maybePromote(moves, board, i, file, targetRank, piece.colour);
    }
    if (file < 7) {  // right
        if (!board.emptyAt(file + 1, targetRank)){
            if (board.get(file + 1, targetRank).colour != piece.colour) try maybePromote(moves, board, i, file + 1, targetRank, piece.colour);
        } else {
            try frenchMove(moves, board, i, file + 1, targetRank, piece.colour);
        }
        
    }
    if (file > 0) {  // left
        if (!board.emptyAt(file - 1, targetRank)){
            if (board.get(file - 1, targetRank).colour != piece.colour) try maybePromote(moves, board, i, file - 1, targetRank, piece.colour);
        } else {
            try frenchMove(moves, board, i, file - 1, targetRank, piece.colour);
        }
    }
}

fn frenchMove(moves: *std.ArrayList(Move), board: *const Board, i: usize, targetFile: usize, targetRank: usize, colour: Colour) !void {
    // TODO
    // Most of the time you can't en-passant so make that case as fast as possible. 
    switch (board.frenchMove) {
        .none => return,
        .file => |validTargetFile| {
            if (targetFile != validTargetFile) return;
            if ((colour == .White and targetRank != 5) or (colour == .Black and targetRank != 2)) return;
            const endIndex = targetRank*8 + targetFile;
            const captureIndex = ((if (colour == .White) targetRank-1 else targetRank+1)*8) + targetFile;
            assert(board.squares[captureIndex].is(colour.other(), .Pawn));
            try moves.append(.{
                .from = @intCast(i),
                .to = @intCast(endIndex),
                .action = .{.useFrenchMove=@intCast(captureIndex)},
                .isCapture = true
            });
        }
    }
}

fn maybePromote(moves: *std.ArrayList(Move), board: *const Board, fromIndex: usize, toFile: usize, toRank: usize, colour: Colour) !void {
    // TODO: including promotions on fast path should be seperate option
    const check = board.get(toFile, toRank);
    
    switch (filter) {
        .Any => {},
        .CapturesOnly => if (check.kind == .Empty or check.colour == colour) return,
        .KingCapturesOnly => if (check.kind != .King or check.colour == colour) return,
    }
    
    if ((colour == .Black and toRank == 0) or (colour == .White and toRank == 7)){
        var move: Move = .{
            .from=@intCast(fromIndex),
            .to = @intCast(toRank*8 + toFile),
            .action = .{.promote = .Queen },
            .isCapture = !check.empty() and check.colour != colour
        };
        // Queen promotions are so good that we don't even care about preserving order of the old stuff. 
        // TODO: that's wrong cause mate
        if (moves.items.len > 0) {
            try moves.append(moves.items[0]);
            moves.items[0] = move;
        } else {
            try moves.append(move);
        }

        // Technically you might want a knight but why ever anything else? For correctness (avoiding draws?) still want to consider everything.
        const options = [_] Kind { .Knight, .Rook, .Bishop }; 
        for (options) |k| {
            move.action = .{.promote = k };
            try moves.append(move);
        }
    } else {
        try moves.append(Move.irf(fromIndex, toFile, toRank, !check.empty() and check.colour != colour));
    }
}

// Returns true if this move was a capture or blocked by self so loop should break. 
fn trySlide(moves: *std.ArrayList(Move), board: *const Board, i: usize, checkFile: usize, checkRank: usize, piece: Piece) !bool {
    const check = board.get(checkFile, checkRank);
    
    switch (filter) {
        .Any => {},
        .CapturesOnly => if (check.kind == .Empty or check.colour == piece.colour) return false,
        .KingCapturesOnly => if (check.kind != .King or check.colour == piece.colour) return !check.empty(),
    }

    if (check.empty()) {
        try moves.append(Move.irf(i, checkFile, checkRank, false));
        return false;
    } else if (check.colour == piece.colour) { 
        return true;
    } else {
        var toPush = Move.irf(i, checkFile, checkRank, true);

        // Have this be a comptime param that gets passed down so I can easily benchmark. 
        // This is a capture, we like that, put it first. Capturing more valuable pieces is also good. 
        for (moves.items, 0..) |move, index| {
            const holding = board.squares[toPush.to].kind.material();
            const lookingAt = board.squares[move.to].kind.material();
            if (holding == 0) break;
            if (holding > lookingAt){
                moves.items[index] = toPush;
                toPush = move;
            }
        }

        try moves.append(toPush);
        return true;
    }
}

fn trySlide2(moves: *std.ArrayList(Move), board: *const Board, fromIndex: u6, toIndexx: u6, piece: Piece) !bool {
    switch (filter) {
        .Any => {},
        .CapturesOnly => if (board.squares[toIndexx].empty()) return false,
        .KingCapturesOnly => if ( board.squares[toIndexx].kind != .King) return ! board.squares[toIndexx].empty(),
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
        }
    }

    const toFlag = one << toIndexx;
    if ((toFlag & mine) != 0) {  // trying to move onto my piece
        return true;
    }

    if ((toFlag & other) != 0) {  // taking an enemy piece
        var toPush = Move.ii(fromIndex, toIndexx, true);

        // Have this be a comptime param that gets passed down so I can easily benchmark. 
        // This is a capture, we like that, put it first. Capturing more valuable pieces is also good. 
        for (moves.items, 0..) |move, index| {
            const holding = board.squares[toPush.to].kind.material();
            const lookingAt = board.squares[move.to].kind.material();
            if (holding == 0) break;
            if (holding > lookingAt){
                moves.items[index] = toPush;
                toPush = move;
            }
        }

        try moves.append(toPush);
        return true;
    }

    // moving to empty square
    try moves.append(Move.ii(fromIndex, toIndexx, false));
    return false;
}

// TODO: This is suck!
fn bishopSlide(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    {
        var checkFile = file;
        var checkRank = rank;
        while (checkFile < 7 and checkRank < 7) {
            checkFile += 1;
            checkRank += 1;
            if (try trySlide(moves, board, i, checkFile, checkRank, piece)) break;
        }
    }

    {
        var checkFile = file;
        var checkRank = rank;
        while (checkFile > 0 and checkRank < 7) {
            checkFile -= 1;
            checkRank += 1;
            if (try trySlide(moves, board, i, checkFile, checkRank, piece)) break;
        }
    }

    {
        var checkFile = file;
        var checkRank = rank;
        while (checkFile < 7 and checkRank > 0) {
            checkFile += 1;
            checkRank -= 1;
            if (try trySlide(moves, board, i, checkFile, checkRank, piece)) break;
        }
    }

    {
        var checkFile = file;
        var checkRank = rank;
        while (checkFile > 0 and checkRank > 0) {
            checkFile -= 1;
            checkRank -= 1;
            if (try trySlide(moves, board, i, checkFile, checkRank, piece)) break;
        }
    }
}

fn kingMove(moves: *std.ArrayList(Move), board: *Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    // forward
    if (file < 7) {
        _ = try trySlide(moves, board, i, file + 1, rank, piece);
        if (rank < 7) _ = try trySlide(moves, board, i, file + 1, rank + 1, piece);
        if (rank > 0) _ = try trySlide(moves, board, i, file + 1, rank - 1, piece);
    }
    // back
    if (file > 0) {
        _ = try trySlide(moves, board, i, file - 1, rank, piece);
        if (rank < 7) _ = try trySlide(moves, board, i, file - 1, rank + 1, piece);
        if (rank > 0) _ = try trySlide(moves, board, i, file - 1, rank - 1, piece);
    }
    // horizontal
    if (rank < 7) _ = try trySlide(moves, board, i, file, rank + 1, piece);
    if (rank > 0) _ = try trySlide(moves, board, i, file, rank - 1, piece);

    try tryCastle(moves, board, i, file, rank, piece.colour, true);
    try tryCastle(moves, board, i, file, rank, piece.colour, false);
}

fn castlingIsLegal(board: *Board, i: usize, colour: Colour, comptime goingLeft: bool) !bool {
    const path = if (goingLeft) [_] usize {i-1, i-2, i-3} else [_] usize {i+1, i+2};
    for (path) |sq| {
        // TODO: do this without playing the move? It annoys me that this makes getPossibleMoves take a mutable board pointer (would also be fixed by doing it later with other legal move checks). 
        const move = Move.ii(@intCast(i), @intCast(sq), false);
        const unMove = try board.play(move);
        defer board.unplay(unMove);
        if (try reverseFromKingIsInCheck(board, colour)) return false;
    }
    return true;
}

// TODO: do all the offsets on i instead of on (x, y) since we know rooks/king are in start pos so can't wrap around board. 
pub fn tryCastle(moves: *std.ArrayList(Move), board: *Board, i: usize, file: usize, rank: usize, colour: Colour, comptime goingLeft: bool) !void {
    const cI: usize = if (colour == .White) 0 else 1;
    if (i != 4 + (cI * 8*7)) return;  // TODO: redundant
    const allow = if (goingLeft) board.castling.left[cI] else board.castling.right[cI];
    if (allow){
        // TODO: can be a hard coded mask
        const pathClear = if (goingLeft) 
                             (board.emptyAtI(i - 1) and board.emptyAtI(i - 2) and board.emptyAtI(i - 3))
                             else (board.emptyAtI(i + 1) and board.emptyAtI(i + 2));

        if (pathClear) {
            // TODO: do this later like other check checks. That way don't need to do the expensive check if it gets pruned out. Probably won't save much since you generally want to castle anyway. 
            if (!try castlingIsLegal(board, i, colour, goingLeft)) return;

            const kingFrom: u6 = @intCast(rank*8 + file);
            const kingTo: u6 = if (goingLeft) @intCast(rank*8 + (file - 2)) else @intCast(rank*8 + (file + 2));
            const rookFrom: u6 = if (goingLeft) @intCast(rank*8) else @intCast((rank+1)*8 - 1);
            const rookTo: u6 = if (goingLeft) @intCast(rank*8 + (file - 1)) else @intCast(rank*8 + (file + 1));
            assert(board.squares[kingFrom].is(colour, .King));
            assert(board.squares[kingTo].empty());
            assert(board.squares[rookFrom].is(colour, .Rook));
            assert(board.squares[rookTo].empty());
            const move: Move = .{
                .from=kingFrom,
                .to=kingTo,
                .action = .{.castle = .{
                    .rookFrom = rookFrom,
                    .rookTo =rookTo,
                }},
                .isCapture=false
            };
            try moves.append(move);
        }
    }
}

fn tryHop(moves: *std.ArrayList(Move), board: *const Board, i: usize, checkFile: usize, checkRank: usize, piece: Piece) !void {
    const check = board.get(checkFile, checkRank);
     switch (filter) {
        .Any => {},
        .CapturesOnly => if (check.empty()) return,
        .KingCapturesOnly => if (check.kind != .King) return,
    }
    
    if (check.empty() or check.colour != piece.colour) {
        try moves.append(Move.irf(i, checkFile, checkRank, !check.empty()));
    } 
}

fn knightMove(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    if (rank < 6){
        if (file < 7) try tryHop(moves, board, i, file + 1, rank + 2, piece);
        if (file > 0) try tryHop(moves, board, i, file - 1, rank + 2, piece);
    }
    if (rank > 1){
        if (file < 7) try tryHop(moves, board, i, file + 1, rank - 2, piece);
        if (file > 0) try tryHop(moves, board, i, file - 1, rank - 2, piece);
    }

    if (file < 6){
        if (rank < 7) try tryHop(moves, board, i, file + 2, rank + 1, piece);
        if (rank > 0) try tryHop(moves, board, i, file + 2, rank - 1, piece);
    }
    if (file > 1){
        if (rank < 7) try tryHop(moves, board, i, file - 2, rank + 1, piece);
        if (rank > 0) try tryHop(moves, board, i, file - 2, rank - 1, piece);
    }
}

};} // End Strategy. 

// TODO: this is bascilly a copy paste from the other one. could have all the move functions be generic over a function to call when you get each move.
pub fn reverseFromKingIsInCheck(game: *Board, me: Colour) !bool {
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
                    } 
                    else break;
                }
            }
        }
        
        if (file > 0) {
            for (1..(file+1)) |checkFile| {
                if (!game.emptyAt(file - checkFile, rank)) {
                    const p = game.get(file - checkFile, rank);
                    if (p.colour == me) break;
                    if (p.kind == .Queen or p.kind == .Rook){
                        break :check true;
                    } 
                    else break;
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
                    } 
                    else break;
                }
            }
        }
    
        if (rank > 0) {
            for (1..(rank+1)) |checkRank| {
                if (!game.emptyAt(file, rank-checkRank)) {
                    const p = game.get(file, rank-checkRank);
                    if (p.colour == me) break;
                    if (p.kind == .Queen or p.kind == .Rook) {
                        break :check true;
                    } 
                    else break;
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
                    if (p.kind == .Queen or p.kind == .Bishop){
                        break :check true;
                    } 
                    else break;
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
                    if (p.kind == .Queen or p.kind == .Bishop){
                        break :check true;
                    } 
                    else break;
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
                    if (p.kind == .Queen or p.kind == .Bishop){
                        break :check true;
                    } 
                    else break;
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
                    if (p.colour == me) break;  // my piece is safe and blocks
                    if (p.kind == .Queen or p.kind == .Bishop) {  // your slider can attack me
                        break :check true;
                    } 
                    else break;  // your non-slider keeps me safe from other sliders 
                }
            }
        }

        // The other king
        const iOther = if (me == .Black) (game.whiteKingIndex) else (game.blackKingIndex);
        const fileOther = iOther % 8;
        const rankOther = iOther / 8;
        const fileDiff = @as(i32, @intCast(file)) - @as(i32, @intCast(fileOther));
        const rankDiff = @as(i32, @intCast(rank)) - @as(i32, @intCast(rankOther));
        if (fileDiff*fileDiff <= 1 and rankDiff*rankDiff <= 1) break :check true;


        // Pawns
        // Dont care about forward moves becasue they can't take. 
        const onEdge = if (me == .White) rank == 7 else rank == 0;
        if (!onEdge){
            const targetRank = switch (me) {
                .White => w: {
                    break :w rank + 1;
                },
                .Black => b: {
                    break :b rank - 1;
                }
            };

            if (file < 7 and game.get(file + 1, targetRank).kind == .Pawn and game.get(file + 1, targetRank).colour != me) {  // right
                break :check true;
            }
            if (file > 0 and game.get(file - 1, targetRank).kind == .Pawn and game.get(file - 1, targetRank).colour != me) {
                break :check true;
            }

        }
       
        // Knights!

        if (rank < 6){
            if (file < 7) {
                const p = game.get(file + 1, rank + 2);
                if (p.kind == .Knight and p.colour != me) break :check true; 
            }

            if (file > 0) {
                const p = game.get(file - 1, rank + 2);
                if (p.kind == .Knight and p.colour != me) break :check true; 
            }
        }
        if (rank > 1){
            if (file < 7) {
                const p = game.get(file + 1, rank - 2);
                if (p.kind == .Knight and p.colour != me) break :check true; 
            }

            if (file > 0) {
                const p = game.get(file - 1, rank - 2);
                if (p.kind == .Knight and p.colour != me) break :check true; 
            }
        }

        if (file < 6){
            if (rank < 7) {
                const p = game.get(file + 2, rank + 1);
                if (p.kind == .Knight and p.colour != me) break :check true; 
            }

            if (rank > 0) {
                const p = game.get(file + 2, rank - 1);
                if (p.kind == .Knight and p.colour != me) break :check true; 
            }
        }
        if (file > 1){
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