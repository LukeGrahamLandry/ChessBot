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

var failed: usize = 0;
var nodesSeen: usize = 0;
const doFishDebugOnFail = true;

const positionData = @embedFile("perft.txt");

// TODO: fall back to the fish if I get the wrong answer. 

// For things I don't care about freeing. 
var foreverArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var forever = foreverArena.allocator();

const Shared = std.atomic.Atomic(usize);

// These could be pointers stored in Worker if I was serious about the global variable holy war, but I don't need to bother yet. 
// TODO: Should probably have each thread count and then add up at the end? but that shouldn't matter because it takes so long to finish one anyway? 
var passedCount = Shared.init(0);
var failedCount = Shared.init(0);
var totalNodes = Shared.init(0);

pub fn main() !void {
    @import("common.zig").setup();
    const t = Timer.start();
    const perfts = (try parsePerfts()).items;

    // TODO: adding more threads doesn't make it faster. maybe they're all just waiting on the last guy
    const cores = 4;
    var taskIndex = Shared.init(0);
    var workers = try forever.alloc(Worker, cores);
    for (0..cores) |i| {
        workers[i] = .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .fish = try Stockfish.init(forever),
            .thread = try std.Thread.spawn(.{}, workerFn, .{ &workers[i] }),
            .nextTask = &taskIndex,
            .tasks = perfts,
        };
    }

    for (workers) |worker| {
        worker.thread.join();
    }

    // Time info is meaningless if it includes the extra debug walking. 
    if (!doFishDebugOnFail or failedCount.loadUnchecked() == 0) print("Finished {} perfts in {} ms. {} nodes per second per core. \n", .{ perfts.len, t.get(), @divFloor(totalNodes.loadUnchecked(), t.get()) * (1000 / cores) });
    
    print("Passed {}. Failed {}.\n", .{ passedCount.loadUnchecked(), failedCount.loadUnchecked() });
}

pub const Perfts = struct {
    fen: []const u8,
    levels: [] Perft,
};

pub const Perft = struct {
    nodes: u64,
    depth: u64,
};

const Worker = struct {
    thread: std.Thread,
    arena: std.heap.ArenaAllocator,
    fish: Stockfish,
    nextTask: *Shared,
    tasks: [] Perfts,
};

fn workerFn(self: *Worker) !void {
    std.time.sleep(250);  // Just make absolutly sure the other thread finishes setting the array. 
    while (true) {
        const nextTask = self.nextTask.fetchAdd(1, .SeqCst);
        if (nextTask >= self.tasks.len) break;

        const position = self.tasks[nextTask];
        var anyFails = false;
        var total: u64 = 0;
        var game = try Board.fromFEN(position.fen);
        for (position.levels) |perft| {
            const nodes = (try @import("tests.zig").countPossibleGames(&game, game.nextPlayer, perft.depth, self.arena.allocator(), false)).games;
            _ = self.arena.reset(.retain_capacity);
            total += nodes;
            if (nodes != perft.nodes) {
                print("{}/{}. Failed {s} depth {}. Expected {} but found {}.\n", .{ nextTask, self.tasks.len, position.fen, perft.depth, perft.nodes, nodes });
                anyFails = true;
                if (doFishDebugOnFail) try debugPerft(&self.fish, position.fen, perft.depth, &self.arena);
                break; // All deeper levels will also fail. 
            } else {
                print("{}/{}. Passed {s} depth {}.\n", .{ nextTask, self.tasks.len, position.fen, perft.depth });
            }
        }

        _ = totalNodes.fetchAdd(total, .SeqCst);
        _ = (if (anyFails) failedCount else passedCount).fetchAdd(1, .SeqCst);
    }
}

// pub fn oldMain() !void {
//     @import("common.zig").setup();
//     const t = Timer.start();
//     var fish = try Stockfish.init(forever);
//     try fish.send(.Init);
//     fish.blockUntilRecieve(.InitOk);

//     print("=== Perft Starting ===\n", .{});

//     // http://www.rocechess.ch/perft.html
//     try debugPerft(&fish, "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 3);
//     try debugPerft(&fish, "n1n5/PPPk4/8/8/8/8/4Kppp/5N1N b - - 0 1", 4);  // promotions
//     try debugPerft(&fish, "rnb1kbnr/pp1ppppp/8/q1p3N1/8/8/PPPPPPPP/RNBQKB1R w KQkq - 2 3", 2);  // has a pin
//     try debugPerft(&fish, "rnbqkbnr/p1p1pppp/1p6/1B1p4/4P3/1P6/P1PP1PPP/RNBQK1NR b KQkq - 1 3", 2);  // has a bishop check

//     try debugPerft(&fish, "rnbq1bnr/pppQpkpp/5p2/8/8/2P5/PP1PPPPP/RNB1KBNR b KQ - 0 3", 2);  // jump forward from initial pos, only hit on depth 6 
    
//     // https://www.chessprogramming.org/Perft_Results
//     try debugPerft(&fish, "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w", 5); 
//     try debugPerft(&fish, "8/8/8/1Ppp3r/1K3p1k/8/4P1P1/1R6 w - c6 0 3", 5);  // french capture the pawn attacking your king 

//     // constructed 
//     try debugPerft(&fish, "2K5/8/8/4Pp2/8/7b/8/k7 w - f6 0 1", 2); // french move capturing something revealing a check
//     try debugPerft(&fish, "5K2/8/8/4Pp2/8/8/8/k4r2 w - f6 0 29", 2); // french pin but you end up still blocking so its fine 
//     try debugPerft(&fish, "8/8/8/KPpP3r/1R3p1k/8/6P1/8 w - c6 0 3", 2); // french pin by rook but theres another friendly pawn between so its fine

