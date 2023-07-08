const std = @import("std");
const board = @import("board.zig");
const moves = @import("moves.zig");
var allocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var b = board.Board.initial();


    // Leaking a bunch of stuff, nobody cares. 
    const fen = "r2Q3r/ppppppp1/8/8/8/8/1PPPPPPP/R3KBNR";
    const game = try board.Board.fromFEN(fen);
    try stdout.print("Run `zig build test` to run the tests.\n{s}\n\n{}\n{s}", .{ try b.toFEN(allocator.allocator()), @sizeOf(board.Board), try b.displayString(allocator.allocator())});
    try stdout.print("=====\n", .{});
    try stdout.print("{s} \n", .{try game.displayString(allocator.allocator())});
    for (try moves.slowPossibleMoves(&game, .Black, allocator.allocator())) |move| {
        try stdout.print("{} \n", .{move});
        var temp = try board.Board.fromFEN(fen);
        temp.play(move);
        try stdout.print("{s} \n", .{try temp.displayString(allocator.allocator())});
    
    }


    try bw.flush(); // don't forget to flush!
}

test {
    _ = @import("board.zig");
    _ = @import("moves.zig");
}
