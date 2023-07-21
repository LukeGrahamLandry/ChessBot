//! Uses UCI to run perft on stockfish and compare it to my engine for debugging movegen. 
//! Take a position, ask stockfish to list all the possible moves at a given depth, make sure we agree. 

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

pub fn main() !void {
    @import("common.zig").setup();
    var fish = try Stockfish.init();
    try fish.send(.Init);
    fish.blockUntilRecieve(.InitOk);
    
    print("=== Perft Starting ===\n", .{});
    try runPerft(&fish, "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 3);
    try runPerft(&fish, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", 6);
    try fish.deinit();
    print("=== Perft Finished ===\n", .{});
}

fn runPerft(fish: *Stockfish, fen: [] const u8, depth: u64) !void {
    var board = try Board.fromFEN(fen);
    print("= Starting {s} = \n", .{fen});
    _ = try walkPerft(fish, &board, depth);
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
            print("[{}] ({s}) Fish has move {s} but I don't. \n", .{depth, fen, &info.move});
        }
    }

    var myTotal: u64 = 0;
    for (myMoves) |move| {
        const colour = board.nextPlayer;
        const unMove = board.play(move);
        defer board.unplay(unMove);
        if (board.slowInCheck(colour)) continue;
        const text = try move.text();
        for (fishBranches.items) |check| {
            if (!std.mem.eql(u8, &text, &check.move)) continue;

            const count = try walkPerft(fish, board, depth - 1);
            if (count != check.count) {
                print("[{}] ({s}) After {s}, I think there are {} possible games but fish thinks its {}.\n", .{ depth, fen, text, count, check.count });
            }
            myTotal += count;
            break;
        } else {
            print("[{}] ({s}) I have move {s} but fish doesn't. \n", .{depth, fen, &text});
        }
    }

    if (myTotal != total) {
        print("[{}] ({s}) I think there are {} possible games but fish thinks its {}.\n", .{ depth, fen, total, myTotal });
    }

    return myTotal;
}