//     // mistakes from fish games
//     try debugPerft(&fish, "r1bqkb1r/1pp2p1p/p1n5/4pP2/4p3/1P6/P1PPKPPP/R1B2BNR w kq - 0 11", 2);
//     try debugPerft(&fish, "r1bqk2r/1pp2ppp/p1nbpn2/8/P7/1P1PpP1N/1BP1P1PP/RN2KB1R w KQkq - 0 9", 2);
//     try debugPerft(&fish, "5k2/6pp/8/3B1p2/P2PrR2/2PK4/7P/RN6 w - - 1 45", 2);
//     try debugPerft(&fish, "2krq2r/1pp3Qp/p7/bb2Pp1K/8/P1Pn1PPB/3P3P/RN4NR w - f6 0 29", 2);  // french while in check
//     try debugPerft(&fish, "r1b5/4q1pk/2pr1p1p/3p3P/1P2pP2/p1PBP3/P2N2P1/3RK1NR b - f3 0 33", 2);  // french move capturing but my pawn is pinned

//     try debugPerft(&fish, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", 4);  // startpos
    
//     try fish.deinit();
//     print("Finished full perft in {} ms. Visited {} nodes. {} nodes per second. \n", .{ t.get(), nodesSeen, @divFloor(nodesSeen, t.get()) * 1000 });
//     if (failed > 0) {
//         print("=== Perft Failed {} ===\n", .{ failed });
//     } else { 
//         print("=== Perft Passed ===\n", .{});
//     }
// }

fn parsePerfts() !std.ArrayList(Perfts) {
    var all = std.ArrayList(Perfts).init(forever);
    
    var lines = std.mem.splitScalar(u8, positionData, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        var parts = std.mem.splitScalar(u8, line, ';');
        const fen = parts.next() orelse unreachable;
        _ = Board.fromFEN(fen) catch |err| std.debug.panic("{}. Failed to parse fen: {s}", .{err, fen});
        var perfts = std.ArrayList(Perft).init(forever);
        while (parts.next()) |level| {
            var info = std.mem.splitScalar(u8, level, ' ');
            const depthInfo = info.next() orelse std.debug.panic("Failed to parse. {s}", .{line});
            const nodesInfo = info.next() orelse std.debug.panic("Failed to parse. {s}", .{line});
            try std.testing.expectEqual(depthInfo[0], 'D');
            const depth = std.fmt.parseInt(u64, depthInfo[1..], 10) catch |err| std.debug.panic("{}. Failed to parse. {s}    LINE: {s}", .{err, depthInfo, line});
            const nodes = std.fmt.parseInt(u64, nodesInfo, 10) catch |err| std.debug.panic("{}. Failed to parse. {s}    LINE: {s}", .{err, nodesInfo, line});
            try perfts.append(.{ .depth=depth, .nodes=nodes } );
        }
        try all.append(.{ .fen=fen, .levels=try perfts.toOwnedSlice() });
    }

    return all;
}

fn debugPerft(fish: *Stockfish, fen: [] const u8, depth: u64, arena: *std.heap.ArenaAllocator) !void {
    var board = try Board.fromFEN(fen);
    print("= Starting {s} = \n", .{fen});
    var foundProblem = false;
    _ = walkPerft(fish, &board, depth, arena) catch |err| {
        if (err != error.FishDisagree) return err;
        foundProblem = true;
    };
    if (!foundProblem) panic("Fish didn't find the problem {s}. Perft failed but fish agrees on counts for all leaf nodes. \nThat means when I make a move I'm getting a different fen than it would have. \nLast time it was a castling rights mistake.\n", .{fen});
    print("= Finished {s} = \n", .{fen});
    _ = arena.reset(.retain_capacity);
}


fn walkPerft(fish: *Stockfish, board: *Board, depth: u64, arena: *std.heap.ArenaAllocator) !u64 {
    if (depth == 0) return 1;

    var alloc = arena.allocator();
    const fen = try board.toFEN(alloc);

    // First decide if this is the branch where we disagree about possible moves. 
    // Can do that by using depth 1 because we don't care about the actual numbers yet. 
    const fishMoves = (try runFishPerft(fish, board, 1, alloc)).childCount;
    const myMoves = try MoveFilter.Any.get().possibleMoves(board, board.nextPlayer, alloc);

    var missingMoves = false;
    var myMovesSet = std.AutoHashMap([5] u8, void).init(alloc);

    // Do I have extra illegal moves?
    for (myMoves) |move| {
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
    if (myMoves.len != fishMoves.count())  {
        panic("had same moves but different numbers. makes no sense!", .{});
    }


    // We agree on which moves are possible from here but disagree on the total size of the tree. 
    // Now need to decide which branch we disagree on by running both counts on a higher depth. 
    // Recursivly repeat this whole process for each child.
    var myTotal: u64 = 0;
    var littleArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    for (myMoves) |myMove| {
        const unMove = board.play(myMove);
        defer board.unplay(unMove);
        const myCount = (try countPossibleGames(board, board.nextPlayer, depth - 1, littleArena.allocator(), false)).games;
        const fishCount = try runFishPerftCountGames(fish, board, depth - 1, littleArena.allocator());
        if (myCount != fishCount){
            // This branch is the problem. 
            print("Disagree on count at depth {}: me:{} vs fish:{}. {s}\n", .{depth-1, myCount, fishCount, try board.toFEN(littleArena.allocator())});
            const calcCount = try walkPerft(fish, board, depth - 1, arena);
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