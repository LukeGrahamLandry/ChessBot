const std = @import("std");
const board = @import("board.zig");
const moves = @import("moves.zig");
var allocatorT = std.heap.GeneralPurposeAllocator(.{}){};
var alloc = allocatorT.allocator();

pub fn main() !void {
    const total = Timer.start();
    const count = 30;

    // std.debug.print("Running behaviour tests...\n", .{});
    // try @import("movegen.zig").runTestCountPossibleGames();
    // try @import("moves.zig").runTestComparePruning();
    // std.debug.print("Tests Passed! \n", .{});

    std.debug.print("Warmup...", .{});
    _ = try checkGameTime(moves.Strategy(.{ .beDeterministicForTest=true }), count);
    std.debug.print(" Ready!\nDefault...\n", .{});
    const first = try checkGameTime(moves.Strategy(.{ .beDeterministicForTest=true }), count);
    std.debug.print("- [   ] (1.00x) default finished in {}ms.\n", .{first});

    // Timing these this way is safe because they don't effect move ordering so always plays the same game.
    // TODO: asserts ^ and crashes for AutoHash cause i'm storing more info on the board
    std.debug.print("Comparing hash functions...\n", .{});
    const algos = comptime std.enums.values(moves.HashAlgo);
    inline for (algos, 0..) |hashAlgo, i| {
        const strategy = comptime moves.Strategy(.{ .hashAlgo=hashAlgo, .beDeterministicForTest=true });
        const time = try checkGameTime(strategy, count);
        var multiplier: f64 = @as(f64, @floatFromInt(first)) / @as(f64, @floatFromInt(time)); 
        std.debug.print("- [{}/{}] ({d:.2}x) {} finished in {}ms.\n", .{i+1, algos.len, multiplier, hashAlgo, time});
    }

    // TODO: the memomap changes the game?? this is a problem!
    // {
    //     std.debug.print("Trying without memo table...\n", .{});
    //     const noMemo = comptime moves.Strategy(.{ .memoMapSizeMB=0, .beDeterministicForTest=true });
    //     const time = try checkGameTime(noMemo, count);
    //     var multiplier: f64 = @as(f64, @floatFromInt(first)) / @as(f64, @floatFromInt(time)); 
    //     std.debug.print("- [   ]({d:.2}x) moves.HashAlgo.None finished in {}ms.\n", .{multiplier, time});
    // }

    // TODO: Generally, timing these this way is not safe because they could play different games. 
    //       But the checkGameTime checks for that and panics. If it panics here, its not really a test fail, its just that the timing info would be invalid.
    std.debug.print("Comparing check detection...\n", .{});
    const algos2 = comptime std.enums.values(moves.CheckAlgo);
    inline for (algos2, 0..) |checkAlgo, i| {
        const strategy = comptime moves.Strategy(.{ .checkDetection=checkAlgo, .beDeterministicForTest=true });
        const time = try checkGameTime(strategy, count);
        var multiplier: f64 = @as(f64, @floatFromInt(first)) / @as(f64, @floatFromInt(time)); 
        std.debug.print("- [{}/{}] ({d:.2}x) {} finished in {}ms.\n", .{i+1, algos2.len, multiplier, checkAlgo, time});
    }


    std.debug.print("Ran full bench in {}ms.\n", .{total.end()});
}

var finalBoard: ?board.Board = null;
fn checkGameTime(comptime strategy: type, comptime moveCount: comptime_int) !i128 {
    var game = board.Board.initial();
    const t = Timer.start();
    var player = board.Colour.White;
    for (0..moveCount) |_| {
        const move = try strategy.bestMove(&game, player);
        _ = try game.play(move);
        player = player.other();
    }
    
    // TODO: the memomap changes the game?? this is a problem!
    // Since I want to compare times, each run must play the same game or it would be unfair. 
    if (finalBoard) |expectedBoard| {
        if (!std.meta.eql(game.squares, expectedBoard.squares)) @panic("Played different game. Time comparison invalid.");
    } else {
        finalBoard = game;
    }
    return t.end();
}

pub const Timer = struct {
    t: i128,

    pub fn start() Timer {
        return .{ .t=std.time.nanoTimestamp() };
    }

    pub fn end(self: Timer) i128 {
        return @divFloor((std.time.nanoTimestamp() - self.t), @as(i128, std.time.ns_per_ms));
    }
};
