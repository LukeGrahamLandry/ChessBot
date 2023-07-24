//! Uses UCI to run perft on stockfish and compare it to my engine for debugging movegen. 
//! Take a position, ask stockfish to list all the possible moves at a given depth, make sure we agree. 
//! Automaticlly follow the tree down to find the exact position with the bug. 

const std = @import("std");
const Board = @import("board.zig").Board;
const Move = @import("board.zig").Move;
const Colour = @import("board.zig").Colour;
const search = @import("search.zig");
const Timer = @import("common.zig").Timer;
const GameOver = @import("board.zig").GameOver;
const Magic = @import("common.zig").Magic;
const assert = @import("common.zig").assert;
const print = @import("common.zig").print;
const panic = @import("common.zig").panic;
const UCI = @import("uci.zig");
const Stockfish = @import("fish.zig").Stockfish;
const MoveFilter = @import("movegen.zig").MoveFilter;
const countPossibleGames = @import("tests.zig").countPossibleGames;
const PerftResult = @import("tests.zig").PerftResult;
const ListPool = @import("movegen.zig").ListPool;

const doFishDebugOnFail = true;
const positionData = @embedFile("perft.txt");

// For things I don't care about freeing. 
var foreverArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var forever = foreverArena.allocator();

const Shared = std.atomic.Atomic(usize);

pub fn main() !void {
    @import("common.zig").setup(0);
    const perfts = (try parsePerfts()).items;
    
    // For best parallelism, don't put the longest tasks at the end. You don't want time at the end where only one therad is working. 
    std.sort.insertion(Perfts, perfts, {}, lessThanFn);

    const cores = 4;
    var taskIndex = Shared.init(0);
    var workers = try forever.alloc(Worker, cores);
    for (0..cores) |i| {
        workers[i] = .{
            .id = i,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .lists = try ListPool.init(forever),
            .fish = try Stockfish.init(forever),
            .thread = try std.Thread.spawn(.{}, workerFn, .{ &workers[i] }),
            .nextTask = &taskIndex,
            .tasks = perfts,
        };
    }

    for (workers) |worker| {
        worker.thread.join();
    }

    const endTime = std.time.nanoTimestamp();
    var failed: u64 = 0;
    for (workers) |worker| {
        print("{}ms, ", .{@divFloor(endTime - worker.endTime, std.time.ns_per_ms)});
        failed += worker.failedCount;
    }
    print("; idle thread time.\n", .{});


    if (failed == 0){
        print("Memory usage: {} KB.\n", .{foreverArena.queryCapacity() / 1024});
        print("Passed All {}.\n", .{ perfts.len });
    } else {
        print("Failed {}/{}.\n", .{ failed, perfts.len });
    }
}

pub const Perfts = struct {
    fen: []const u8,
    levels: [] Perft,
    allCount: u64 // for sorting
};

pub const Perft = struct {
    nodes: u64,
    depth: u64,
};

const Worker = struct {
    id: usize,
    thread: std.Thread,
    arena: std.heap.ArenaAllocator,
    lists: ListPool,
    fish: Stockfish,
    nextTask: *Shared,
    tasks: [] Perfts,
    failedCount: u64 = 0,
    passedCount: u64 = 0,
    totalNodes: u64 = 0,
    endTime: i128 = 0,
};

