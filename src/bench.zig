const std = @import("std");
const board = @import("board.zig");
const moves = @import("moves.zig");
var allocatorT = std.heap.GeneralPurposeAllocator(.{}){};
var alloc = allocatorT.allocator();

pub fn main() !void {
    const count = 30;

    std.debug.print("Warmup...", .{});
    _ = try checkGameTime(moves.Strategy(.{ .beDeterministicForTest=true }), count);
    std.debug.print(" Ready!\nDefault...\n", .{});
    const first = try checkGameTime(moves.Strategy(.{ .beDeterministicForTest=true }), count);
    std.debug.print("- [   ] (1.00x) default finished in {}ms.\n", .{first});

    std.debug.print("Comparing hash functions...\n", .{});
    const algos = comptime std.enums.values(moves.HashAlgo);
    inline for (algos, 0..) |hashAlgo, i| {
        const strategy = comptime moves.Strategy(.{ .hashAlgo=hashAlgo, .beDeterministicForTest=true });
        const time = try checkGameTime(strategy, count);
        var multiplier: f64 = @as(f64, @floatFromInt(first)) / @as(f64, @floatFromInt(time)); 
        std.debug.print("- [{}/{}] ({d:.2}x) {} finished in {}ms.\n", .{i+1, algos.len, multiplier, hashAlgo, time});
    }

    std.debug.print("Trying without memo table...\n", .{});
    const noMemo = comptime moves.Strategy(.{ .memoMapSizeMB=0, .beDeterministicForTest=true });
    const time = try checkGameTime(noMemo, count);
    var multiplier: f64 = @as(f64, @floatFromInt(first)) / @as(f64, @floatFromInt(time)); 
    std.debug.print("- [   ]({d:.2}x) null finished in {}ms.\n", .{multiplier, time});
}

fn checkGameTime(comptime strategy: type, comptime moveCount: comptime_int) !i128 {
    var game = board.Board.initial();
    const start = std.time.nanoTimestamp();
    var player = board.Colour.White;
    for (0..moveCount) |_| {
        const move = try strategy.bestMove(&game, player);
        _ = game.play(move);
        player = player.other();
    }
    
    return @divFloor((std.time.nanoTimestamp() - start), @as(i128, std.time.ns_per_ms));
}
