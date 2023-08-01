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
    trackPv: bool = false,
    followCapturesDepth: i32 = 0,  // TODO: on 3 it fails more bestmoves tests (2 seconds/pos). too slow? ignoring checks?
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

const IntListPool = @import("movegen.zig").AnyListPool(i32);
pub const SearchGlobals = struct {
    lists: ListPool,
    evalLists: IntListPool,
    memoMap: MemoTable,
    forceStop: bool = false,
    uciResults: std.ArrayList(UCI.UciResult),
    rng: std.rand.DefaultPrng,

    pub fn init(memoMapSizeMB: u64, alloc: std.mem.Allocator) !@This() {
        const seed: u64 = @truncate(@as(u128, @bitCast(nanoTimestamp())));
        return .{ .memoMap = try MemoTable.initWithCapacity(memoMapSizeMB, alloc), .lists = try ListPool.init(alloc), .evalLists = try IntListPool.init(alloc), .uciResults = std.ArrayList(UCI.UciResult).init(alloc), .rng = std.rand.DefaultPrng.init(seed) };
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
    var evals = try ctx.evalLists.get();
    defer ctx.evalLists.release(evals);

    for (topLevelMoves.items) |_| {
        try evals.append(0);
    }

    var thinkTime: i128 = -1;
    var favourite: Move = topLevelMoves.items[0];
    const startDepth = if (opts.doIterative) 0 else @min(maxDepth, 100);
    // TODO: stop iteration if there's a forced mate. doesnt matter but offends me to do pointless work
    for (startDepth..(@min(maxDepth, 100) + 1)) |depth| { // @min is sanity check for list pool capacity
        var pv = try ctx.lists.get();
        defer ctx.lists.release(pv);
        var stats: Stats = .{};
        var alpha = LOWEST_EVAL;
        var beta = -LOWEST_EVAL;
        // TODO: this is almost the same as walkEval.
        for (topLevelMoves.items, 0..) |move, i| {
            var line = try ctx.lists.get();
            defer ctx.lists.release(line);
            try line.append(move);
            const unMove = game.play(move);
            defer game.unplay(unMove);
            const eval = -(walkEval(opts, ctx, game, @intCast(depth), -beta, -alpha, &stats, false, endTime, &line) catch |err| {
                if (err == error.ForceStop) {
                    // If we ran out of time, just return the best result from the last search.
                    if (thinkTime == -1) {
                        if (isWasm) print("Didn't even finish one layer in {}ms! Playing random move! \n", .{timeLimitMs});
                        favourite = topLevelMoves.items[0];
                    } else {
                        if (isWasm) print("Out of time. Using move from depth {} ({}ms)\n", .{ depth - 1, @divFloor(thinkTime, std.time.ns_per_ms) });
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
            });
            evals.items[i] = eval;

            // Update a/b to pass better ones to walkEval but it would never be able to prune here because the we're always the same player.
            if (eval > alpha) {
                alpha = eval;
                if (opts.trackPv) {
                    pv.items.len = line.items.len;
                    @memcpy(pv.items, line.items);
                }
            }
        }

        if (opts.trackPv) assert(pv.items.len > 0); // There must be some best line.

        std.sort.insertionContext(0, topLevelMoves.items.len, PairContext{ .moves = topLevelMoves.items, .evals = evals.items });
        thinkTime = nanoTimestamp() - startTime;

        // Using topLevelMoves.items[0] passed my simple test by coincidence because I put captures first in the list
        // so it chooses those over other moves it thinks are equal. I want to use pv because then the move played matches.
        // But that reveals it thinks hanging pieces beyond depth is fine.
        favourite = topLevelMoves.items[0]; // pv.items[0] // remember to use the right score

        if (opts.printUci) {
            var str = try std.BoundedArray(u8, 10000).init(0);
            if (opts.trackPv) {
                for (pv.items) |move| {
                    if ((try move.text())[4] == 0) {
                        try str.appendSlice((try move.text())[0..4]);
                    } else {
                        try str.appendSlice((try move.text())[0..]);
                    }

                    try str.append(' ');
                }
            } else {
                try str.appendSlice((try favourite.text())[0..4]);
            }

            // TODO: report mate distance. don't mind branches here because its only at the top level. 
            const info: UCI.UciInfo = .{ .time = @intCast(@divFloor(thinkTime, std.time.ns_per_ms)), .depth = @intCast(depth + 1), .pvFirstMove = UCI.writeAlgebraic(favourite), .cp = evals.items[0], .pv = str.slice() };
            const result: UCI.UciResult = .{ .Info = info };
            // try ctx.uciResults.append(result);
            try result.writeTo(std.io.getStdOut().writer());
        }
    }

    if (opts.printUci) {
        const result: UCI.UciResult = .{ .BestMove = UCI.writeAlgebraic(favourite) };
        // try ctx.uciResults.append(result);
        try result.writeTo(std.io.getStdOut().writer());
    }
    if (isWasm) print("Reached max depth {} in {}ms.\n", .{ maxDepth, @divFloor(thinkTime, std.time.ns_per_ms) });

    return favourite;
}

pub const PairContext = struct {
    moves: []Move,
    evals: []i32,

    // Flipped cause accending
    pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
        return ctx.evals[a] > ctx.evals[b];
    }

    pub fn swap(ctx: @This(), a: usize, b: usize) void {
        std.mem.swap(Move, &ctx.moves[a], &ctx.moves[b]);
        std.mem.swap(i32, &ctx.evals[a], &ctx.evals[b]);
    }
};

// https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning
// The alpha-beta values effect lower layers, not higher layers, so passed by value.
// Returns the relative eval of <game>, positive means current player is winning, after game.nextPlayer makes a move.
// Returns error.GameOver if there were no possible moves or other draws.
// TODO: pv doesnt need to copy the whole list every time
pub fn walkEval(comptime opts: StratOpts, ctx: *SearchGlobals, game: *Board, remaining: i32, alphaIn: i32, betaIn: i32, stats: *Stats, comptime capturesOnly: bool, endTime: i128, line: *ListPool.List) error{ OutOfMemory, ForceStop, Overflow }!i32 {
    const me = game.nextPlayer;
    if (ctx.forceStop) return error.ForceStop;
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
                if (!opts.doPruning) assert(cached.kind != .BetaPrune);

                switch (cached.kind) {
                    .Exact => return cached.eval * me.dir(),
                    .BetaPrune => if ((cached.eval * me.dir()) >= betaIn) return cached.eval * me.dir(),
                    .AlphaIgnore => if ((cached.eval * me.dir()) <= alphaIn) return (cached.eval * me.dir()), // TODO: ?
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
            return (IM_MATED_EVAL - remaining);
        } else {
            return Learned.DRAW_EVAL;
        }
    }

    // If you add this you can to remove the ordering in movegen.addMoveOrdered 
    // if (opts.followCapturesDepth > 0 or remaining > 1) {
    //     try @import("movegen.zig").reorderMoves(game, &moves, &ctx.evalLists, cacheHit);
    // }

    if (cacheHit) |cached| {
        if (cached.move) |move| {
            for (0..moves.items.len) |i| {
                if (moves.items[i].from == move.from and moves.items[i].to == move.to) {
                    std.mem.swap(Move, &moves.items[0], &moves.items[i]);
                    break;
                }
            }
        }
    } 

    var foundMove: ?Move = null;
    var pv = if (opts.trackPv) ctx.lists.copyOf(line) else try ctx.lists.get();
    defer ctx.lists.release(pv);
    for (moves.items) |move| {
        var nextLine = if (opts.trackPv) ctx.lists.copyOf(line) else try ctx.lists.get();
        defer ctx.lists.release(nextLine);
        try nextLine.append(move);

        const eval = e: {
            if (remaining > 1) { // TODO: decide if this should be 0 or 1
                const unMove = game.play(move);
                defer game.unplay(unMove);
                break :e -(try walkEval(opts, ctx, game, remaining - 1, -beta, -alpha, stats, capturesOnly, endTime, &nextLine));
            } else {
                if (opts.followCapturesDepth > 0) {
                    const unMove = game.play(move);
                    defer game.unplay(unMove);
                    break :e -(try lookForPeace(opts, ctx, game, opts.followCapturesDepth, -beta, -alpha, &nextLine));
                } else {
                    const unMove = game.playNoUpdateChecks(move);
                    defer game.unplay(unMove);
                    break :e game.simpleEval * me.dir();
                }
            }
        };

        if (eval > alpha) {
            alpha = eval;
            foundMove = move;
            if (opts.trackPv) {
                pv.items.len = nextLine.items.len;
                @memcpy(pv.items, nextLine.items);
            }
        }

        if (opts.doPruning and eval >= beta) {
            // That move made this subtree super good so we probably won't get here.
            if (opts.trackPv) {
                line.items.len = nextLine.items.len;
                @memcpy(line.items, nextLine.items);
            }

            if (opts.doMemo) { // Can never get here if forceStop=true.
                ctx.memoMap.setAndOverwriteBucket(game, .{ .eval = eval * me.dir(), .remaining = @intCast(remaining), .move = move, .kind = .BetaPrune });
            }
            return beta;
        }
    }

    if (opts.doMemo) { // Can never get here if forceStop=true.
        if (foundMove) |move| {
            ctx.memoMap.setAndOverwriteBucket(game, .{ .eval = alpha * me.dir(), .remaining = @intCast(remaining), .move = move, .kind = .Exact });
        } else {
            // No move was good enough to make this subtree interesting
            ctx.memoMap.setAndOverwriteBucket(game, .{ .eval = alpha * me.dir(), .remaining = @intCast(remaining), .move = null, .kind = .AlphaIgnore });
        }
    }

    if (opts.trackPv) {
        line.items.len = pv.items.len;
        @memcpy(line.items, pv.items);
    }
    return alpha;
}

// TODO: should this use the memo table? need flag to indicate it didn't consider all moves so walkEval can't trust it 
// TODO: this is so similar to normal walkEval, can they be merged without making it more confusing? 
pub fn lookForPeace(comptime opts: StratOpts, ctx: *SearchGlobals, game: *Board, remaining: i32, alphaIn: i32, betaIn: i32, line: *ListPool.List) error{ OutOfMemory, ForceStop, Overflow }!i32 {
    const me = game.nextPlayer;
    if (ctx.forceStop) return error.ForceStop;
    if (remaining == 0) {
        return game.simpleEval * me.dir();
    }
    if (game.halfMoveDraw >= 100 or game.hasInsufficientMaterial() or game.lastMoveWasRepetition()) return Learned.DRAW_EVAL * game.nextPlayer.dir();

    // Want to mutate copies of values from parameters.
    var alpha = alphaIn;
    var beta = betaIn;

    const base = game.simpleEval * me.dir();
    if (base >= beta) {
        return beta;
    }
    if (alpha < base) {
        alpha = base;
    }

    var moves = try movegen.capturesOnlyMoves(game, me, &ctx.lists);
    defer ctx.lists.release(moves);

    if (moves.items.len == 0) { // <me> can't make any moves. Either got checkmated or its a draw.
        if (game.nextPlayerInCheck()) {
            return (IM_MATED_EVAL - remaining);
        } else {
            return Learned.DRAW_EVAL;
        }
    }

    var pv = if (opts.trackPv) ctx.lists.copyOf(line) else try ctx.lists.get();
    defer ctx.lists.release(pv);
    for (moves.items) |move| {
        assert(move.isCapture);
        var nextLine = if (opts.trackPv) ctx.lists.copyOf(line) else try ctx.lists.get();
        defer ctx.lists.release(nextLine);
        try nextLine.append(move);
        const eval = e: {
            if (remaining > 1) {
                const unMove = game.play(move);
                defer game.unplay(unMove);
                break :e -(try lookForPeace(opts, ctx, game, remaining - 1, -beta, -alpha, &nextLine));
            } else {
                // Don't need to do the extra work to prep for legal move generation if this is a leaf node.
                // This trick was the justification for switching from pseudo-legal generation.
                const unMove = game.playNoUpdateChecks(move);
                defer game.unplay(unMove);
                break :e game.simpleEval * me.dir();
            }
        };

        if (eval > alpha) {
            alpha = eval;
            if (opts.trackPv) {
                pv.items.len = nextLine.items.len;
                @memcpy(pv.items, nextLine.items);
            }
        }

        if (opts.doPruning and eval >= beta) {
            // That move made this subtree super good so we probably won't get here.
            if (opts.trackPv) {
                line.items.len = nextLine.items.len;
                @memcpy(line.items, nextLine.items);
            }
            return beta;
        }
    }

    if (opts.trackPv) {
        line.items.len = pv.items.len;
        @memcpy(line.items, pv.items);
    }
    return alpha;
}

pub const MemoEntry = struct {
    // squares: [64]Piece,
    hash: u64,
    value: MemoValue,
};

const MemoKind = enum(u2) { Exact, AlphaIgnore, BetaPrune };

pub const MemoValue = struct { eval: i32, remaining: i16, move: ?Move, kind: MemoKind };

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