fn workerFn(self: *Worker) !void {
    std.time.sleep(50);  // Just make absolutly sure the other thread finishes setting the array. 
    const startTime = std.time.nanoTimestamp();
    while (true) {
        const nextTask = self.nextTask.fetchAdd(1, .SeqCst);
        if (nextTask >= self.tasks.len) break;

        const position = self.tasks[nextTask];
        var game = try Board.fromFEN(position.fen);
        for (position.levels) |perft| {
            const nodes = (try @import("tests.zig").countPossibleGames(&game, game.nextPlayer, perft.depth, &self.lists, false)).games;
            self.totalNodes += nodes;
            if (nodes != perft.nodes) {
                print("[{}/{}] Failed {s} depth {}. Expected {} but found {}.\n", .{ nextTask+1, self.tasks.len, position.fen, perft.depth, perft.nodes, nodes });
                self.failedCount += 1;
                if (doFishDebugOnFail) {
                    try debugPerft(&self.fish, position.fen, perft.depth, &self.arena, &self.lists);
                    _ = self.arena.reset(.retain_capacity);
                }
                break; // All deeper levels will also fail. 
            } else {
                print("[{}/{}] Passed {s} depth {}.\n", .{ nextTask+1, self.tasks.len, position.fen, perft.depth });
            }
        } else {
            self.passedCount += 1;
        }
    }

    self.endTime = std.time.nanoTimestamp();
    if (self.failedCount == 0){
        const ms = @divFloor((self.endTime - startTime), std.time.ns_per_ms);
        print("Thread {} finished {} perfts in {}ms. {} nodes / second.\n", .{self.id, self.passedCount, ms, @divFloor(self.totalNodes * 1000, ms)});
    }
}

fn parsePerfts() !std.ArrayList(Perfts) {
    var all = std.ArrayList(Perfts).init(forever);
    
    var lines = std.mem.splitScalar(u8, positionData, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        var parts = std.mem.splitScalar(u8, line, ';');
        const fen = parts.next() orelse unreachable;
        _ = Board.fromFEN(fen) catch |err| std.debug.panic("{}. Failed to parse fen: {s}", .{err, fen});
        var perfts = std.ArrayList(Perft).init(forever);
        var total: u64 = 0;
        while (parts.next()) |level| {
            var info = std.mem.splitScalar(u8, level, ' ');
            const depthInfo = info.next() orelse std.debug.panic("Failed to parse. {s}", .{line});
            const nodesInfo = info.next() orelse std.debug.panic("Failed to parse. {s}", .{line});
            try std.testing.expectEqual(depthInfo[0], 'D');
            const depth = std.fmt.parseInt(u64, depthInfo[1..], 10) catch |err| std.debug.panic("{}. Failed to parse. {s}    LINE: {s}", .{err, depthInfo, line});
            const nodes = std.fmt.parseInt(u64, nodesInfo, 10) catch |err| std.debug.panic("{}. Failed to parse. {s}    LINE: {s}", .{err, nodesInfo, line});
            try perfts.append(.{ .depth=depth, .nodes=nodes } );
            total += nodes;
        }
        try all.append(.{ .fen=fen, .levels=try perfts.toOwnedSlice(), .allCount=total });
    }

    return all;
}

fn lessThanFn(ctx: void, lhs: Perfts, rhs: Perfts) bool {
    _ = ctx;
    return lhs.allCount > rhs.allCount; // flipped cause ascending
}

fn debugPerft(fish: *Stockfish, fen: [] const u8, depth: u64, arena: *std.heap.ArenaAllocator, lists: *ListPool) !void {
    var board = try Board.fromFEN(fen);
    print("= Starting {s} = \n", .{fen});
    var foundProblem = false;
    _ = walkPerft(fish, &board, depth, arena, lists) catch |err| {
        if (err != error.FishDisagree) return err;
        foundProblem = true;
    };
    if (!foundProblem) panic("Fish didn't find the problem {s}. Perft failed but fish agrees on counts for all leaf nodes. \nThat means when I make a move I'm getting a different fen than it would have. \nLast time it was a castling rights mistake.\n", .{fen});
    print("= Finished {s} = \n", .{fen});
    _ = arena.reset(.retain_capacity);
}


