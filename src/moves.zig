const std = @import("std");
const assert = std.debug.assert;

const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;

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
    pub fn irf(fromIndex: usize, toFile: usize, toRank: usize) Move {
        // std.debug.assert(fromIndex < 64 and toFile < 8 and toRank < 8);
        return .{
            .from=@truncate(fromIndex),
            .to = @truncate(toRank*8 + toFile),
            .action = .none,
        };
    }
};

pub const HashAlgo = enum {
    // Slower because it does individual struct parts?
    StdAuto,
    // These all operate on the byte array of squares.
    Wyhash, // same algo as auto
    Fnv1a_64,
    XxHash64,
    Murmur2_64,
    CityHash64,
};

var notTheRng = std.rand.DefaultPrng.init(0);
var rng = notTheRng.random();

pub const genAllMoves = @import("movegen.zig").MoveFilter.Any.get();

pub const StratOpts = struct {
    maxDepth: comptime_int = 4,  // TODO: should be runtime param to bestMove so wasm can change without increasing code size. 
    doPruning: bool = true, 
    beDeterministicForTest: bool = false,  // Interesting that it's much faster with this =true. Rng is slow!
    memoMapSizeMB: usize = 20,  // Zero means don't use memo map at all. 
    memoMapFillPercent: usize = 60,  // Affects usable map capacity but not memory usage. 
    hashAlgo: HashAlgo = .CityHash64,
    checkDetection: enum {
        Ignore, LookAhead
    } = .Ignore,
};

// TODO: script that tests different variations (compare speed and run correctness tests). 
pub fn Strategy(comptime opts: StratOpts) type {
    return struct {  // Start Strategy. 

comptime { 
    assert(@sizeOf(Piece) == @sizeOf(u8)); 
    assert(opts.memoMapFillPercent <= 100);
}

const MemoMap = std.HashMap(Board, struct {
    eval: i32,
    remaining: i32
}, struct {
    // TODO: don't include padding bytes, try Zobrist. 
    pub fn hash(ctx: @This(), key: Board) u64 {
        const data = std.mem.asBytes(&key.squares);  
        return switch (comptime opts.hashAlgo) {
            .StdAuto => (comptime std.hash_map.getAutoHashFn(Board, @This()))(ctx, key), 
            .Wyhash => std.hash.Wyhash.hash(0, data),
            .Fnv1a_64 => std.hash.Fnv1a_64.hash(data),
            .XxHash64 => std.hash.XxHash64.hash(0, data),
            .Murmur2_64 => std.hash.Murmur2_64.hash(data),
            .CityHash64 => std.hash.CityHash64.hash(data),
        };
    }
    
    pub fn eql(_: @This(), a: Board, b: Board) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a.squares), std.mem.asBytes(&b.squares));
    }
}, opts.memoMapFillPercent);  

const useMemoMap = opts.memoMapSizeMB > 0 and opts.memoMapFillPercent > 0;
// TODO: this wont be exact because capacity goes to the next highest power of two. 
const MEMO_CAPACITY = if (useMemoMap) (opts.memoMapSizeMB * 1024 * 1024) / @sizeOf(MemoMap.KV) * 100 / opts.memoMapFillPercent else 0;

// This gets reset after each whole decision is done.
var upperArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
// This gets reset after checking each top level move. 
var movesArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const genKingCapturesOnly = @import("movegen.zig").MoveFilter.KingCapturesOnly.get();
fn inCheck(game: *Board, me: Colour, alloc: std.mem.Allocator) !bool {
    switch (opts.checkDetection) {
        .Ignore => return false,
        .LookAhead => {
            const moves = try genKingCapturesOnly.possibleMoves(game, me.other(), alloc);
            defer alloc.free(moves);
            return moves.len > 0;
        }
    }
}

// This has its own loop because I actually need to know which move is best which walkEval doesn't return. 
// Also means I can reset the temp allocator more often. 
pub fn bestMove(game: *Board, me: Colour) !Move {
    var alloc = upperArena.allocator();
    defer assert(upperArena.reset(.retain_capacity));
    
    const moves = try genAllMoves.possibleMoves(game, me, alloc);
    defer alloc.free(moves);
    if (moves.len == 0) return error.GameOver;
    var bestMoves = try std.ArrayList(Move).initCapacity(alloc, 50);
    defer bestMoves.deinit();

    var memo = MemoMap.init(alloc);
    if (useMemoMap) try memo.ensureTotalCapacity(MEMO_CAPACITY);
    defer memo.deinit();

    var bestWhiteEval: i32 = -99999999;
    var bestBlackEval: i32 = -99999999;
    
    // TODO: use memo at top level? once it persists longer it must be helpful
    var bestVal: i32 = -1000000;
    var count: u64 = 0;
    for (moves) |move| {
        const unMove = try game.play(move);
        defer game.unplay(unMove);
        if (try inCheck(game, me, alloc)) continue;
        const value = -try walkEval(game, me.other(), opts.maxDepth, bestWhiteEval, bestBlackEval, movesArena.allocator(), &count, &memo);  // TODO: need to catch
        if (value > bestVal) {
            bestVal = value;
            bestMoves.clearRetainingCapacity();
            try bestMoves.append(move);
            if (opts.doPruning and checkAlphaBeta(bestVal, me, &bestWhiteEval, &bestBlackEval)) break;
        } else if (value == bestVal) {
            try bestMoves.append(move);
        }
        assert(movesArena.reset(.retain_capacity));
    }

    // assert(bestMoves.items.len > 0 and bestMoves.items.len <= moves.len);
    // You can't just pick a deterministic random because pruning might end up with a shorter list of equal moves. 
    // Always choosing the first should be fine because pruning just cuts off the search early.
    // Generating random numbers is quite slow, so don't do it if theres only 1 option anyway. 
    const choice = if (opts.beDeterministicForTest or bestMoves.items.len == 1) 0 else rng.uintLessThanBiased(usize,  bestMoves.items.len);
    if (!isWasm and !opts.beDeterministicForTest) {
        std.debug.print("- Checked {} end states. {} boards in memo table (max={}). {} moves with eval {}.\n", .{count, memo.count(), memo.capacity(), bestMoves.items.len, bestVal});
    }
    return bestMoves.items[choice];
}

