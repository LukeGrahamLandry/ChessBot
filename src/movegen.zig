const std = @import("std");
const assert = std.debug.assert;

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
    return @truncate(rank*8 + file);
}

// const MoveSortContext = struct { 
//     me: Colour,
//     board: Board,
// };

// This is used as a lessThan function but is flipped because std sorts in ascending order. 
// fn bestMovesFirst(ctx: MoveSortContext, a: Move, b: Move) bool {
//     switch (ctx.me) {
//         .White => return simpleEval(&ctx.board.copyPlay(a)) > simpleEval(&ctx.board.copyPlay(b)),
//         .Black => return simpleEval(&ctx.board.copyPlay(a)) < simpleEval(&ctx.board.copyPlay(b)),
//         .Empty => unreachable,
//     }
// }

// // The alpha-beta pruning saves a lot more time if the best moves are the first ones it tries. 
// // Sort by material eval with the best moves first. 
// pub fn sortedMoves(board: *const Board, me: Colour, alloc: std.mem.Allocator) ![] Move {
//     var moves = try possibleMoves(board, me, alloc);
//     // This was much slower than the simple prefer captures in trySlide. 
//     // TODO: maybe check again if I do the iterative deepening thing then remove this. even doubling speed of simpleEval didn't help. 
//     // TODO: try heap sort so you can bail out after best x moves or whatever
//     // const ctx: MoveSortContext = .{ .me=me, .board=board.* };
//     // std.sort.insertion(Move, moves, ctx, bestMovesFirst);
//     return moves;
// }

// TODO: castling, en-passant, check
const one: u64 = 1;
// Caller owns the returned slice.
pub fn possibleMoves(board: *const Board, me: Colour, alloc: std.mem.Allocator) ![] Move {
    var moves = try std.ArrayList(Move).initCapacity(alloc, 50);
    const mySquares = switch (me) {
            .White => board.peicePositions.white,
            .Black => board.peicePositions.black,
        };
    
    var flag: u64 = 1;
    for (0..64) |i| {
        defer flag <<= 1; // shift the bit over at the end of each iteration. 
        if ((mySquares & flag) == 0) {
            // assert(board.squares[i].empty() or board.squares[i].colour != me);
            continue;
        }
        // assert(board.squares[i].colour == me);

        const file = i % 8;
        const rank = i / 8;
        try collectOnePieceMoves(&moves, board, i, file, rank);
    }

    // TODO: make sure this isn't reallocating 
    return try moves.toOwnedSlice();
}

