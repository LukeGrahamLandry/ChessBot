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
    isCapture: bool,

    // TODO: method that factors out bounds check from try methods then calls this? make sure not to do twice in slide loops.
    pub fn irf(fromIndex: usize, toFile: usize, toRank: usize, isCapture: bool) Move {
        // std.debug.assert(fromIndex < 64 and toFile < 8 and toRank < 8);
        return .{
            .from=@truncate(fromIndex),
            .to = @truncate(toRank*8 + toFile),
            .action = .none,
            .isCapture=isCapture
        };
    }

    pub fn ii(fromIndex: u6, toIndex: u6, isCapture: bool) Move {
        return .{
            .from=fromIndex,
            .to = toIndex,
            .action = .none,
            .isCapture=isCapture
        };
    }
};

pub const HashAlgo = enum {
    // These all operate on the byte array of squares.
    Wyhash, // same algo as auto
    Fnv1a_64,
    XxHash64,
    Murmur2_64,
    CityHash64,
    // Slower because it does individual struct parts?
    StdAuto,
};

pub const CheckAlgo = enum {
    Ignore, ReverseFromKing, LookAhead
};

var notTheRng = std.rand.DefaultPrng.init(0);
var rng = notTheRng.random();

const movegen = @import("movegen.zig");
pub const genCapturesOnly = movegen.MoveFilter.CapturesOnly.get();
pub const genAllMoves = movegen.MoveFilter.Any.get();

pub const StratOpts = struct {
    maxDepth: comptime_int = 3,  // TODO: should be runtime param to bestMove so wasm can change without increasing code size. 
    doPruning: bool = true, 
    beDeterministicForTest: bool = true,  // Interesting that it's much faster with this =true. Rng is slow!
    memoMapSizeMB: usize = 20,  // Zero means don't use memo map at all. 
    memoMapFillPercent: usize = 60,  // Affects usable map capacity but not memory usage. 
    hashAlgo: HashAlgo = .CityHash64,
    checkDetection: CheckAlgo = .ReverseFromKing,
    followCaptureDepth: i32 = 5,
};

