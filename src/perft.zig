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
const UCI = @import("uci.zig");
const Stockfish = @import("fish.zig").Stockfish;
const MoveFilter = @import("movegen.zig").MoveFilter;
const countPossibleGames = @import("tests.zig").countPossibleGames;
const PerftResult = @import("tests.zig").PerftResult;

var failed: usize = 0;
var nodes: usize = 0;

pub fn main() !void {
    @import("common.zig").setup();
    const t = Timer.start();
    var fish = try Stockfish.init();
    try fish.send(.Init);
    fish.blockUntilRecieve(.InitOk);
    
    print("=== Perft Starting ===\n", .{});

    // http://www.rocechess.ch/perft.html
    try runPerft(&fish, "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 3);
    try runPerft(&fish, "n1n5/PPPk4/8/8/8/8/4Kppp/5N1N b - - 0 1", 4);  // promotions
    try runPerft(&fish, "rnb1kbnr/pp1ppppp/8/q1p3N1/8/8/PPPPPPPP/RNBQKB1R w KQkq - 2 3", 2);  // has a pin
    try runPerft(&fish, "rnbqkbnr/p1p1pppp/1p6/1B1p4/4P3/1P6/P1PP1PPP/RNBQK1NR b KQkq - 1 3", 2);  // has a bishop check

    try runPerft(&fish, "rnbq1bnr/pppQpkpp/5p2/8/8/2P5/PP1PPPPP/RNB1KBNR b KQ - 0 3", 2);  // jump forward from initial pos, only hit on depth 6 
    
    // https://www.chessprogramming.org/Perft_Results
    try runPerft(&fish, "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w", 5); 
    try runPerft(&fish, "8/8/8/1Ppp3r/1K3p1k/8/4P1P1/1R6 w - c6 0 3", 5);  // french capture the pawn attacking your king 

    // constructed 
    try runPerft(&fish, "2K5/8/8/4Pp2/8/7b/8/k7 w - f6 0 1", 2); // french move capturing something revealing a check
    try runPerft(&fish, "5K2/8/8/4Pp2/8/8/8/k4r2 w - f6 0 29", 2); // french pin but you end up still blocking so its fine 
    try runPerft(&fish, "8/8/8/KPpP3r/1R3p1k/8/6P1/8 w - c6 0 3", 2); // french pin by rook but theres another friendly pawn between so its fine

    
    // mistakes from fish games
    try runPerft(&fish, "r1bqkb1r/1pp2p1p/p1n5/4pP2/4p3/1P6/P1PPKPPP/R1B2BNR w kq - 0 11", 2);
    try runPerft(&fish, "r1bqk2r/1pp2ppp/p1nbpn2/8/P7/1P1PpP1N/1BP1P1PP/RN2KB1R w KQkq - 0 9", 2);
    try runPerft(&fish, "5k2/6pp/8/3B1p2/P2PrR2/2PK4/7P/RN6 w - - 1 45", 2);
    try runPerft(&fish, "2krq2r/1pp3Qp/p7/bb2Pp1K/8/P1Pn1PPB/3P3P/RN4NR w - f6 0 29", 2);  // french while in check
    try runPerft(&fish, "r1b5/4q1pk/2pr1p1p/3p3P/1P2pP2/p1PBP3/P2N2P1/3RK1NR b - f3 0 33", 2);  // french move capturing but my pawn is pinned

    try runPerft(&fish, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", 4);  // startpos
    
    try fish.deinit();
    print("Finished full perft in {} ms. Visited {} nodes. \n", .{ t.get(), nodes });
    if (failed > 0) {
        print("=== Perft Failed {} ===\n", .{ failed });
    } else { 
        print("=== Perft Passed ===\n", .{});
    }
}

fn runPerft(fish: *Stockfish, fen: [] const u8, depth: u64) !void {
    var board = try Board.fromFEN(fen);
    print("= Starting {s} = \n", .{fen});
    nodes += try walkPerft(fish, &board, depth);
    print("= Finished {s} = \n", .{fen});
    _ = arena.reset(.retain_capacity);
}

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
fn walkPerft(fish: *Stockfish, board: *Board, depth: u64) !u64 {
    if (depth == 0) return 1;
    var alloc = arena.allocator();
    try fish.send(.{ .SetPositionMoves = .{ .board = board, .moves=null }});
    try fish.send(.{ .Go = .{ .perft = depth}});
    var fishBranches = std.ArrayList(UCI.PerftNode).init(alloc);
    var total: u64 = 0;
    const fen = try board.toFEN(alloc);

    while (true) {
        const msg = fish.recieve() catch continue;
        switch (msg) {
            .PerftDivide => |info| {
                try fishBranches.append(info);
                total += info.count;
            },
            .PerftDone => |info| {
                if (info.total != total) {
                    failed += 1;
                    print("[{}] ({s}) Sum is {} but fish thinks its {}. Makes no sense!\n", .{ depth, fen, total, info.total });
                }
                break;
            },
            else => {},
        }
    }

    const myMoves = try MoveFilter.Any.get().possibleMoves(board, board.nextPlayer, alloc);

    for (fishBranches.items) |info| {
        for (myMoves) |check| {
            const text = try check.text();
            if (std.mem.eql(u8, &info.move, &text)) break;
        } else {
            failed += 1;
            print("[{}] ({s}) Fish has move {s} but I don't. \n", .{depth, fen, &info.move});
        }
    }

    var myTotal: u64 = 0;
    for (myMoves) |move| {
        const unMove = board.play(move);
        defer board.unplay(unMove);
        // Don't need to check that it's legal because comparing to stockfish will catch that mistake. 
        const text = try move.text();
        for (fishBranches.items) |check| {
            if (!std.mem.eql(u8, &text, &check.move)) continue;

            const count = try walkPerft(fish, board, depth - 1);
            if (count != check.count) {
                failed += 1;
                print("[{}] ({s}) After {s}, I think there are {} possible games but fish thinks its {}.\n", .{ depth, fen, text, count, check.count });
            }
            myTotal += count;
            break;
        } else {
            failed += 1;
            print("[{}] ({s}) I have move {s} but fish doesn't. \n", .{depth, fen, &text});
        }
    }

    if (myTotal != total) {
        failed += 1;
        print("[{}] ({s}) I think there are {} possible games but fish thinks its {}.\n", .{ depth, fen, total, myTotal });
    }

    return myTotal;
}