fn walkPerft(fish: *Stockfish, board: *Board, depth: u64, arena: *std.heap.ArenaAllocator, lists: *ListPool) !u64 {
    if (depth == 0) return 1;

    var alloc = arena.allocator();
    const fen = try board.toFEN(alloc);

    // First decide if this is the branch where we disagree about possible moves. 
    // Can do that by using depth 1 because we don't care about the actual numbers yet. 
    const fishMoves = (try runFishPerft(fish, board, 1, alloc)).childCount;
    const myMoves = try MoveFilter.Any.get().possibleMoves(board, board.nextPlayer, lists);
    defer lists.release(myMoves);

    var missingMoves = false;
    var myMovesSet = std.AutoHashMap([5] u8, void).init(alloc);

    // Do I have extra illegal moves?
    for (myMoves.items) |move| {
        // Don't need to check that it's legal because comparing to stockfish will catch that mistake. 
        const text = try move.text();
        try myMovesSet.put(text, {});
        if (!fishMoves.contains(text)) {
            missingMoves = true;
            print("[{}] ({s}) Found! I have move {s} but fish doesn't. \n", .{depth, fen, &text});
        }
    }

    // Am I missing moves?
    var keys = fishMoves.keyIterator();
    while (keys.next()) |info| {
        if (!myMovesSet.contains(info.*)) {
            missingMoves = true;
            print("[{}] ({s}) Found! Fish has move {s} but I don't. \n", .{depth, fen, info});
        }
    }

    // If we disagreed on moves, this level is the problem, don't need to keep going. 
    if (missingMoves) {
        return error.FishDisagree;
    }
    if (myMoves.items.len != fishMoves.count())  {
        panic("had same moves but different numbers. makes no sense!", .{});
    }


    // We agree on which moves are possible from here but disagree on the total size of the tree. 
    // Now need to decide which branch we disagree on by running both counts on a higher depth. 
    // Recursivly repeat this whole process for each child.
    var myTotal: u64 = 0;
    var littleArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    for (myMoves.items) |myMove| {
        const unMove = board.play(myMove);
        defer board.unplay(unMove);
        const myCount = (try countPossibleGames(board, board.nextPlayer, depth - 1, lists, false)).games;
        const fishCount = try runFishPerftCountGames(fish, board, depth - 1, littleArena.allocator());
        if (myCount != fishCount){
            // This branch is the problem. 
            print("Disagree on count at depth {}: me:{} vs fish:{}. {s}\n", .{depth-1, myCount, fishCount, try board.toFEN(littleArena.allocator())});
            const calcCount = try walkPerft(fish, board, depth - 1, arena, lists);
            if (calcCount != myCount) panic("countPossibleGames didnt match walkPerft: {} vs {}\n", .{ myCount, calcCount});
        }
        myTotal += myCount;

        _ = littleArena.reset(.retain_capacity);
    }   

    return myTotal;
}

const FishResult = struct {
    childCount: std.AutoHashMap([5] u8, u64),
    total: u64
};

fn runFishPerft(fish: *Stockfish, board: *Board, depth: u64, alloc: std.mem.Allocator) !FishResult {
    const fen = try board.toFEN(alloc);
    try fish.send(.{ .SetPositionMoves = .{ .board = board, .moves=null }});
    try fish.send(.{ .Go = .{ .perft = depth}});
    var total: u64 = 0;
    var branches = std.AutoHashMap([5] u8, u64).init(alloc);
    while (true) {
        const msg = fish.recieve() catch continue;
        switch (msg) {
            .PerftDivide => |info| {
                try branches.put(info.move, info.count);
                total += info.count;
            },
            .PerftDone => |info| {
                if (info.total != total) {
                    panic("[{}] ({s}) Sum is {} but fish thinks its {}. This should be unreachable\n", .{ depth, fen, total, info.total });
                }
                break;
            },
            else => {},
        }
    }
    return .{
        .childCount = branches,
        .total = total,
    };
}

fn runFishPerftCountGames(fish: *Stockfish, board: *Board, depth: u64, alloc: std.mem.Allocator) !u64 {
    const fen = try board.toFEN(alloc);
    try fish.send(.{ .SetPositionMoves = .{ .board = board, .moves=null }});
    try fish.send(.{ .Go = .{ .perft = depth}});
    var total: u64 = 0;
    while (true) {
        const msg = fish.recieve() catch continue;
        switch (msg) {
            .PerftDivide => |info| {
                total += info.count;
            },
            .PerftDone => |info| {
                if (info.total != total) {
                    panic("[{}] ({s}) Sum is {} but fish thinks its {}. This should be unreachable\n", .{ depth, fen, total, info.total });
                }
                break;
            },
            else => {},
        }
    }
    return total;
}