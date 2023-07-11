const std = @import("std");
const assert = std.debug.assert;

const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;

var notTheRng = std.rand.DefaultPrng.init(0);
var rng = notTheRng.random();
const MoveErr = error { GameOver, OutOfMemory };
const isWasm = @import("builtin").target.isWasm();

// This is 4 bytes but, 
// If I was more efficient for promotion targets because you know it's on the far rank, and there's only 4 promotion options,
// this could fit in 3 bytes, [from: u6, action: u1, (to: u6) or (kind: u2, to: u3)] = u13. 
// Or even 2 bytes because if you can check if its a pawn moving from second back rank so you don't need the action flag. 
// But it's not worth dealing with yet. Might be worth it to store the opening book in half the space tho!
pub const Move = struct {
    from: u6,
    to: u6,
    action: union(enum) {
        none,
        promote: Kind,
    },

    // TODO: method that factors out bounds check from try methods then calls this? make sure not to do twice in slide loops.
    fn irf(fromIndex: usize, toFile: usize, toRank: usize) Move {
        std.debug.assert(fromIndex < 64 and toFile < 8 and toRank < 8);
        return .{
            .from=@truncate(fromIndex),
            .to = @truncate(toRank*8 + toFile),
            .action = .none,
        };
    }
};

pub fn Strategy(
    comptime maxDepth: comptime_int,  // TODO: should be runtime param to bestMove so wasm can change without increasing code size. 
    comptime doPruning: bool, 
    comptime beDeterministicForTest: bool
) type {
    return struct {  // Start Strategy. 

comptime { 
    assert(@sizeOf(Piece) == @sizeOf(u8)); 
}

const MemoMap = std.HashMap(Board, struct {
    eval: i32,
    remaining: u64
}, struct {
    // TODO: auto test different algos, don't include padding bytes, try Zobrist. 
    pub fn hash(_: @This(), key: Board) u64 {
        const data = std.mem.asBytes(&key.squares);  
        return std.hash.CityHash64.hash(data); 
    }
    
    pub fn eql(_: @This(), a: Board, b: Board) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a.squares), std.mem.asBytes(&b.squares));
    }
}, FILL_PERCENT);  

// TODO: this wont be exact because capacity goes to the next highest power of two. 
const MEMO_MAX_MB = 20;  // TODO: make this configurable 
const MEMO_CAPACITY = (MEMO_MAX_MB * 1024 * 1024) / @sizeOf(MemoMap.KV) * 100 / FILL_PERCENT;
const FILL_PERCENT = 60;  // TODO: script to test different values 

// This gets reset after each whole decision is done.
var upperArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
// This gets reset after checking each top level move. 
var movesArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

// This has its own loop because I actually need to know which move is best which walkEval doesn't return. 
// Also means I can reset the temp allocator more often. 
pub fn bestMove(game: *Board, me: Colour) !Move {
    var alloc = upperArena.allocator();
    defer _ = upperArena.reset(.retain_capacity);
    
    const moves = try sortedMoves(game, me, alloc);
    defer alloc.free(moves);
    if (moves.len == 0) return error.GameOver;
    var bestMoves = try std.ArrayList(Move).initCapacity(alloc, 50);
    defer bestMoves.deinit();

    var memo = MemoMap.init(alloc);
    try memo.ensureTotalCapacity(MEMO_CAPACITY);
    defer memo.deinit();

    var bestWhiteEval: i32 = -99999999;
    var bestBlackEval: i32 = -99999999;
    
    var bestVal: i32 = -1000000;
    var count: u64 = 0;
    for (moves) |move| {
        const unMove = game.play(move);
        defer game.unplay(unMove);
        const value = -try walkEval(game, me.other(), maxDepth, bestWhiteEval, bestBlackEval, movesArena.allocator(), &count, &memo);  // TODO: need to catch
        if (value > bestVal) {
            bestVal = value;
            bestMoves.clearRetainingCapacity();
            try bestMoves.append(move);
            if (doPruning and checkAlphaBeta(bestVal, me, &bestWhiteEval, &bestBlackEval)) break;
        } else if (value == bestVal) {
            try bestMoves.append(move);
        }
        _ = movesArena.reset(.retain_capacity);
    }

    assert(bestMoves.items.len > 0 and bestMoves.items.len <= moves.len);
    // You can't just pick a deterministic random because pruning might end up with a shorter list of equal moves. 
    // Always choosing the first should be fine because pruning just cuts off the search early.
    const choice = if (beDeterministicForTest) 0 else rng.uintLessThanBiased(usize,  bestMoves.items.len);
    if (!isWasm and !beDeterministicForTest) std.debug.print("Checked {} end states. {} boards in memo table. {} moves with eval {}.\n", .{count, memo.count(), bestMoves.items.len, bestVal});
    // for (bestMoves.items, 0..) |move, i| {
    //     std.debug.print("{}. \n{s}\n", .{i, try game.copyPlay(move).displayString(alloc)});
    // } 
    
    return bestMoves.items[choice];
}

