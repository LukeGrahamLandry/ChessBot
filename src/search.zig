//! Choosing the best move for a position.

const std = @import("std");
const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;
const Move = @import("board.zig").Move;
const GameOver = @import("board.zig").GameOver;
const Magic = @import("common.zig").Magic;
const Timer = @import("common.zig").Timer;
const print = @import("common.zig").print;
const panic = @import("common.zig").panic;
const assert = @import("common.zig").assert;
const nanoTimestamp = @import("common.zig").nanoTimestamp;

// TODO: carefully audit any use of usize because wasm is 32 bit!
const isWasm = @import("builtin").target.isWasm();

var notTheRng = std.rand.DefaultPrng.init(0);
var rng = notTheRng.random();

const movegen = @import("movegen.zig");
pub const genCapturesOnly = movegen.MoveFilter.CapturesOnly.get();
pub const genAllMoves = movegen.MoveFilter.Any.get();

pub const StratOpts = struct {
    doPruning: bool = true,
    doIterative: bool = true, // When false, it will play garbage moves if it runs out of time because it won't have other levels to fall back to.
    doMemo: bool = true,
};

pub const MoveErr = error{ GameOver, OutOfMemory, ForceStop, Overflow, ThisIsntThreadSafe };

// These numbers are for one depth in bestMoveIterative, not cumulative.
pub const Stats = struct {
    comptime use: bool = false,
    // Starts of looking relitively low but by the end there's about as many hits as leaf boards. also remember that a hit happens at ahigher level so saves many layers of work
    memoHits: u64 = 0, // Tried to evaluate a board and it was already in the memo table with a high enough depth.
    leafBoardsSeen: u64 = 0, // Ran out of depth and checked the simpleEval of a board.
};

const IM_MATED_EVAL: i32 = -1000000; // Add distance to prefer sooner mates
const LOWEST_EVAL: i32 = -2000000;

// This gets reset after each whole decision is done.
var upperArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
// This gets reset after checking each top level move.
var movesArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

// TODO: should use the std mutex but i'm guessing wasm freestanding wont have one? 
var stuffInUse = false;

// This uses the global arenas above so individual dudes don't need to be dropped. 
pub fn bestMove(comptime opts: StratOpts, game: *Board, maxDepth: usize, timeLimitMs: i128) !Move {
    // Because RAII stands for "the code runs when the code damn well pleases" and we don't like that in this household apparently. 
    if (stuffInUse) return error.ThisIsntThreadSafe;
    stuffInUse = true;
    defer stuffInUse = false;
    assert(memoMap != null);

    if (game.halfMoveDraw >= 100 or game.hasInsufficientMaterial()) return error.GameOver; // Draw
    const me = game.nextPlayer;

    const startTime = nanoTimestamp();
    const endTime = startTime + (timeLimitMs * std.time.ns_per_ms);
    defer _ = upperArena.reset(.retain_capacity);
    var topLevelMoves = try movegen.MoveFilter.Any.get().possibleMoves(game, me, upperArena.allocator());

    var evalGuesses = try std.ArrayList(i32).initCapacity(upperArena.allocator(), topLevelMoves.len);

    // TODO: remove this. it used to remove illigal moves but now i dont generate them.
    var m: usize = 0;
    while (m < topLevelMoves.len) {
        const move = topLevelMoves[m];
        const unMove = game.play(move);
        defer game.unplay(unMove);
        try evalGuesses.append(game.simpleEval);
        m += 1;
    }
    if (topLevelMoves.len == 0) return error.GameOver;

    var thinkTime: i128 = -1;
    var favourite: Move = topLevelMoves[0];
    const startDepth = if (opts.doIterative) 0 else maxDepth;
    for (startDepth..(maxDepth + 1)) |depth| {
        var stats: Stats = .{};
        var alpha = LOWEST_EVAL;
        var beta = -LOWEST_EVAL;
        var bestVal: i32 = LOWEST_EVAL * me.dir();
        // TODO: this is almost the same as walkEval.
        for (topLevelMoves, 0..) |move, i| {
            _ = movesArena.reset(.retain_capacity);
            const unMove = game.play(move);
            defer game.unplay(unMove);
            const eval = walkEval(opts, game, @intCast(depth), alpha, beta, movesArena.allocator(), &stats, false, endTime) catch |err| {
                if (err == error.ForceStop) {
                    // If we ran out of time, just return the best result from the last search.
                    if (nanoTimestamp() >= endTime) {
                        if (thinkTime == -1) {
                            print("Didn't even finish one layer! Playing random move! \n", .{});
                            favourite = topLevelMoves[0];
                        } else {
                            if (isWasm) print("Out of time. Using move from depth {} ({}ms)\n", .{ depth - 1, @divFloor(thinkTime, std.time.ns_per_ms) });
                        }
                        return favourite;
                    }
                }
                return err;
            };
            evalGuesses.items[i] = eval;

            // Update a/b to pass better ones to walkEval but it would never be able to prune here because the we're always the same player.
            switch (me) {
                .White => {
                    bestVal = @max(bestVal, eval);
                    alpha = @max(alpha, bestVal);
                },
                .Black => {
                    bestVal = @min(bestVal, eval);
                    beta = @min(beta, bestVal);
                },
            }
        }

        std.sort.insertionContext(0, topLevelMoves.len, PairContext{ .moves = topLevelMoves, .evals = evalGuesses.items, .me = me });
        thinkTime = nanoTimestamp() - startTime;
        favourite = topLevelMoves[0];

        // print("Searched depth {} in {} ms.\n", .{ depth, @divFloor(thinkTime, std.time.ns_per_ms) });
    }

    if (isWasm) print("Reached max depth {} in {}ms.\n", .{ maxDepth, @divFloor(thinkTime, std.time.ns_per_ms) });
    return topLevelMoves[0];
}