// TODO: script that tests different variations (compare speed and run correctness tests). 
pub fn Strategy(comptime opts: StratOpts) type {
    return struct {  // Start Strategy. 

pub const config = opts;
comptime { 
    assert(@sizeOf(Piece) == @sizeOf(u8)); 
    assert(opts.memoMapFillPercent <= 100);
}

pub const MemoMap = std.HashMap(Board, struct {
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
const one: u64 = 1;
pub fn inCheck(game: *Board, me: Colour, alloc: std.mem.Allocator) !bool {
    switch (opts.checkDetection) {
        .Ignore => return false,
        .LookAhead => {
            const moves = try genKingCapturesOnly.possibleMoves(game, me.other(), alloc);
            defer alloc.free(moves);
            return moves.len > 0;
        },
        .ReverseFromKing => {
            return try movegen.reverseFromKingIsInCheck(game, me);
        }
    }
}

// This has its own loop because I actually need to know which move is best which walkEval doesn't return. 
// Also means I can reset the temp allocator more often. 
pub fn bestMove(game: *Board, me: Colour) !Move {
    var alloc = upperArena.allocator();
    defer assert(upperArena.reset(.retain_capacity));
    const bestMoves = try allEqualBestMoves(game, me, alloc);
    defer bestMoves.deinit();

    // assert(bestMoves.items.len > 0 and bestMoves.items.len <= moves.len);
    // You can't just pick a deterministic random because pruning might end up with a shorter list of equal moves. 
    // Always choosing the first should be fine because pruning just cuts off the search early.
    // Generating random numbers is quite slow, so don't do it if theres only 1 option anyway. 
    const choice = if (opts.beDeterministicForTest or bestMoves.items.len == 1) 0 else rng.uintLessThanBiased(usize, bestMoves.items.len);
    return bestMoves.items[choice];
}

pub fn allEqualBestMoves(game: *Board, me: Colour, alloc: std.mem.Allocator) !std.ArrayList(Move) {
    const moves = try genAllMoves.possibleMoves(game, me, alloc);
    defer alloc.free(moves);
    if (moves.len == 0) return error.GameOver;

    // No deinit because returned
    var bestMoves = try std.ArrayList(Move).initCapacity(alloc, 50);

    var memo = MemoMap.init(alloc);
    if (useMemoMap) try memo.ensureTotalCapacity(MEMO_CAPACITY);
    defer memo.deinit();
    
    // TODO: use memo at top level? once it persists longer it must be helpful
    var bestVal: i32 = -1000000;
    var count: u64 = 0;
    for (moves) |move| {
        const unMove = try game.play(move);
        defer game.unplay(unMove);
        if (try inCheck(game, me, alloc)) continue;
        const value = -try walkEval(game, me.other(), opts.maxDepth, opts.followCaptureDepth, -99999999, -99999999, movesArena.allocator(), &count, &memo, false);  // TODO: need to catch
        if (value > bestVal) {
            bestVal = value;
            bestMoves.clearRetainingCapacity();
            try bestMoves.append(move);
        } else if (value == bestVal) {
            try bestMoves.append(move);
        }
        assert(movesArena.reset(.retain_capacity));
    }

    return bestMoves;
}

// https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning
// TODO: when hit depth, keep going but only look at captures
// The alpha-beta values effect lower layers, not higher layers, so passed by value. 
// The eval of <game>, positive means <me> is winning, assuming it is <me>'s turn. 
pub fn walkEval(game: *Board, me: Colour, remaining: i32, bigRemaining: i32, bestWhiteEvalIn: i32, bestBlackEvalIn: i32, alloc: std.mem.Allocator, count: *u64, memo: *MemoMap, comptime capturesOnly: bool) MoveErr!i32 {
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

    const moveGen = genAllMoves;
    const moves = try moveGen.possibleMoves(game, me, alloc);
    defer alloc.free(moves);
    if (moves.len == 0) return error.GameOver;
    
    var bestVal: i32 = -1000000;
    for (moves) |move| {
        const unMove = try game.play(move);
        defer game.unplay(unMove);
        if (try inCheck(game, me, alloc)) continue;

        const value = if (capturesOnly and !move.isCapture) v: {
            // TODO: this isnt quite what I want. That move wasn't a capture but that doesn't mean that the new board is safe. 
            // The problem I'm trying to solve is if you simpleEval on a board where captures are possible, the eval will be totally different next move. 
            break :v if (me == .White) genAllMoves.simpleEval(game) else -genAllMoves.simpleEval(game); 
        } else if (remaining <= 0) v: {
            if (!capturesOnly) {
                    const val = walkEval(game, me.other(), opts.maxDepth, bigRemaining, bestWhiteEval, bestBlackEval, alloc, count, memo, true) catch |err| {
                    switch (err) {
                        error.OutOfMemory => return err,
                        error.GameOver => break :v 1234567,
                    }
                };
                break :v -val;
            }
            break :v if (me == .White) genAllMoves.simpleEval(game) else -genAllMoves.simpleEval(game); 
        } else r: {
            const v = walkEval(game, me.other(), remaining - 1, bigRemaining, bestWhiteEval, bestBlackEval, alloc, count, memo, capturesOnly) catch |err| {
                switch (err) {
                    error.OutOfMemory => return err,
                    error.GameOver => break :r 1234567,
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
// TODO: tests dont pass on maxDepth=2
const testFast = Strategy(.{ .beDeterministicForTest=true, .checkDetection=.Ignore, .doPruning=true, .maxDepth=3 });
const testSlow = Strategy(.{ .beDeterministicForTest=true, .checkDetection=.Ignore, .doPruning=false, .maxDepth=3 });
const Timer = @import("bench.zig").Timer;

// TODO: this should be generic over a the strategies to compare. 
fn testPruning(fen: [] const u8, me: Colour) !void {
    var pls = std.heap.GeneralPurposeAllocator(.{}){};
    const tst = if (@import("builtin").is_test) std.testing.allocator else pls.allocator();
    _ = tst;
    var game = try Board.fromFEN(fen);
    game.nextPlayer = me; // TODO
    var t = Timer.start();
    const slow = try testSlow.bestMove(&game, me);
    const t1 = t.end();
    t = Timer.start();
    const fast = try testFast.bestMove(&game, me);
    const t2 = t.end();

    if (!std.meta.eql(slow, fast)){
        std.debug.print("Moves did not match.\nInitial ({} to move):\n", .{ me });
        game.debugPrint();
        std.debug.print("Without pruning: \n", .{});
        game.copyPlay(slow).debugPrint();
        std.debug.print("With pruning: \n", .{});
        game.copyPlay(fast).debugPrint();
        return error.TestFailed;
    }
    if (t2 > t1 or t1 > 250) std.debug.print("- testPruning (slow: {}ms, fast: {}ms) {s}\n", .{t1, t2, fen});
}

// Tests that alpha-beta pruning chooses the same best move as a raw search. 
// Doesn't check if king is in danger to ignore move. // TODO: skip if no legal moves instead 
pub fn runTestComparePruning() !void {
    // Not all of @import("movegen.zig").fensToTest because they're super slow.
    const fensToTest = [_] [] const u8 {
        "8/p7/8/8/8/4b3/P2P4/8",
        "7K/8/7B/8/8/8/Pq6/kN6",
        "7K/7p/8/8/8/r1q5/1P5P/k7", // Check and multiple best moves for black
        // "rn1q1bnr/1p2pkp1/2p2p1p/p2p1b2/1PP4P/3PQP2/P2KP1PB/RN3BNR", // hang a queen. super slow to run rn
    };
    inline for (fensToTest) |fen| {
        inline for (.{Colour.White, Colour.Black}) |me| {
            try testPruning(fen, me);
        }
    }
}

test "simple compare pruning" {
    try runTestComparePruning();
}

// When I was sharing alpha-beta values between loop iterations when making best move list, it thought all the moves were equal.  
test "bestMoves eval equal" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var quickAlloc = arena.allocator();
    inline for (@import("movegen.zig").fensToTest) |fen| {
        inline for (.{Colour.White, Colour.Black}) |me| {
            defer assert(arena.reset(.retain_capacity));
            var initial = try Board.fromFEN(fen);
            initial.nextPlayer = me; // TODO
            var game = try Board.fromFEN(fen);
            game.nextPlayer = me; // TODO
            const bestMoves = try testFast.allEqualBestMoves(&game, me, quickAlloc);

            const allMoves = try @import("movegen.zig").MoveFilter.Any.get().possibleMoves(&game, me, quickAlloc);
            try std.testing.expect(allMoves.len >= bestMoves.items.len);  // sanity
            
            var memo = testFast.MemoMap.init(quickAlloc);
            try memo.ensureTotalCapacity(10000);
            var expectedEval: ?i32 = null;
            for (bestMoves.items, 0..) |move, i| {
                const unMove = try game.play(move);
                defer game.unplay(unMove);
                try std.testing.expect(!(try testFast.inCheck(&game, me, quickAlloc)));

                var thing: usize = 0;
                // pay attention to negative sign
                const eval = -(try testFast.walkEval(&game, me.other(), testFast.config.maxDepth, testFast.config.followCaptureDepth, -99999999, -99999999, quickAlloc, &thing, &memo, false));
                if (expectedEval) |expected| {
                    if (eval != expected) {
                        std.debug.print("{} best moves but evals did not match.\nInitial ({} to move):\n", .{ bestMoves.items.len, me });
                        initial.debugPrint();
                        std.debug.print("best[0] (eval={}): \n", .{ expected});
                        initial.copyPlay(bestMoves.items[0]).debugPrint();
                        std.debug.print("best[{}]: (eval={})\n", .{ i, eval });
                        game.debugPrint();
                        return error.TestFailed;
                    }
                } else {
                    expectedEval = eval;
                }
            }

            try std.testing.expectEqual(initial, game);  // sanity check unplay function.
        }
    }
}