// https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning
// TODO: when hit depth, keep going but only look at captures
// The alpha-beta values effect lower layers, not higher layers, so passed by value. 
fn walkEval(game: *Board, me: Colour, remaining: i32, bestWhiteEvalIn: i32, bestBlackEvalIn: i32, alloc: std.mem.Allocator, count: *u64, memo: *MemoMap) MoveErr!i32 {
    // After alpha-beta, bigger starting cap, and not reallocating each move, this does make it faster. 
    // Makes Black move 4 end states go 16,000,000 -> 1,000,000
    // But now after better pruning it does almost nothing. 
    if (useMemoMap) {
        if (memo.get(game.*)) |cached| {
            if (cached.remaining >= remaining){
                return if (me == .White) cached.eval else -cached.eval;
            }
            // TODO: should save the best move from that position at the old low depth and use it as the start for the search 
        }
    }

    // Want to mutate values from parameters. 
    var bestWhiteEval = bestWhiteEvalIn;
    var bestBlackEval = bestBlackEvalIn;

    const moves = try genAllMoves.possibleMoves(game, me, alloc);
    defer alloc.free(moves);
    if (moves.len == 0) return error.GameOver;
    
    var bestVal: i32 = -1000000;
    for (moves) |move| {
        const unMove = try game.play(move);
        defer game.unplay(unMove);
        if (try inCheck(game, me, alloc)) continue;
        const value = if (remaining == 0) e: {
            if (!isWasm) count.* += 1;
            break :e if (me == .White) genAllMoves.simpleEval(game) else -genAllMoves.simpleEval(game);
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
            if (opts.doPruning and checkAlphaBeta(bestVal, me, &bestWhiteEval, &bestBlackEval)) break;
        }
    }

    // TODO: I want to not reset the table between moves but then when it runs out of space it would be full of positions we don't need anymore.
    //       need to get rid of old ones somehow. maybe my own hash map that just overwrites on collissions? 
    // Don't need to check `and memo.capacity() > MEMO_CAPACITY` because we allocate the desired capacity up front.
    if (useMemoMap){
        const memoFull = memo.unmanaged.available == 0;
        if (!memoFull) {
            try memo.put(game.*, .{
                .eval = if (me == .White) bestVal else -bestVal,
                .remaining = remaining,
            });
        }
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

};} // End Strategy. 

pub const default = Strategy(.{});
const testFast = Strategy(.{ .beDeterministicForTest=true, .checkDetection=.Ignore});
const testSlow = Strategy(.{ .beDeterministicForTest=true, .doPruning=false, .checkDetection=.Ignore});
const Timer = @import("bench.zig").Timer;

// TODO: this should be generic over a the strategies to compare. 
fn testPruning(fen: [] const u8, me: Colour) !void {
    const tst = std.testing.allocator;
    var game = try Board.fromFEN(fen, tst);
    defer game.deinit();
    var t = Timer.start();
    const slow = try testSlow.bestMove(&game, me);
    const t1 = t.end();
    t = Timer.start();
    const fast = try testFast.bestMove(&game, me);
    const t2 = t.end();

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
    std.debug.print("\n- testPruning (slow: {}ms, fast: {}ms) {s}", .{t1, t2, fen});
}

// Tests that alpha-beta pruning chooses the same best move as a raw search. 
// Doesn't check if king is in danger to ignore move. 
test "simple compare pruning" {
    // The initial position has many equal moves, this makes sure I'm not accidently making random choices while testing. 
    try testPruning("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR", .White);
    try testPruning("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR", .Black);

    try testPruning("8/p7/8/8/8/4b3/P2P4/8", .White);
    try testPruning("8/p7/8/8/8/4b3/P2P4/8", .Black);

    try testPruning("7K/8/7B/8/8/8/Pq6/kN6", .White);
    try testPruning("7K/8/7B/8/8/8/Pq6/kN6", .Black);

    // TODO: it thinks a bunch of things, including hanging its queen, are eval 0. Also takes way too long to run without pruning. 
    // try testPruning("rn1q1bnr/1p2pkp1/2p2p1p/p2p1b2/1PP4P/3PQP2/P2KP1PB/RN3BNR", .White);

    try testPruning("7K/7p/8/8/8/r1q5/1P5P/k7", .White); // TODO: check and multiple best moves for black.    
}
