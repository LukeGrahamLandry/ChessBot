const std = @import("std");
const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;
const Move = @import("board.zig").Move;
const GameOver = @import("board.zig").GameOver;
const Magic = @import("magic.zig");
const Timer = @import("bench.zig").Timer;
const print = if (@import("builtin").target.isWasm()) @import("web.zig").consolePrint else std.debug.print;
const panic = if (@import("builtin").target.isWasm()) @import("web.zig").alertPrint else std.debug.panic;

fn nanoTimestamp() i128 {
    if (comptime isWasm) {
        return @as(i128, @intFromFloat(@import("web.zig").jsPerformaceNow())) * std.time.ns_per_ms;
    } else {
        return std.time.nanoTimestamp();
    }
}

// TODO: carefully audit any use of usize because wasm is 32 bit!
const isWasm = @import("builtin").target.isWasm();

inline fn assert(val: bool) void {
    // if (val) @panic("lol nope");
    std.debug.assert(val);
    // _ = val;
}

pub const HashAlgo = enum {
    // These all operate on the byte array of squares.
    Wyhash, // same algo as auto
    Fnv1a_64,
    XxHash64,
    Murmur2_64,
    CityHash64,
};

pub const CheckAlgo = enum { Ignore, ReverseFromKing, LookAhead };

var notTheRng = std.rand.DefaultPrng.init(0);
var rng = notTheRng.random();

const movegen = @import("movegen.zig");
pub const genCapturesOnly = movegen.MoveFilter.CapturesOnly.get();
pub const genAllMoves = movegen.MoveFilter.Any.get();

pub const StratOpts = struct {
    maxDepth: comptime_int = 4, // TODO: should be runtime param to bestMove so wasm can change without increasing code size.
    doPruning: bool = true,
    beDeterministicForTest: bool = true,
    memoMapSizeMB: u64 = 100, // Zero means don't use memo map at all.
    hashAlgo: HashAlgo = .CityHash64,
    checkDetection: CheckAlgo = .ReverseFromKing,
    // TODO: High numbers play worse?? i know im doing it wrong but i thought it would still be better. or maybe its cripplefish fuck up
    followCaptureDepth: i32 = -12345, // TODO: unused
    // TODO: how many levels to sort. which algo to use. whether to use memo map.
};

pub const MoveErr = error{ GameOver, OutOfMemory, ForceStop, Overflow };

// These numbers are for one bestMove call, not cumulative.
pub const Stats = struct {
    comptime use: bool = false,
    memoHits: u64 = 0, // Tried to evaluate a board and it was already in the memo table with a high enough depth.
    // memoAdditions: u64 = 0, // Added a board to the memo table.
    // memoCollissions: u64 = 0, // Added a board and overwrite a previous value. Since the table is never reset, this will trend towards 100% of memoAdditions. TODO: make this useful
    leafBoardsSeen: u64 = 0, // Ran out of depth and checked the simpleEval of a board.
    gameOversSeen: u64 = 0,
};

const IM_MATED_EVAL: i32 = -1000000; // Add distance to prefer sooner mates
const LOWEST_EVAL: i32 = -2000000;