const PairContext = struct {
    moves: []Move,
    evals: []i32,
    me: Colour,

    // Flipped cause accending
    pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
        switch (ctx.me) {
            .White => return ctx.evals[a] > ctx.evals[b],
            .Black => return ctx.evals[a] < ctx.evals[b],
        }
    }

    pub fn swap(ctx: @This(), a: usize, b: usize) void {
        std.mem.swap(Move, &ctx.moves[a], &ctx.moves[b]);
        std.mem.swap(i32, &ctx.evals[a], &ctx.evals[b]);
    }
};

var memoMap: ?MemoTable = null;
pub var forceStop = false;

pub fn resetMemoTable() void {
   for (0..memoMap.?.buffer.len) |i| {
        memoMap.?.buffer[i].hash = 0;
    }
}

pub fn initMemoTable(memoMapSizeMB: u64) !void {
    if (memoMap) |*memo| {
        memo.deinit(std.heap.page_allocator);
    }
    memoMap = try MemoTable.initWithCapacity(memoMapSizeMB, std.heap.page_allocator);
}

// https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning
// The alpha-beta values effect lower layers, not higher layers, so passed by value.
// Returns the absolute eval of <game>, positive means white is winning, after game.nextPlayer makes a move.
// Returns error.GameOver if there were no possible moves or other draws.
// TODO: redo my captures only thing to be lookForPeace and only simpleEval if no captures on the board
pub fn walkEval(comptime opts: StratOpts, game: *Board, remaining: i32, alphaIn: i32, betaIn: i32, alloc: std.mem.Allocator, stats: *Stats, comptime capturesOnly: bool, endTime: i128) error{ OutOfMemory, ForceStop, Overflow }!i32 {
    const me = game.nextPlayer;
    if (forceStop) return error.ForceStop;
    if (remaining == 0) {
        if (comptime stats.use) stats.leafBoardsSeen += 1;
        return game.simpleEval;
    }
    if (game.halfMoveDraw >= 100 or game.hasInsufficientMaterial()) return Magic.DRAW_EVAL;
    // Getting the time at every leaf node slows it down. But don't want to wait to get all the way back to the top if we're out of time.
    // Note: since I'm not checking at top level, it just doen't limit time if maxDepth=2 but only matters if you give it <5 ms so don't care.
    // TODO: should probably do this even less often 
    if (remaining > 2 and nanoTimestamp() >= endTime) return error.ForceStop;

    var cacheHit: ?MemoValue = null;
    if (opts.doMemo) {
        if (memoMap.?.get(game)) |cached| {
            if (cached.remaining >= remaining) {
                if (comptime stats.use) stats.memoHits += 1;
                if (!opts.doPruning) assert(cached.kind == .Exact);

                switch (cached.kind) {
                    .Exact => return cached.eval,
                    .AlphaPrune => if (cached.eval <= alphaIn) return cached.eval,
                    .BetaPrune => if (cached.eval >= betaIn) return cached.eval,
                }
            }
            cacheHit = cached;
        }
    }

    // Want to mutate copies of values from parameters.
    var alpha = alphaIn;
    var beta = betaIn;

    var moves = try movegen.MoveFilter.Any.get().possibleMoves(game, me, alloc);
    defer alloc.free(moves);

    if (moves.len == 0) { // <me> can't make any moves. Either got checkmated or its a draw.
        if (game.nextPlayerInCheck()) {
            return (IM_MATED_EVAL - remaining) * me.dir();
        } else {
            return Magic.DRAW_EVAL;
        }
    }

    if (cacheHit) |cached| {
        for (0..moves.len) |i| {
            if (moves[i].from == cached.move.from and moves[i].to == cached.move.to) {
                std.mem.swap(Move, &moves[0], &moves[i]);
                break;
            }
        }
    }

    var bestVal: i32 = LOWEST_EVAL * me.dir();
    var memoKind: MemoKind = .Exact;
    var foundMove: ?Move = null;
    for (moves) |move| {
        const unMove = game.play(move);
        defer game.unplay(unMove);
        const eval = try walkEval(opts, game, remaining - 1, alpha, beta, alloc, stats, capturesOnly, endTime);
        switch (me) {
            .White => {
                bestVal = @max(bestVal, eval);
                if (bestVal == eval) foundMove = move;
                alpha = @max(alpha, bestVal);
                if (opts.doPruning and bestVal >= beta) {
                    memoKind = .BetaPrune;
                    break;
                }
            },
            .Black => {
                bestVal = @min(bestVal, eval);
                if (bestVal == eval) foundMove = move;
                beta = @min(beta, bestVal);
                if (opts.doPruning and bestVal <= alpha) {
                    memoKind = .AlphaPrune;
                    break;
                }
            },
        }
    }

    if (opts.doMemo) { // Can never get here if forceStop=true.
        memoMap.?.setAndOverwriteBucket(game, .{ .eval = bestVal, .remaining = @intCast(remaining), .move = foundMove.?, .kind = memoKind });
    }

    return bestVal;
}

