//! Choosing the best move for a position.

const std = @import("std");
const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;
const Move = @import("board.zig").Move;
const GameOver = @import("board.zig").GameOver;
const Learned = @import("learned.zig");
const Timer = @import("common.zig").Timer;
const print = @import("common.zig").print;
const panic = @import("common.zig").panic;
const assert = @import("common.zig").assert;
const nanoTimestamp = @import("common.zig").nanoTimestamp;
const ListPool = @import("movegen.zig").ListPool;
const UCI = @import("uci.zig");

// TODO: carefully audit any use of usize because wasm is 32 bit!
const isWasm = @import("builtin").target.isWasm();

const movegen = @import("movegen.zig");

pub const StratOpts = struct {
    doPruning: bool = true,
    doIterative: bool = true, // When false, it will play garbage moves if it runs out of time because it won't have other levels to fall back to.
    doMemo: bool = true,
    printUci: bool = false,
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

pub const SearchGlobals = struct {
    lists: ListPool,
    evalGuesses: std.ArrayList(i32),
    memoMap: MemoTable,
    forceStop: bool = false,
    uciResults: std.ArrayList(UCI.UciResult),
    rng: std.rand.DefaultPrng,

    pub fn init(memoMapSizeMB: u64, alloc: std.mem.Allocator) !@This() {
        const seed: u64 = @truncate(@as(u128, @bitCast(nanoTimestamp())));
        return .{ .memoMap = try MemoTable.initWithCapacity(memoMapSizeMB, alloc), .evalGuesses = try std.ArrayList(i32).initCapacity(alloc, 50), .lists = try ListPool.init(alloc), .uciResults = std.ArrayList(UCI.UciResult).init(alloc), .rng = std.rand.DefaultPrng.init(seed) };
    }

    pub fn resetMemoTable(self: *@This()) void {
        for (0..self.memoMap.buffer.len) |i| {
            self.memoMap.buffer[i].hash = 0;
        }
    }
};

pub fn bestMove(comptime opts: StratOpts, ctx: *SearchGlobals, game: *Board, maxDepth: usize, timeLimitMs: i128) !Move {
    if (!opts.printUci and (game.halfMoveDraw >= 100 or game.hasInsufficientMaterial() or game.lastMoveWasRepetition())) return error.GameOver; // Draw
    const me = game.nextPlayer;
    assert(ctx.lists.noneLost());

    const startTime = nanoTimestamp();
    const endTime = startTime + (timeLimitMs * std.time.ns_per_ms);
    var topLevelMoves = try movegen.possibleMoves(game, me, &ctx.lists);
    defer ctx.lists.release(topLevelMoves);
    if (topLevelMoves.items.len == 0) {
        if (opts.printUci) {
            const result: UCI.UciResult = .{ .BestMove = null };
            // try ctx.uciResults.append(result);
            try result.writeTo(std.io.getStdOut().writer());
        }
        return error.GameOver;
    }

    try ctx.evalGuesses.ensureTotalCapacity(topLevelMoves.items.len);
    defer ctx.evalGuesses.clearRetainingCapacity();

    for (topLevelMoves.items) |_| {
        try ctx.evalGuesses.append(0);
    }

    var thinkTime: i128 = -1;
    var favourite: Move = topLevelMoves.items[0];
    const startDepth = if (opts.doIterative) 0 else @min(maxDepth, 100);
    for (startDepth..(@min(maxDepth, 100) + 1)) |depth| { // @min is sanity check for list pool capacity
        var pv = try ctx.lists.get();
        var stats: Stats = .{};
        var alpha = LOWEST_EVAL;
        var beta = -LOWEST_EVAL;
        var bestVal: i32 = LOWEST_EVAL * me.dir();
        // TODO: this is almost the same as walkEval.
        for (topLevelMoves.items, 0..) |move, i| {
            var line = try ctx.lists.get();
            try line.append(move);
            const unMove = game.play(move);
            defer game.unplay(unMove);
            const eval = walkEval(opts, ctx, game, @intCast(depth), alpha, beta, &stats, false, endTime, &line) catch |err| {
                ctx.lists.release(pv);
                ctx.lists.release(line);
                if (err == error.ForceStop) {
                    // If we ran out of time, just return the best result from the last search.
                    if (thinkTime == -1) {
                        print("Didn't even finish one layer in {}ms! Playing random move! \n", .{timeLimitMs});
                        favourite = topLevelMoves.items[0];
                    } else {
                        print("Out of time. Using move from depth {} ({}ms)\n", .{ depth - 1, @divFloor(thinkTime, std.time.ns_per_ms) });
                    }
                    if (opts.printUci) {
                        const result: UCI.UciResult = .{ .BestMove = UCI.writeAlgebraic(favourite) };
                        // try ctx.uciResults.append(result);
                        try result.writeTo(std.io.getStdOut().writer());
                    }
                    return favourite;
                } else {
                    return err;
                }
            };
            ctx.evalGuesses.items[i] = eval;

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

            if (eval == bestVal) {
                pv.items.len = line.items.len;
                @memcpy(pv.items, line.items);
            }
            ctx.lists.release(line);
        }

        std.sort.insertionContext(0, topLevelMoves.items.len, PairContext{ .moves = topLevelMoves.items, .evals = ctx.evalGuesses.items, .me = me });
        thinkTime = nanoTimestamp() - startTime;
        favourite = pv.items[0]; // topLevelMoves.items[0]; //

        if (opts.printUci) {
            var str = try std.BoundedArray(u8, 10000).init(0);
            for (pv.items) |move| {
                if ((try move.text())[4] == 0) {
                    try str.appendSlice((try move.text())[0..4]);
                } else {
                    try str.appendSlice((try move.text())[0..]);
                }

                try str.append(' ');
            }

            const info: UCI.UciInfo = .{ .time = @intCast(@divFloor(thinkTime, std.time.ns_per_ms)), .depth = @intCast(depth + 1), .pvFirstMove = UCI.writeAlgebraic(favourite), .cp = ctx.evalGuesses.items[0], .pv = str.slice() };
            const result: UCI.UciResult = .{ .Info = info };
            // try ctx.uciResults.append(result);
            try result.writeTo(std.io.getStdOut().writer());
        }
        ctx.lists.release(pv);
    }

    if (opts.printUci) {
        const result: UCI.UciResult = .{ .BestMove = UCI.writeAlgebraic(favourite) };
        // try ctx.uciResults.append(result);
        try result.writeTo(std.io.getStdOut().writer());
    }
    print("Reached max depth {} in {}ms.\n", .{ maxDepth, @divFloor(thinkTime, std.time.ns_per_ms) });

    return favourite;
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

// https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning
// The alpha-beta values effect lower layers, not higher layers, so passed by value.
// Returns the absolute eval of <game>, positive means white is winning, after game.nextPlayer makes a move.
// Returns error.GameOver if there were no possible moves or other draws.
// TODO: redo my captures only thing to be lookForPeace and only simpleEval if no captures on the board
// TODO: pv doesnt need to copy the whole list every time
pub fn walkEval(comptime opts: StratOpts, ctx: *SearchGlobals, game: *Board, remaining: i32, alphaIn: i32, betaIn: i32, stats: *Stats, comptime capturesOnly: bool, endTime: i128, line: *ListPool.List) error{ OutOfMemory, ForceStop, Overflow }!i32 {
    const me = game.nextPlayer;
    if (ctx.forceStop) return error.ForceStop;
    if (remaining == 0) {
        if (comptime stats.use) stats.leafBoardsSeen += 1;
        return game.simpleEval;
    }
    if (game.halfMoveDraw >= 100 or game.hasInsufficientMaterial() or game.lastMoveWasRepetition()) return Learned.DRAW_EVAL * game.nextPlayer.dir();
    // Getting the time at every leaf node slows it down. But don't want to wait to get all the way back to the top if we're out of time.
    // Note: since I'm not checking at top level, it just doen't limit time if maxDepth=2 but only matters if you give it <5 ms so don't care.
    // TODO: should probably do this even less often
    if (remaining > 2 and nanoTimestamp() >= endTime) return error.ForceStop;

    var cacheHit: ?MemoValue = null;
    if (opts.doMemo) {
        if (ctx.memoMap.get(game)) |cached| {
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

    var moves = try movegen.possibleMoves(game, me, &ctx.lists);
    defer ctx.lists.release(moves);

    if (moves.items.len == 0) { // <me> can't make any moves. Either got checkmated or its a draw.
        if (game.nextPlayerInCheck()) {
            return (IM_MATED_EVAL - remaining) * me.dir();
        } else {
            return Learned.DRAW_EVAL;
        }
    }

    if (cacheHit) |cached| {
        for (0..moves.items.len) |i| {
            if (moves.items[i].from == cached.move.from and moves.items[i].to == cached.move.to) {
                std.mem.swap(Move, &moves.items[0], &moves.items[i]);
                break;
            }
        }
    }

    var bestVal: i32 = LOWEST_EVAL * me.dir();
    var memoKind: MemoKind = .Exact;
    var foundMove: ?Move = null;
    var pv = ctx.lists.copyOf(line);
    defer ctx.lists.release(pv);
    for (moves.items) |move| {
        var nextLine = ctx.lists.copyOf(line);
        defer ctx.lists.release(nextLine);
        try nextLine.append(move);
        const eval = e: {
            if (remaining > 1) {
                const unMove = game.play(move);
                defer game.unplay(unMove);
                break :e try walkEval(opts, ctx, game, remaining - 1, alpha, beta, stats, capturesOnly, endTime, &nextLine);
            } else {
                // Don't need to do the extra work to prep for legal move generation if this is a leaf node.
                // This trick was the justification for switching from pseudo-legal generation.
                const unMove = game.playNoUpdateChecks(move);
                defer game.unplay(unMove);
                break :e game.simpleEval;
            }
        };

        switch (me) {
            .White => {
                bestVal = @max(bestVal, eval);
                if (bestVal == eval) {
                    foundMove = move;
                    pv.items.len = nextLine.items.len;
                    @memcpy(pv.items, nextLine.items);
                }
                alpha = @max(alpha, bestVal);
                if (opts.doPruning and bestVal >= beta) {
                    memoKind = .BetaPrune;
                    break;
                }
            },
            .Black => {
                bestVal = @min(bestVal, eval);
                if (bestVal == eval) {
                    foundMove = move;
                    pv.items.len = nextLine.items.len;
                    @memcpy(pv.items, nextLine.items);
                }
                beta = @min(beta, bestVal);
                if (opts.doPruning and bestVal <= alpha) {
                    memoKind = .AlphaPrune;
                    break;
                }
            },
        }
    }

    if (opts.doMemo) { // Can never get here if forceStop=true.
        ctx.memoMap.setAndOverwriteBucket(game, .{ .eval = bestVal, .remaining = @intCast(remaining), .move = foundMove.?, .kind = memoKind });
    }

    line.items.len = pv.items.len;
    @memcpy(line.items, pv.items);
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
