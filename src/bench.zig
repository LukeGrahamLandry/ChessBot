const std = @import("std");
const board = @import("board.zig");
const search = @import("search.zig");
var allocatorT = std.heap.GeneralPurposeAllocator(.{}){};
var alloc = allocatorT.allocator();
const print = if (@import("builtin").target.isWasm()) @import("web.zig").consolePrint else std.debug.print;

// TODO: maybe one game then compare time to generate an eval of each position
pub fn main() !void {
    _ = try replayGame(example);
    // const total = Timer.start();
    // const count = 30;

    // // print("Running behaviour tests...\n", .{});
    // // try @import("movegen.zig").runTestCountPossibleGames();
    // // try @import("moves.zig").runTestComparePruning();
    // // print("Tests Passed! \n", .{});

    // print("Warmup...", .{});
    // _ = try checkGameTime(search.Strategy(.{ .beDeterministicForTest = true }), count);
    // print(" Ready!\nDefault...\n", .{});
    // const first = try checkGameTime(search.Strategy(.{ .beDeterministicForTest = true }), count);
    // print("- [   ] (1.00x) default finished in {}ms.\n", .{first});

    // // // Before: Timing these this way is safe because they don't effect move ordering so always plays the same game.
    // // // TODO: asserts ^ and crashes for AutoHash cause i'm storing more info on the board
    // // // TODO: these tests no longer work because I overwrite on hash <bucket> collissions
    // // print("Comparing hash functions...\n", .{});
    // // const algos = comptime std.enums.values(moves.HashAlgo);
    // // inline for (algos, 0..) |hashAlgo, i| {
    // //     if (hashAlgo == .StdAuto) continue;
    // //     const strategy = comptime moves.Strategy(.{ .hashAlgo=hashAlgo, .beDeterministicForTest=true });
    // //     const time = try checkGameTime(strategy, count);
    // //     var multiplier: f64 = @as(f64, @floatFromInt(first)) / @as(f64, @floatFromInt(time));
    // //     print("- [{}/{}] ({d:.2}x) {} finished in {}ms.\n", .{i+1, algos.len, multiplier, hashAlgo, time});
    // // }

    // // TODO: the memomap changes the game?? this is a problem!
    // // {
    // //     print("Trying without memo table...\n", .{});
    // //     const noMemo = comptime moves.Strategy(.{ .memoMapSizeMB=0, .beDeterministicForTest=true });
    // //     const time = try checkGameTime(noMemo, count);
    // //     var multiplier: f64 = @as(f64, @floatFromInt(first)) / @as(f64, @floatFromInt(time));
    // //     print("- [   ]({d:.2}x) moves.HashAlgo.None finished in {}ms.\n", .{multiplier, time});
    // // }

    // // TODO: Generally, timing these this way is not safe because they could play different games.
    // //       But the checkGameTime checks for that and panics. If it panics here, its not really a test fail, its just that the timing info would be invalid.
    // // TODO: new memo map means they play totally different games
    // // print("Comparing check detection...\n", .{});
    // // const algos2 = comptime std.enums.values(moves.CheckAlgo);
    // // inline for (algos2, 0..) |checkAlgo, i| {
    // //     const strategy = comptime moves.Strategy(.{ .checkDetection=checkAlgo, .beDeterministicForTest=true });
    // //     const time = try checkGameTime(strategy, count);
    // //     var multiplier: f64 = @as(f64, @floatFromInt(first)) / @as(f64, @floatFromInt(time));
    // //     print("- [{}/{}] ({d:.2}x) {} finished in {}ms.\n", .{i+1, algos2.len, multiplier, checkAlgo, time});
    // // }

    // print("Ran full bench in {}ms.\n", .{total.get()});
}

const example = "b1c3 d7d5 a1b1 d5d4 c3b5 g8f6 b1a1 d4d3 g1h3 e7e5 h1g1 f8c5 g1h1 c8h3 a2a3 d3e2 d1e2 h3e6 f2f4 c5a3 a1a3 d8d2 e1d2 e5e4 b5c7 e8e7 c7a8 e4e3 d2e3 b8a6 b2b3 h8d8 a8c7 e6b3 a3a6 b3c2 a6a7 c2d3 e2b2 e7d7 b2d4 d7c7 a7b7 c7c8 b7b8 c8b8 d4d8 b8b7 f1d3 f6g4 e3e2 b7a7 d8c8 f7f5 c8c7 a7a8 c1b2";
fn replayGame(gameStr: []const u8) !std.ArrayList(board.Move) {
    const strat = search.Strategy(.{ .beDeterministicForTest = true });
    var moves = std.mem.splitScalar(u8, gameStr, ' ');
    const t = Timer.start();
    var game = board.Board.initial();
    var bestMoves = std.ArrayList(board.Move).init(alloc);
    while (true) {
        try bestMoves.append(try strat.bestMoveIterative(&game, game.nextPlayer, 5, 5000, &strat.NoTrackLines.I));

        const word = moves.next() orelse break;
        std.debug.assert(word.len == 4 or word.len == 5);
        var moveStr = std.mem.zeroes([5]u8);
        @memcpy(moveStr[0..word.len], word);

        print("{s} ", .{word});
        try @import("uci.zig").playAlgebraic(&game, moveStr);
    }

    print("\nFinished game in {}ms.\n", .{t.get()});
    return bestMoves;
}

var finalBoard: ?board.Board = null;
fn checkGameTime(comptime strategy: type, comptime moveCount: comptime_int) !i128 {
    var game = board.Board.initial();
    const t = Timer.start();
    var player = board.Colour.White;
    for (0..moveCount) |_| {
        const move = try strategy.bestMove(&game, player);
        _ = game.play(move);
        player = player.other();
    }

    // TODO: the memomap changes the game?? this is a problem!
    // Since I want to compare times, each run must play the same game or it would be unfair.
    // if (finalBoard) |expectedBoard| {
    //     if (!std.meta.eql(game.squares, expectedBoard.squares)) @panic("Played different game. Time comparison invalid.");
    // } else {
    //     finalBoard = game;
    // }
    return t.get();
}

pub const Timer = struct {
    t: i128,

    pub fn start() Timer {
        return .{ .t = std.time.nanoTimestamp() };
    }

    pub fn get(self: Timer) i128 {
        return @divFloor((std.time.nanoTimestamp() - self.t), @as(i128, std.time.ns_per_ms));
    }
};