// https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning
// TODO: when hit depth, keep going but only look at captures
// The alpha-beta values effect lower layers, not higher layers, so passed by value. 
fn walkEval(game: *Board, me: Colour, remaining: u32, bestWhiteEvalIn: i32, bestBlackEvalIn: i32, alloc: std.mem.Allocator, count: *u64, memo: *MemoMap) MoveErr!i32 {
    // After alpha-beta, bigger starting cap, and not reallocating each move, this does make it faster. 
    // Makes Black move 4 end states go 16,000,000 -> 1,000,000
    // But now after better pruning it does almost nothing. 
    if (memo.get(game.*)) |cached| {
        if (cached.remaining >= remaining){
            return if (me == .White) cached.eval else -cached.eval;
        }
        // TODO: should save the best move from that position at the old low depth and use it as the start for the search 
    }

    // Want to mutate values from parameters. 
    var bestWhiteEval = bestWhiteEvalIn;
    var bestBlackEval = bestBlackEvalIn;

    const moves = try sortedMoves(game, me, alloc);
    defer alloc.free(moves);
    if (moves.len == 0) return error.GameOver;
    
    var bestVal: i32 = -1000000;
    for (moves) |move| {
        const unMove = game.play(move);
        defer game.unplay(unMove);
        const value = if (remaining == 0) e: {
            if (!isWasm) count.* += 1;
            break :e if (me == .White) simpleEval(game) else -simpleEval(game);
        } else r: {
            const v = walkEval(game, me.other(), remaining - 1, bestWhiteEval, bestBlackEval, alloc, count, memo) catch |err| {
                switch (err) {
                    error.OutOfMemory => return err,
                    error.GameOver => break :r 1000000,
                }
            };
            break :r -v;
        };

        if (value > bestVal) {
            bestVal = value;
            if (doPruning and checkAlphaBeta(bestVal, me, &bestWhiteEval, &bestBlackEval)) break;
        }
    }

    // TODO: I want to not reset the table between moves but then when it runs out of space it would be full of positions we don't need anymore.
    //       need to get rid of old ones somehow. maybe my own hash map that just overwrites on collissions? 
    // Don't need to check `and memo.capacity() > MEMO_CAPACITY` because we allocate the desired capacity up front.
    const memoFull = memo.unmanaged.available == 0;
    if (!memoFull) {
        try memo.put(game.*, .{
            .eval = if (me == .White) bestVal else -bestVal,
            .remaining = remaining,
        });
    }
    
    return bestVal;
}

// This is in it's own function because it's used in the special upper loop and the walkEval. 
/// Returns true if the move is so good we should stop considering this branch. 
fn checkAlphaBeta(bestVal: i32, me: Colour, bestWhiteEval: *i32, bestBlackEval: *i32) bool {
    switch (me) {
        .White => {
            bestWhiteEval.* = @max(bestWhiteEval.*, bestVal);
            if (bestVal >= -bestBlackEval.*) {
                return true;
            }
        },
        .Black => {
            bestBlackEval.* = @max(bestBlackEval.*, bestVal);
            if (bestVal >= -bestWhiteEval.*) {
                return true;
            }
        }
    }
    return false;
}

/// Positive means white is winning. 
pub fn simpleEval(game: *const Board) i32 {
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

// The alpha-beta pruning saves a lot more time if the best moves are the first ones it tries. 
// Sort by material eval with the best moves first. 
pub fn sortedMoves(board: *const Board, me: Colour, alloc: std.mem.Allocator) ![] Move {
    var moves = try possibleMoves(board, me, alloc);
    // This was much slower than the simple prefer captures in trySlide. 
    // TODO: maybe check again if I do the iterative deepening thing then remove this. even doubling speed of simpleEval didn't help. 
    // const ctx: MoveSortContext = .{ .me=me, .board=board.* };
    // std.sort.insertion(Move, moves, ctx, bestMovesFirst);
    return moves;
}

// TODO: castling, en-passant, check
const one: u64 = 1;
pub fn possibleMoves(board: *const Board, me: Colour, alloc: std.mem.Allocator) ![] Move {
    var moves = try std.ArrayList(Move).initCapacity(alloc, 50);
    const mySquares = switch (me) {
            .White => board.whitePeicePositions,
            .Black => board.blackPeicePositions,
        };
    
    var flag: u64 = 1;
    for (0..64) |i| {
        defer flag <<= 1; // shift the bit over at the end of each iteration. 
        if ((mySquares & flag) == 0) {
            // assert(board.squares[i].empty() or board.squares[i].colour != me);
            continue;  // bit board means fewer memory accesses 
        }
        // assert(board.squares[i].colour == me);

        const piece = board.squares[i];
        const file = i % 8;
        const rank = i / 8;
        switch (piece.kind) {
            .Pawn => try pawnMove(&moves, board, i, file, rank, piece),
            .Bishop => try bishopSlide(&moves, board, i, file, rank, piece),
            .Knight => try knightMove(&moves, board, i, file, rank, piece),
            .Rook => try rookSlide(&moves, board, i, file, rank, piece),
            .King => try kingMove(&moves, board, i, file, rank, piece),
            .Queen => {
                try rookSlide(&moves, board, i, file, rank, piece);
                try bishopSlide(&moves, board, i, file, rank, piece);
            },
            .Empty => unreachable,
        }
    }

    // TODO: make sure this isn't reallocating 
    return try moves.toOwnedSlice();
}

fn rookSlide(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
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
            assert(rank < 7);  
            if (rank == 1 and board.emptyAt(file, 2) and board.emptyAt(file, 3)) {  // forward two
                try moves.append(Move.irf(i, file, 3));  // cant promote
            }
            break :w rank + 1;
        },
        .Black => b: {
            assert(rank > 0);
            if (rank == 6 and board.emptyAt(file, 5) and board.emptyAt(file, 4)) {  // forward two
                try moves.append(Move.irf(i, file, 4));  // cant promote
            }
            break :b rank - 1;
        }
    };

    if (board.emptyAt(file, targetRank)) {  // forward
        try maybePromote(moves, board, i, file, targetRank, piece.colour);
    }
    if (file < 7 and !board.emptyAt(file + 1, targetRank) and board.get(file + 1, targetRank).colour == piece.colour.other()) {  // right
        try maybePromote(moves, board, i, file + 1, targetRank, piece.colour);
    }
    if (file > 0 and !board.emptyAt(file - 1, targetRank) and board.get(file - 1, targetRank).colour == piece.colour.other()) {
        try maybePromote(moves, board, i, file - 1, targetRank, piece.colour);
    }
}