// TODO: script that tests different variations (compare speed and run correctness tests).
pub fn Strategy(comptime opts: StratOpts) type {
    return struct { // Start Strategy.
        pub const config = opts;
        const useMemoMap = opts.memoMapSizeMB > 0;

        // None of this is thread safe!
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
                },
            }
        }

        pub fn randomMove(game: *Board, me: Colour, alloc: std.mem.Allocator) !Move {
            const moves = try genAllMoves.possibleMoves(game, me, alloc);
            defer alloc.free(moves);
            if (moves.len == 0) return error.GameOver;

            var legalMoves = try std.ArrayList(Move).initCapacity(alloc, 50);
            defer legalMoves.deinit();

            for (moves) |move| {
                const unMove = game.play(move);
                defer game.unplay(unMove);
                if (try inCheck(game, me, alloc)) continue;
                try legalMoves.append(move);
            }

            if (legalMoves.items.len == 0) return error.GameOver;
            const choice = if (opts.beDeterministicForTest or legalMoves.items.len == 1) 0 else rng.uintLessThanBiased(usize, legalMoves.items.len);
            return legalMoves.items[choice];
        }

        // This has its own loop because I actually need to know which move is best which walkEval doesn't return.
        // Also means I can reset the temp allocator more often.
        pub fn bestMove(game: *Board, me: Colour, depth: ?i32) !Move {
            var alloc = upperArena.allocator();
            defer assert(upperArena.reset(.retain_capacity));
            const bestMoves = try allEqualBestMoves(game, me, alloc, depth orelse opts.maxDepth);
            defer bestMoves.deinit();

            // You can't just pick a deterministic random because pruning might end up with a shorter list of equal moves.
            // Always choosing the first should be fine because pruning just cuts off the search early.
            // Generating random numbers is quite slow, so don't do it if theres only 1 option anyway.
            const choice = if (opts.beDeterministicForTest or bestMoves.items.len == 1) 0 else rng.uintLessThanBiased(usize, bestMoves.items.len);
            return bestMoves.items[choice];
        }

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

        pub fn bestMoveIterative(game: *Board, me: Colour, maxDepth: usize, timeLimitMs: i128, lines_out: anytype) !Move {
            if (game.halfMoveDraw >= 100 or insufficientMaterial(game)) return error.GameOver; // Draw

            const startTime = nanoTimestamp();
            const endTime = startTime + (timeLimitMs * std.time.ns_per_ms);
            defer _ = upperArena.reset(.retain_capacity);
            if (memoMap == null) memoMap = try MemoTable.initWithCapacity(opts.memoMapSizeMB, std.heap.page_allocator);
            var memo = &memoMap.?;

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
                if (try inCheck(game, me, movesArena.allocator())) {
                    // TODO: leak but arena
                    std.mem.swap(Move, &topLevelMoves[topLevelMoves.len - 1], &topLevelMoves[m]);
                    topLevelMoves.len -= 1;
                } else {
                    try evalGuesses.append(game.simpleEval);
                    m += 1;
                }
            }
            if (topLevelMoves.len == 0) return error.GameOver;

            var stats: Stats = .{};
            var thinkTime: i128 = -1;
            var favourite: Move = topLevelMoves[0];
            for (0..(maxDepth + 1)) |depth| {
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
                    const eval = walkEval(game, me.other(), @intCast(depth), alpha, beta, movesArena.allocator(), &stats, memo, false, &line, endTime) catch |err| {
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

        // TODO: why am I returning an array list here but a slice from possibleMoves?
        pub fn allEqualBestMoves(game: *Board, me: Colour, alloc: std.mem.Allocator, depth: i32) MoveErr!std.ArrayList(Move) {
            if (game.halfMoveDraw >= 100 or insufficientMaterial(game)) return error.GameOver; // Draw

            // TODO: I don't like that I can't init this outside.
            // Not using the arena alloc because this persists after the move is played so work can be reused.
            if (memoMap == null) memoMap = try MemoTable.initWithCapacity(opts.memoMapSizeMB, std.heap.page_allocator);
            var memo = &memoMap.?;

            const moves = try genAllMoves.possibleMoves(game, me, alloc);
            defer alloc.free(moves);
            if (moves.len == 0) return error.GameOver;
            sortMoves(game, moves);

            // No deinit because returned
            var bestMoves = try std.ArrayList(Move).initCapacity(alloc, 50);

            // TODO: use memo at top level? once it persists longer it must be helpful
            var bestVal: i32 = LOWEST_EVAL;
            var stats: Stats = .{};
            var bestWhiteEval = LOWEST_EVAL;
            var bestBlackEval = LOWEST_EVAL;
            for (moves) |move| {
                const unMove = game.play(move);
                defer game.unplay(unMove);
                if (try inCheck(game, me, alloc)) continue;
                const value = -try walkEval(game, me.other(), depth, bestWhiteEval, bestBlackEval, movesArena.allocator(), &stats, memo, false); // TODO: need to catch
                if (value > bestVal) {
                    bestVal = value;
                    bestMoves.clearRetainingCapacity();
                    try bestMoves.append(move);
                    if (opts.doPruning and checkAlphaBeta(bestVal, me, &bestWhiteEval, &bestBlackEval)) {
                        break;
                    }
                } else if (value == bestVal) {
                    try bestMoves.append(move);
                }
                _ = movesArena.reset(.retain_capacity);
            }

            if (bestMoves.items.len == 0) return error.GameOver;
            // assert(stats.memoAdditions >= stats.memoCollissions);
            if (comptime stats.use) print("Move {}, eval {}. Depth {} (+{} for captures) saw {} leaf boards with {} memo hits.\n", .{ game.fullMoves + 1, bestVal, depth, @min(opts.followCaptureDepth, depth), stats.leafBoardsSeen, stats.memoHits });
            return bestMoves;
        }

        // https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning
        // The alpha-beta values effect lower layers, not higher layers, so passed by value.
        // The eval of <game>, positive means <me> is winning, assuming it is <me>'s turn.
        // Returns error.GameOver if there were no possible moves or for 50 move rule.
        // TODO: redo my captures only thing to be lookForPiece and only simpleEval if no captures on the board
        pub fn walkEval(game: *Board, me: Colour, remaining: i32, alphaIn: i32, betaIn: i32, alloc: std.mem.Allocator, stats: *Stats, memo: *MemoTable, comptime capturesOnly: bool, line: anytype, endTime: i128) error{ OutOfMemory, ForceStop, Overflow }!i32 {
            if (forceStop) return error.ForceStop;
            if (remaining == 0) {
                if (comptime stats.use) stats.leafBoardsSeen += 1;
                return game.simpleEval;
            }
            if (game.halfMoveDraw >= 100 or insufficientMaterial(game)) return Magic.DRAW_EVAL;
            // Getting the time at every leaf node slows it down. But don't want to wait to get all the way back to the top if we're out of time.
            // Note: since I'm not checking at top level, it just doen't limit time if maxDepth=2 but only matters if you give it <5 ms so don't care.
            if (remaining > 2 and nanoTimestamp() >= endTime) return error.ForceStop;

            // Want to mutate copies of values from parameters.
            var alpha = alphaIn;
            var beta = betaIn;

            var cacheHit: ?MemoValue = null;
            if (useMemoMap) {
                // TODO: It would be really good to be able to reuse what we did on the last search if they played the move we thought they would.
                //       This remaining checks stops that but also seems nesisary for correctness.
                if (memo.get(game)) |cached| {
                    if (cached.remaining >= remaining) {
                        if (comptime stats.use) stats.memoHits += 1;
                        switch (cached.kind) {
                            .Exact => return cached.eval,
                            .AlphaPrune => if (cached.eval <= alpha) return cached.eval,
                            .BetaPrune => if (cached.eval >= beta) return cached.eval,
                        }
                    }
                    cacheHit = cached;
                }
            }

            const moveGen = genAllMoves;
            var moves = try moveGen.possibleMoves(game, me, alloc);
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
                if (try inCheck(game, me, alloc)) {
                    checksSkipped += 1;
                    continue;
                }
                startEvaling += 1;
                noLegalMoves = false;
                var nextLine = try line.makeChild(move, @intCast(remaining), alpha, beta);
                const eval = try walkEval(game, me.other(), remaining - 1, alpha, beta, alloc, stats, memo, capturesOnly, &nextLine, endTime);
                nextLine.eval = eval;
                try line.addChild(nextLine);

                switch (me) {
                    .White => {
                        bestVal = @max(bestVal, eval);
                        if (bestVal == eval) foundMove = move;
                        alpha = @max(alpha, bestVal);
                        if (bestVal >= beta) {
                            memoKind = .BetaPrune;
                            break;
                        }
                    },
                    .Black => {
                        bestVal = @min(bestVal, eval);
                        if (bestVal == eval) foundMove = move;
                        beta = @min(beta, bestVal);
                        if (bestVal <= alpha) {
                            memoKind = .AlphaPrune;
                            break;
                        }
                    },
                }
            }

            if (noLegalMoves) { // <me> can't make any moves. Either got checkmated or its a draw.
                if (try inCheck(game, me, alloc)) {
                    return (IM_MATED_EVAL - remaining) * me.dir();
                } else {
                    return Magic.DRAW_EVAL;
                }
            }

            // TODO: this is still wrong, its only skipping if we pruned this level, but should also care if any children pruned?
            if (useMemoMap) { // Can never get here if forceStop=true.
                memo.setAndOverwriteBucket(game, .{ .eval = bestVal, .remaining = @intCast(remaining), .move = foundMove.?, .kind = memoKind });
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
                },
            }
            return false;
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
                if (try inCheck(game, colour, alloc)) continue;
                return true;
            }
            return false;
        }

        pub fn isGameOver(game: *Board, alloc: std.mem.Allocator) !GameOver {
            if (game.halfMoveDraw >= 100) return .FiftyMoveDraw;
            if (insufficientMaterial(game)) return .MaterialDraw;
            if (try hasAnyLegalMoves(game, alloc)) return .Continue;
            if (try inCheck(game, game.nextPlayer, alloc)) return if (game.nextPlayer == .White) .BlackWins else .WhiteWins;
            return .Stalemate;
        }

        // https://www.chess.com/article/view/how-chess-games-can-end-8-ways-explained#insufficient-material
        pub fn insufficientMaterial(game: *Board) bool {
            const total = @popCount(game.peicePositions.white | game.peicePositions.white);
            if (total > 4) return false;
            var minorWhite: usize = 0;
            var minorBlack: usize = 0;
            for (game.squares) |piece| {
                switch (piece.kind) {
                    .Empty, .King => {},
                    .Rook, .Queen, .Pawn => return false,
                    .Bishop, .Knight => switch (piece.colour) {
                        .White => minorWhite += 1,
                        .Black => minorBlack += 1,
                    },
                }
            }
            // TODO: king vs king + 2N
            // (king vs king, king+1 vs king) or (king+1 vs king+1)
            return (minorWhite + minorBlack) <= 1 or (minorWhite == 1 and minorBlack == 1);
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
                const realSizeMB = realCapacity * @sizeOf(MemoEntry) / 1024 / 1024;
                print("Memo table capacity is {} ({} MB).\n", .{ realCapacity, realSizeMB });

                // for (0..781) |i| {
                //     print("{b}\n", .{Magic.ZOIDBERG[i] & (realCapacity - 1)});
                // }
                return self;
            }

            // Must be same allocator as used to init.
            pub fn deinit(self: *MemoTable, alloc: std.mem.Allocator) void {
                alloc.free(self.buffer);
            }

            pub fn hash(key: *const Board) u64 {
                // // TODO: include castling/french move.
                // This is relies on empty squares having a definied colour so they bytes match!
                // const data = std.mem.asBytes(&key.squares);
                // const hashcode = switch (comptime opts.hashAlgo) {
                //     .Wyhash => std.hash.Wyhash.hash(0, data),
                //     .Fnv1a_64 => std.hash.Fnv1a_64.hash(data),
                //     .XxHash64 => std.hash.XxHash64.hash(0, data),
                //     .Murmur2_64 => std.hash.Murmur2_64.hash(data),
                //     .CityHash64 => std.hash.CityHash64.hash(data),
                // };
                // assert(hashcode != 0); // collission with my empty bucket indicator
                // return hashcode;
                // print("set {} ", .{key.zoidberg});
                // key.debugPrint();
                return key.zoidberg;
            }

            pub fn eql(key: *const Board, entry: *MemoEntry) bool {
                // This is relies on empty squares having a definied colour so they bytes match!
                return std.mem.eql(u8, std.mem.asBytes(&key.squares), std.mem.asBytes(&entry.squares));
            }

            // TODO: some heuristic for when you get to overwrite bucket? age (epoch counter) vs remaining
            pub fn setAndOverwriteBucket(self: *MemoTable, key: *const Board, value: MemoValue) void {
                const hashcode = hash(key);
                const bucket: usize = @intCast(hashcode & self.bucketMask);
                self.buffer[bucket] = .{
                    // .squares = key.squares,
                    .hash = hashcode,
                    .value = value,
                };
            }

            pub fn get(self: *MemoTable, key: *const Board) ?MemoValue {
                const hashcode = hash(key);
                const bucket: usize = @intCast(hashcode & self.bucketMask);
                // print("get {} ", .{key.zoidberg});
                // key.debugPrint();
                if (self.buffer[bucket].hash == hashcode) {
                    // fuck it, we ball, 2^64 is basically infinity
                    // if (!eql(key, &self.buffer[bucket])) {
                    //     panic("hash collission (not a problem... yet, just debugging)", .{}); // TODO: does this every happen? how confident am I?
                    //     return null;
                    // }
                    return self.buffer[bucket].value;
                } else {
                    return null;
                }
            }
        };
    };
} // End Strategy.

pub const default = Strategy(.{});

test {
    var game = Board.initial();
    var lines: ?default.Lines = null;
    const best = try default.bestMoveIterative(&game, .White, 5, 1000, &lines);
    _ = best;
    for (lines.?.children.items) |move| {
        print("{s} ({}); ", .{ try move.move.text(), move.eval });
    }
    print("\n", .{});
    for (lines.?.children.items[0].children.items) |move| {
        print("{s} ({}); ", .{ try move.move.text(), move.eval });
    }
}

test "dir" {
    try std.testing.expectEqual(Colour.White.dir(), 1);
    try std.testing.expectEqual(Colour.Black.dir(), -1);
}
