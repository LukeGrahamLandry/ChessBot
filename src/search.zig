//! Choosing the best move for a position.

const std = @import("std");
const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;
const Move = @import("board.zig").Move;
const GameOver = @import("board.zig").GameOver;
const Magic = @import("magic.zig");
const Timer = @import("common.zig").Timer;
const print = @import("common.zig").print;
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
    memoMapSizeMB: u64 = 100, // TODO: runtime so can set this in ui?
};

pub const MoveErr = error{ GameOver, OutOfMemory, ForceStop, Overflow };

// These numbers are for one depth in bestMoveIterative, not cumulative.
pub const Stats = struct {
    comptime use: bool = false,
    // Starts of looking relitively low but by the end there's about as many hits as leaf boards. also remember that a hit happens at ahigher level so saves many layers of work
    memoHits: u64 = 0, // Tried to evaluate a board and it was already in the memo table with a high enough depth.
    leafBoardsSeen: u64 = 0, // Ran out of depth and checked the simpleEval of a board.
};

const IM_MATED_EVAL: i32 = -1000000; // Add distance to prefer sooner mates
const LOWEST_EVAL: i32 = -2000000;

// TODO: opts can just be an arg to bestMove and walkEval
pub fn Strategy(comptime opts: StratOpts) type {
    return struct {
        pub const config = opts;
        const useMemoMap = opts.doMemo and opts.memoMapSizeMB > 0;

        // None of this is thread safe!
        // This gets reset after each whole decision is done.
        var upperArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        // This gets reset after checking each top level move.
        var movesArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

        // TODO: a bunch of sanity check regression tests for simple positions that have an obvious best move
        // TODO: flag to start at max depth to confirm that iterative is comparably fast because of better ordering
        // TODO: make it more clear when in an arena and dont bother freeing.
        pub fn bestMove(game: *Board, maxDepth: usize, timeLimitMs: i128, lines_out: anytype) !Move {
            if (game.halfMoveDraw >= 100 or game.hasInsufficientMaterial()) return error.GameOver; // Draw
            const me = game.nextPlayer;

            const startTime = nanoTimestamp();
            const endTime = startTime + (timeLimitMs * std.time.ns_per_ms);
            defer _ = upperArena.reset(.retain_capacity);
            // TODO: do this in global init
            if (memoMap == null) memoMap = try MemoTable.initWithCapacity(opts.memoMapSizeMB, std.heap.page_allocator);

            var topLevelMoves = try genAllMoves.possibleMoves(game, me, upperArena.allocator());
            defer upperArena.allocator().free(topLevelMoves);

            const LineTracker = @TypeOf(lines_out.*.?);
            var prevLines = try LineTracker.init(game, std.heap.page_allocator);
            var currentLines = try LineTracker.init(game, std.heap.page_allocator);

            var evalGuesses = try std.ArrayList(i32).initCapacity(upperArena.allocator(), topLevelMoves.len);
            defer evalGuesses.deinit();

            // Remove illigal moves.
            var m: usize = 0;
            while (m < topLevelMoves.len) {
                const move = topLevelMoves[m];
                const unMove = game.play(move);
                defer game.unplay(unMove);
                if (game.inCheck(me)) {
                    // TODO: leak but arena
                    std.mem.swap(Move, &topLevelMoves[topLevelMoves.len - 1], &topLevelMoves[m]);
                    topLevelMoves.len -= 1;
                } else {
                    try evalGuesses.append(game.simpleEval);
                    m += 1;
                }
            }
            if (topLevelMoves.len == 0) return error.GameOver;

            var thinkTime: i128 = -1;
            var favourite: Move = topLevelMoves[0];
            const startDepth = if (opts.doIterative) 0 else maxDepth;
            for (startDepth..(maxDepth + 1)) |depth| {
                var stats: Stats = .{};
                currentLines.depth = depth;
                var alpha = LOWEST_EVAL;
                var beta = -LOWEST_EVAL;
                var bestVal: i32 = LOWEST_EVAL * me.dir();
                // TODO: this is almost the same as walkEval.
                for (topLevelMoves, 0..) |move, i| {
                    _ = movesArena.reset(.retain_capacity);
                    const unMove = game.play(move);
                    defer game.unplay(unMove);
                    var line = try currentLines.makeChild(move, @intCast(depth + 1), alpha, beta);
                    const eval = walkEval(game, @intCast(depth), alpha, beta, movesArena.allocator(), &stats, false, &line, endTime) catch |err| {
                        if (err == error.ForceStop) {
                            // If we ran out of time, just return the best result from the last search.
                            if (nanoTimestamp() >= endTime) {
                                if (thinkTime == -1) {
                                    if (isWasm) print("Didn't even finish one layer!\n", .{});
                                    sortMoves(game, topLevelMoves);
                                    favourite = topLevelMoves[0];
                                    prevLines.deinit();
                                } else {
                                    lines_out.* = prevLines;
                                    if (isWasm) print("Out of time. Using move from depth {} ({}ms)\n", .{ depth - 1, @divFloor(thinkTime, std.time.ns_per_ms) });
                                }
                                currentLines.deinit();
                                return favourite;
                            }
                        }
                        return err;
                    };
                    evalGuesses.items[i] = eval;
                    line.eval = eval;
                    try currentLines.addChild(line);

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
                currentLines.eval = bestVal * me.dir();
                std.mem.swap(@TypeOf(lines_out.*.?), &prevLines, &currentLines);
                try currentLines.clear();
                favourite = topLevelMoves[0];

                // print("Searched depth {} in {} ms.\n", .{ depth, @divFloor(thinkTime, std.time.ns_per_ms) });
            }

            if (isWasm) print("Reached max depth {} in {}ms.\n", .{ maxDepth, @divFloor(thinkTime, std.time.ns_per_ms) });
            lines_out.* = prevLines;
            currentLines.deinit();

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
            if (useMemoMap) {
                for (0..memoMap.?.buffer.len) |i| {
                    memoMap.?.buffer[i].hash = 0;
                }
            }
        }

        // https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning
        // The alpha-beta values effect lower layers, not higher layers, so passed by value.
        // Returns the absolute eval of <game>, positive means white is winning, after game.nextPlayer makes a move.
        // Returns error.GameOver if there were no possible moves or other draws.
        // TODO: redo my captures only thing to be lookForPeace and only simpleEval if no captures on the board
        pub fn walkEval(game: *Board, remaining: i32, alphaIn: i32, betaIn: i32, alloc: std.mem.Allocator, stats: *Stats, comptime capturesOnly: bool, line: anytype, endTime: i128) error{ OutOfMemory, ForceStop, Overflow }!i32 {
            const me = game.nextPlayer;
            if (forceStop) return error.ForceStop;
            if (remaining == 0) {
                if (comptime stats.use) stats.leafBoardsSeen += 1;
                return game.simpleEval;
            }
            if (game.halfMoveDraw >= 100 or game.hasInsufficientMaterial()) return Magic.DRAW_EVAL;
            // Getting the time at every leaf node slows it down. But don't want to wait to get all the way back to the top if we're out of time.
            // Note: since I'm not checking at top level, it just doen't limit time if maxDepth=2 but only matters if you give it <5 ms so don't care.
            if (remaining > 2 and nanoTimestamp() >= endTime) return error.ForceStop;

            // Want to mutate copies of values from parameters.
            var alpha = alphaIn;
            var beta = betaIn;

            var cacheHit: ?MemoValue = null;
            if (useMemoMap) {
                if (memoMap.?.get(game)) |cached| {
                    if (cached.remaining >= remaining) {
                        if (comptime stats.use) stats.memoHits += 1;
                        if (!opts.doPruning) assert(cached.kind == .Exact);

                        switch (cached.kind) {
                            .Exact => return cached.eval,
                            .AlphaPrune => if (cached.eval <= alpha) return cached.eval,
                            .BetaPrune => if (cached.eval >= beta) return cached.eval,
                        }
                    }
                    cacheHit = cached;
                }
            }

            var moves = try genAllMoves.possibleMoves(game, me, alloc);
            defer alloc.free(moves);

            // if (remaining > 0) {
            // sortMoves(game, moves);
            // This is as good as sorting when using the iterative one but probably worse otherwise.
            if (cacheHit) |cached| {
                for (0..moves.len) |i| {
                    if (moves[i].from == cached.move.from and moves[i].to == cached.move.to) {
                        std.mem.swap(Move, &moves[0], &moves[i]);
                        break;
                    }
                }
            }
            // }

            var bestVal: i32 = LOWEST_EVAL * me.dir();
            var checksSkipped: usize = 0;
            var startEvaling: usize = 0;
            var memoKind: MemoKind = .Exact;
            var foundMove: ?Move = null;
            var noLegalMoves = true;
            for (moves) |move| {
                const unMove = game.play(move);
                defer game.unplay(unMove);
                if (game.inCheck(me)) {
                    checksSkipped += 1;
                    continue;
                }
                startEvaling += 1;
                noLegalMoves = false;
                var nextLine = try line.makeChild(move, @intCast(remaining), alpha, beta);
                const eval = try walkEval(game, remaining - 1, alpha, beta, alloc, stats, capturesOnly, &nextLine, endTime);
                nextLine.eval = eval;
                try line.addChild(nextLine);

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

            if (noLegalMoves) { // <me> can't make any moves. Either got checkmated or its a draw.
                if (game.inCheck(me)) {
                    return (IM_MATED_EVAL - remaining) * me.dir();
                } else {
                    return Magic.DRAW_EVAL;
                }
            }

            if (useMemoMap) { // Can never get here if forceStop=true.
                memoMap.?.setAndOverwriteBucket(game, .{ .eval = bestVal, .remaining = @intCast(remaining), .move = foundMove.?, .kind = memoKind });
            }

            return bestVal;
        }

        // TODO: try putting move values in parralel array so i dont need to keep re-playing move?
        fn quickEvalMove(game: *Board, move: Move) i32 {
            const unMove = game.play(move);
            defer game.unplay(unMove);
            if (memoMap.?.get(game)) |cached| {
                return cached.eval * game.nextPlayer.other().dir();
            } else {
                return game.simpleEval * game.nextPlayer.other().dir();
            }
        }

        fn greaterThan(game: *Board, a: Move, b: Move) bool {
            return quickEvalMove(game, a) > quickEvalMove(game, b);
        }

        // Sorting at every depth is much slower.
        // But sorting just at the very top is much faster because it means you can prune very effectivly.
        // I thought it was because of reusing work from the memo table but just using simple eval is same speed. (only testing up to move 8).
        // But using it at the very top shouldn't even work because I'm not pruning?
        // It also feels like its playing better so maybe my pruning is broken.
        // Sorting makes early moves slower.
        fn sortMoves(game: *Board, moves: []Move) void {
            // Flipped because assending.
            std.sort.insertion(Move, moves, game, greaterThan);
        }

        // TODO: this could be faster if it didn't generate every possible move first
        pub fn hasAnyLegalMoves(game: *Board, alloc: std.mem.Allocator) !bool {
            const colour = game.nextPlayer;
            const moves = try genAllMoves.possibleMoves(game, colour, alloc);
            defer alloc.free(moves);
            if (moves.len == 0) return false;

            for (moves) |move| {
                const unMove = game.play(move);
                defer game.unplay(unMove);
                if (game.inCheck(colour)) continue;
                return true;
            }
            return false;
        }

        pub fn isGameOver(game: *Board, alloc: std.mem.Allocator) !GameOver {
            if (game.halfMoveDraw >= 100) return .FiftyMoveDraw;
            if (game.hasInsufficientMaterial()) return .MaterialDraw;
            if (try hasAnyLegalMoves(game, alloc)) return .Continue;
            if (game.inCheck(game.nextPlayer)) return if (game.nextPlayer == .White) .BlackWins else .WhiteWins;
            return .Stalemate;
        }

        pub const MemoEntry = struct {
            // squares: [64]Piece,
            hash: u64, // TODO: lower x bits are the bucket so why store them
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

            pub fn initWithCapacity(comptime sizeMB: u64, alloc: std.mem.Allocator) !MemoTable {
                if (sizeMB == 0) return MemoTable{ .buffer = try alloc.alloc(MemoEntry, 0), .bucketMask = 0 };
                const targetCapacity: u64 = (sizeMB * 1024 * 1024) / @sizeOf(MemoEntry);
                const bits: u6 = @intCast(std.math.log2(targetCapacity));
                // WASM is 32 bit, make sure not to overflow a usize (4 GB).
                const realCapacity = @as(usize, 1) << @min(31, bits);
                if (!std.math.isPowerOfTwo(realCapacity)) std.debug.panic("MemoTable calculated size is {}, not a power of two!", .{realCapacity});
                var self = MemoTable{ .buffer = try alloc.alloc(MemoEntry, realCapacity), .bucketMask = (realCapacity - 1) };
                for (0..realCapacity) |i| {
                    self.buffer[i].hash = 0;
                }
                // const realSizeMB = realCapacity * @sizeOf(MemoEntry) / 1024 / 1024;
                // if (!@import("builtin").is_test) print("Memo table capacity is {} ({} MB).\n", .{ realCapacity, realSizeMB });
                return self;
            }

            // Must be same allocator as used to init.
            pub fn deinit(self: *MemoTable, alloc: std.mem.Allocator) void {
                alloc.free(self.buffer);
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
    };
} // End Strategy.

// TODO: This seems like a lot of code for something that only gets used during narrowest debugging because using at any meaningful depth uses way to much memory.
//       Should really have a simpler way to just track the best x lines it finds.
pub const Lines = struct {
    pub const Node = struct {
        move: Move,
        eval: i32 = 0,
        children: std.ArrayList(Node),
        alloc: std.mem.Allocator,
        remaining: u32,
        alpha: i32,
        beta: i32,

        pub fn makeChild(self: *Node, move: Move, remaining: u32, alpha: i32, beta: i32) !Node {
            var c = std.ArrayList(Node).init(self.alloc);
            const node: Node = .{ .alloc = self.alloc, .move = move, .children = c, .remaining = remaining, .alpha = alpha, .beta = beta };
            return node;
        }

        pub fn addChild(self: *Node, child: Node) !void {
            try self.children.append(child);
        }
    };

    arena: std.heap.ArenaAllocator,
    game: Board,
    children: std.ArrayList(Node),
    depth: usize = 0,
    eval: i32 = 0,

    pub fn init(game: *Board, alloc: std.mem.Allocator) !Lines {
        var arena = std.heap.ArenaAllocator.init(alloc);
        // TODO: wtf is happening. everything breaks if this resizes
        var c = try std.ArrayList(Node).initCapacity(arena.allocator(), 100);
        return .{ .arena = arena, .game = game.*, .children = c };
    }

    pub fn makeChild(self: *Lines, move: Move, remaining: u32, alpha: i32, beta: i32) !Node {
        const c = std.ArrayList(Node).init(self.arena.allocator());
        const node: Node = .{ .alloc = self.arena.allocator(), .move = move, .children = c, .remaining = remaining, .alpha = alpha, .beta = beta };
        return node;
    }

    pub fn addChild(self: *Lines, child: Node) !void {
        try self.children.append(child);
    }

    pub fn clear(self: *Lines) !void {
        // print("clear lines.\n", .{});
        self.eval = 0;
        self.depth = 0;
        _ = self.arena.reset(.retain_capacity);
        self.children = std.ArrayList(Node).init(self.arena.allocator());
    }

    pub fn deinit(self: *Lines) void {
        // print("Deinit lines.\n", .{});
        self.arena.deinit();
    }
};

// TODO: this SUCKS
pub const NoTrackLines = struct {
    pub const Node: type = NoTrackLines;
    pub var I: ?NoTrackLines = .{};

    eval: i32 = 0,
    depth: usize = 0,
    pub inline fn init(game: *Board, alloc: std.mem.Allocator) !NoTrackLines {
        _ = alloc;
        _ = game;
        return .{};
    }
    pub inline fn makeChild(self: *NoTrackLines, move: Move, remaining: u32, alpha: i32, beta: i32) !NoTrackLines {
        _ = beta;
        _ = alpha;
        _ = remaining;
        _ = move;
        _ = self;
        return .{};
    }
    pub inline fn addChild(self: *NoTrackLines, child: NoTrackLines) !void {
        _ = child;
        _ = self;
    }
    pub inline fn clear(self: *NoTrackLines) !void {
        _ = self;
    }

    pub inline fn deinit(self: *NoTrackLines) void {
        _ = self;
    }
};

pub const default = Strategy(.{});