fn maybePromote(moves: *std.ArrayList(Move), board: *const Board, fromIndex: usize, toFile: usize, toRank: usize, colour: Colour) !void {
    _ = board;
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

pub const default = Strategy(4, true, false);
const testFast = Strategy(4, true, true);
const testSlow = Strategy(4, false, true);

var tst = std.testing.allocator;

fn countPossibleGames(game: *Board, me: Colour, remainingDepth: usize) !usize {
    if (remainingDepth == 0) return 1;
    const allMoves = try default.possibleMoves(game, me, tst);
    defer tst.free(allMoves);
    if (remainingDepth == 1) return allMoves.len;

    var total: usize = 0;
    for (allMoves) |move| {
        const unMove = game.play(move);
        defer game.unplay(unMove);
        total += try countPossibleGames(game, me.other(), remainingDepth - 1);
    }

    return total;
}

// TODO: Super slow. memo or count as you go down instead of redoing work all the time. 
// TODO: can't go farther until it knows about checkmate
// Tests that the move generation gets the right number of nodes at each depth. 
// Also exercises the Board.unplay function.
test "count possible games" {
    // https://en.wikipedia.org/wiki/Shannon_number
    const possibleGames = [_] usize { 20, 400, 8902	};

    var game = Board.initial();
    for (possibleGames, 1..) |expected, i| {
        // const start = std.time.nanoTimestamp();
        // These parameters are backwards because it can't infer type from a comptime_int. This seems dumb. 
        try std.testing.expectEqual(countPossibleGames(&game, .White, i), expected);
        // std.debug.print("Explored Depth {} in {}ms.\n", .{i, @divFloor((std.time.nanoTimestamp() - start), @as(i128, std.time.ns_per_ms))});
    }
}

fn testPruning(fen: [] const u8, me: Colour) !void {
    var game = try Board.fromFEN(fen);
    const slow = try testSlow.bestMove(&game, me);
    const fast = try testFast.bestMove(&game, me);

    if (!std.meta.eql(slow, fast)){
        // Leaks here don't really matter but freeing prevents error spam. 
        const startBoard = try game.displayString(tst);
        defer tst.free(startBoard);
        const slowBoard = try game.copyPlay(slow).displayString(tst);
        defer tst.free(slowBoard);
        const fastBoard = try game.copyPlay(fast).displayString(tst);
        defer tst.free(fastBoard);
        std.debug.print("Moves did not match.\nInitial ({} to move):\n{s}\n\nWithout pruning: \n{s}\nWith pruning: \n{s}", .{me, startBoard, slowBoard, fastBoard});
        return error.TestFailed;
    }
}

// Tests that alpha-beta pruning chooses the same best move as a raw search. 
test "simple compare pruning" {
    try testPruning("8/p7/8/8/8/4b3/P2P4/8", .White);
    try testPruning("8/p7/8/8/8/4b3/P2P4/8", .Black);

    try testPruning("7K/8/7B/8/8/8/Pq6/kN6", .White);
    try testPruning("7K/8/7B/8/8/8/Pq6/kN6", .Black);

    // TODO: it thinks a bunch of things, including hanging its queen, are eval 0. Also takes way too long to run without pruning. 
    // try testPruning("rn1q1bnr/1p2pkp1/2p2p1p/p2p1b2/1PP4P/3PQP2/P2KP1PB/RN3BNR", .White);

    try testPruning("7K/7p/8/8/8/r1q5/1P5P/k7", .White); // multiple best moves for black.     
}