pub const MemoEntry = struct {
    // squares: [64]Piece,
    hash: u64, 
    value: MemoValue,
};

const MemoKind = enum(u2) { Exact, AlphaPrune, BetaPrune };

pub const MemoValue = struct { eval: i32, remaining: i16, move: Move, kind: MemoKind };

// Sets overwrite if their buckets collide so never have to worry about it filling up with old boards.
// That also means there's no chain of bucket collissions to follow when reading a value.
// Allocates the full capacity up front so never needs to resize.
pub const MemoTable = struct {
    buffer: []MemoEntry,
    bucketMask: u64,

    // Since I force capacity to be a power of two and do the mask manually, it doesn't need to be comptime. 
    pub fn initWithCapacity(sizeMB: u64, alloc: std.mem.Allocator) !MemoTable {
        if (sizeMB == 0) return MemoTable{ .buffer = try alloc.alloc(MemoEntry, 1), .bucketMask = 0 };
        const targetCapacity: u64 = (sizeMB * 1024 * 1024) / @sizeOf(MemoEntry);
        const bits: u6 = @intCast(std.math.log2(targetCapacity));
        // WASM is 32 bit, make sure not to overflow a usize (4 GB).
        const realCapacity = @as(usize, 1) << @min(31, bits);
        if (!std.math.isPowerOfTwo(realCapacity)) panic("MemoTable calculated size is {}, not a power of two!", .{realCapacity});
        var self = MemoTable{ .buffer = try alloc.alloc(MemoEntry, realCapacity), .bucketMask = (realCapacity - 1) };
        for (0..realCapacity) |i| {
            self.buffer[i].hash = 0;
        }
        const realSizeMB = realCapacity * @sizeOf(MemoEntry) / 1024 / 1024;
        if (!@import("builtin").is_test) print("Memo table capacity is {} ({} MB).\n", .{ realCapacity, realSizeMB });
        return self;
    }

    // Must be same allocator as used to init.
    pub fn deinit(self: *MemoTable, alloc: std.mem.Allocator) void {
        alloc.free(self.buffer);
        self.buffer.len = 0;
    }

    // TODO: some heuristic for when you get to overwrite bucket? age (epoch counter) vs remaining
    pub fn setAndOverwriteBucket(self: *MemoTable, key: *const Board, value: MemoValue) void {
        const bucket: usize = @intCast(key.zoidberg & self.bucketMask);
        self.buffer[bucket] = .{
            // .squares = key.squares,
            .hash = key.zoidberg,
            .value = value,
        };
    }

    pub fn get(self: *MemoTable, key: *const Board) ?MemoValue {
        const bucket: usize = @intCast(key.zoidberg & self.bucketMask);
        if (self.buffer[bucket].hash == key.zoidberg) {
            // fuck it, we ball, 2^64 is basically infinity
            // const eql = std.mem.eql(u8, std.mem.asBytes(&key.squares), std.mem.asBytes(&self.buffer[bucket].squares));
            // if (!eql) return null;
            return self.buffer[bucket].value;
        } else {
            return null;
        }
    }
};