pub fn collectOnePieceMoves(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize) !void {
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

const Sq = @Vector(2, i32);
fn rookSlide(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    // _ = _rank;
    // _ = _file;
    // const up: i32 = 8;
    // const down: i32 = -8;
    // const left: i32 = -1;
    // const right: i32 = 1;
    // const directions = comptime [_] i32 { up, down, left, right };
    // inline for (directions) |dir| {
    //     var pos: i32 = @intCast(i);
    //     for (0..8) |_| {
    //         pos += dir;
    //         if (pos < 0 or pos > 63) break;
    //         if (try trySlide2(moves, board, @intCast(i), @intCast(pos), piece)) break;
    //     }
    // }


    // const start: Sq = [_] i32 { @intCast(_file), @intCast(_rank) };

    // const up: Sq = comptime [_] i32 { 0, 1 };
    // const down: Sq = comptime [_] i32 { 0, -1 };
    // const left: Sq = comptime [_] i32 { -1, 0 };
    // const right: Sq = comptime [_] i32 { 1, 0 };
    // const directions = comptime [_] Sq { up, down, left, right };

    // const _flag: i32 = 63;
    // const flag: Sq = @splat(2, ~_flag);

    // inline for (directions, 0..) |dir, dirIndex| {
    //     _ = dirIndex;
    //     var pos = start;
    //     for (0..8) |_| {
    //         pos += dir;
    //         if (@reduce(.Or, pos & flag != @splat(2, @as(i32, 0)))) break;
    //         if (try trySlide(moves, board, i, @intCast(pos[0]), @intCast(pos[1]), piece)) break;
    //     }
    // }

    // const distances = comptime calc: {
    //     @setEvalBranchQuota(4*64*8);
    //     var byDirection: [4] [64] usize = std.mem.zeroes([4] [64] usize);
    //     for (directions, 0..) |dir, dirIndex| {
    //         for (0..64) |sqIndex| {
    //             var pos: Sq = [_] i32 { @rem(sqIndex, 8), @divFloor(sqIndex, 8) };
    //             for (0..8) |_| {
    //                 pos += dir;
    //                 if (pos[0] < 0 or pos[1] < 0 or pos[0] > 7 or pos[1] > 7) break;
    //                 byDirection[dirIndex][sqIndex] += 1;
    //             }
    //         }
    //     }
    //     break :calc byDirection;
    // };

    // inline for (directions, 0..) |dir, dirIndex| {
    //     var pos = start;
    //     for (0..distances[dirIndex][i]) |_| {
    //         pos += dir;
    //         if (try trySlide(moves, board, i, @intCast(pos[0]), @intCast(pos[1]), piece)) break;
    //     }
    // }

    // const zero: Sq = @splat(2, @as(i32, 0));
    // const seven: Sq = @splat(2, @as(i32, 7));
    // inline for (directions) |dir| {
    //     var pos = start;
    //     for (0..8) |_| {
    //         pos += dir;
    //         if (@reduce(.Or, pos < zero) or @reduce(.Or, pos > seven)) break;
    //         if (try trySlide(moves, board, i, @intCast(pos[0]), @intCast(pos[1]), piece)) break;
    //     }
    // }

    // TODO: this does not spark joy. Feels like there should be some way to express it as a mask that you bit shift around. 
    if (file < 7) {
        for ((file + 1)..8) |checkFile| {
            if (try trySlide(moves, board, i, checkFile, rank, piece)) break;
        }
    }
    
    if (file > 0) {
        for (1..(file+1)) |checkFile| {
            if (try trySlide(moves, board, i, file - checkFile, rank, piece)) break;
        }
    }

    if (rank < 7) {
        for ((rank + 1)..8) |checkRank| {
            if (try trySlide(moves, board, i, file, checkRank, piece)) break;
        }
    }
    
    if (rank > 0) {
        for (1..(rank+1)) |checkRank| {
            if (try trySlide(moves, board, i, file, rank-checkRank, piece)) break;
        }
    }
}

fn pawnMove(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    const targetRank = switch (piece.colour) {
        // Asserts can't have a pawn at the end in real games because it would have promoted. 
        .White => w: {
            // assert(rank < 7);  
            if (filter == .Any and rank == 1 and board.emptyAt(file, 2) and board.emptyAt(file, 3)) {  // forward two
                try moves.append(Move.irf(i, file, 3));  // cant promote
            }
            break :w rank + 1;
        },
        .Black => b: {
            // assert(rank > 0);
            if (filter == .Any and rank == 6 and board.emptyAt(file, 5) and board.emptyAt(file, 4)) {  // forward two
                try moves.append(Move.irf(i, file, 4));  // cant promote
            }
            break :b rank - 1;
        }
    };

    if (filter == .Any and board.emptyAt(file, targetRank)) {  // forward
        try maybePromote(moves, board, i, file, targetRank, piece.colour);
    }
    if (file < 7 and !board.emptyAt(file + 1, targetRank) and board.get(file + 1, targetRank).colour != piece.colour) {  // right
        try maybePromote(moves, board, i, file + 1, targetRank, piece.colour);
    }
    if (file > 0 and !board.emptyAt(file - 1, targetRank) and board.get(file - 1, targetRank).colour != piece.colour) {
        try maybePromote(moves, board, i, file - 1, targetRank, piece.colour);
    }
}

fn maybePromote(moves: *std.ArrayList(Move), board: *const Board, fromIndex: usize, toFile: usize, toRank: usize, colour: Colour) !void {
    // TODO: including promotions on fast path should be seperate option
    switch (filter) {
        .Any => {},
        .CapturesOnly => if (board.emptyAt(toFile, toRank)) return,
        .KingCapturesOnly => if (board.get(toFile, toRank).kind != .King) return,
    }
    
    if ((colour == .Black and toRank == 0) or (colour == .White and toRank == 7)){
        // Just pushing all options does make it a bit slower. 
        // This is even slower:
        // var toPush: Move = base;
        // for (moves.items, 0..) |move, index| {
        //     const holding = switch (toPush.action) {
        //         .none => board.squares[toPush.to].kind.material(),
        //         .promote => |kind| kind.material(),
        //     };
        //     const lookingAt = switch (move.action) {
        //         .none => board.squares[move.to].kind.material(),
        //         .promote => |kind| kind.material(),
        //     };
        //     if (holding == 0) break;
        //     if (holding > lookingAt){
        //         moves.items[index] = toPush;
        //         toPush = move;
        //     }
        // }

        var move: Move = .{
            .from=@truncate(fromIndex),
            .to = @truncate(toRank*8 + toFile),
            .action = .{.promote = .Queen }
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
        try moves.append(Move.irf(fromIndex, toFile, toRank));
    }
}

// Returns true if this move was a capture or blocked by self so loop should break. 
fn trySlide(moves: *std.ArrayList(Move), board: *const Board, i: usize, checkFile: usize, checkRank: usize, piece: Piece) !bool {
    const check = board.get(checkFile, checkRank);
    
    switch (filter) {
        .Any => {},
        .CapturesOnly => if (check.empty()) return true,
        .KingCapturesOnly => if (check.kind != .King) return !check.empty(),
    }

    if (check.empty()) {
        try moves.append(Move.irf(i, checkFile, checkRank));
        return false;
    } else if (check.colour == piece.colour) { 
        return true;
    } else {
        var toPush = Move.irf(i, checkFile, checkRank);

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
    const check = board.squares[toIndexx];
    
    switch (filter) {
        .Any => {},
        .CapturesOnly => if (check.empty()) return true,
        .KingCapturesOnly => if (check.kind != .King) return !check.empty(),
    }

    if (check.empty()) {
        try moves.append(Move.ii(fromIndex, toIndexx));
        return false;
    } else if (check.colour == piece.colour) { 
        return true;
    } else {
        var toPush = Move.ii(fromIndex, toIndexx);

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

fn kingMove(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
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
}

fn tryHop(moves: *std.ArrayList(Move), board: *const Board, i: usize, checkFile: usize, checkRank: usize, piece: Piece) !void {
    const check = board.get(checkFile, checkRank);
     switch (filter) {
        .Any => {},
        .CapturesOnly => if (check.empty()) return,
        .KingCapturesOnly => if (check.kind != .King) return,
    }
    
    if (check.empty() or check.colour != piece.colour) {
        try moves.append(Move.irf(i, checkFile, checkRank));
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


var tst = std.testing.allocator;


const genKingCapturesOnly = @import("movegen.zig").MoveFilter.KingCapturesOnly.get();
fn countPossibleGames(game: *Board, me: Colour, remainingDepth: usize, alloc: std.mem.Allocator) !usize {
    if (remainingDepth == 0) return 1;
    const allMoves = try MoveFilter.Any.get().possibleMoves(game, me, alloc);
    defer alloc.free(allMoves);
    // if (remainingDepth == 1) return allMoves.len; // TODO: look at checks

    var total: usize = 0;
    for (allMoves) |move| {
        const unMove = try game.play(move);
        defer game.unplay(unMove);

        {
            const moves = try genKingCapturesOnly.possibleMoves(game, me.other(), alloc);
            defer alloc.free(moves);
            if (moves.len > 0) continue; // move illigal
        }

        total += try countPossibleGames(game, me.other(), remainingDepth - 1, alloc);
    }

    return total;
}

// TODO: Super slow. memo or count as you go down instead of redoing work all the time, could do it iteritivly that way and just store the whole next layer in an array. 
// TODO: can't go farther until it knows about checkmate
// Tests that the move generation gets the right number of nodes at each depth. 
// Also exercises the Board.unplay function.
test "count possible games" {
    // https://en.wikipedia.org/wiki/Shannon_number
    const possibleGames = [_] usize { 20, 400, 8902, 197281	}; // 4865609 (needs checkmate or castling?)

    var tempA = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tempA.deinit();
    var game = Board.initial(tst);
    defer game.deinit();
    for (possibleGames, 1..) |expected, i| {
        const start = std.time.nanoTimestamp();
        // These parameters are backwards because it can't infer type from a comptime_int. This seems dumb. 
        try std.testing.expectEqual(countPossibleGames(&game, .White, i, tempA.allocator()), expected);
        std.debug.print("Explored Depth {} in {}ms.\n", .{i, @divFloor((std.time.nanoTimestamp() - start), @as(i128, std.time.ns_per_ms))});
    }
}

// TODO: this is bascilly a copy paste from the other one 
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