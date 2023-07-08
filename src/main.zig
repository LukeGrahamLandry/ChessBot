const std = @import("std");
const board = @import("board.zig");
const moves = @import("moves.zig");
var allocatorT = std.heap.GeneralPurposeAllocator(.{}){};
var alloc = allocatorT.allocator();

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    var ggame = try board.Board.fromFEN("R6R/3Q4/1Q4Q1/4Q3/2Q4Q/Q4Q2/pp1Q4/kBNNK1B1");
    const allMoves = try moves.possibleMoves(&ggame, .White, alloc);
    std.debug.print("All your {s} are belong to us. {}\n", .{"codebase", allMoves.len});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var game = board.Board.initial();

    // TODO: this is always the same sequence because I'm not seeding it. 
    // try std.os.getrandom(buffer: []u8)
    // TODO: can't chain because it decides to be const and can't shadow names so now I have to think of two names? this can't be right
    var notTheRng = std.rand.DefaultPrng.init(0);
    var rng = notTheRng.random();
    const ss = try game.displayString(alloc);
    try stdout.print("{s}\n", .{ss});
    const delay = 500000000;
    for (0..100) |i| {
        if (!try debugPlayOne(&game, i, .White, &rng, stdout)) {
            break;
        }
        try bw.flush();
        std.time.sleep(delay);
        if (!try debugPlayOne(&game, i, .Black, &rng, stdout)) {
            break;
        }
        try bw.flush();
        std.time.sleep(delay);
    }


    // Leaking a bunch of stuff, nobody cares. 
    // try stdout.print("Run `zig build test` to run the tests.\n{s}\n\n{}\n{s}", .{ try b.toFEN(alloc), @sizeOf(board.Board), try b.displayString(alloc)});
    // try stdout.print("===BLACK===\n", .{});
    // try stdout.print("{s} \n", .{try game.displayString(alloc)});
    // for (try moves.possibleMoves(&game, .Black, alloc)) |move| {
    //     try stdout.print("{} \n", .{move});
    //     var temp = try board.Board.fromFEN(fen);
    //     temp.play(move);
    //     try stdout.print("{s} \n", .{try temp.displayString(alloc)});
    
    // }

    // try stdout.print("===WHITE===\n", .{});
    // try stdout.print("{s} \n", .{try game.displayString(alloc)});
    // for (try moves.possibleMoves(&game, .White, alloc)) |move| {
    //     try stdout.print("{} \n", .{move});
    //     var temp = try board.Board.fromFEN(fen);
    //     temp.play(move);
    //     try stdout.print("{s} \n", .{try temp.displayString(alloc)});
    // }


    try bw.flush(); // don't forget to flush!
}

// TODO: how to refer to the writer interface 
fn debugPlayOne(game: *board.Board, i: usize, colour: board.Colour, rng: *std.rand.Random, stdout: anytype) !bool {
    const allMoves = try moves.possibleMoves(game, colour, alloc);
    try stdout.print("_________________\n", .{});
    try stdout.print("{} has {} legal moves. \n", .{colour, allMoves.len});
    defer alloc.free(allMoves);
    if (allMoves.len == 0) {
        return false;
    }

    const choice = rng.uintLessThanBiased(usize, allMoves.len);
    const move = allMoves[choice];
    try stdout.print("{} move {} is {}\n", .{colour, i, move});
    game.play(move);

    const ss = try game.toFEN(alloc);
    defer alloc.free(ss);
    try stdout.print("{s}\n\n", .{ss});

    const s = try game.displayString(alloc);
    defer alloc.free(s);
    try stdout.print("{s}", .{s});

    return true;
}

test {
    _ = @import("board.zig");
    _ = @import("moves.zig");
}
