const std = @import("std");
const board = @import("board.zig");
const moves = @import("moves.zig");
var allocatorT = std.heap.GeneralPurposeAllocator(.{}){};
var alloc = allocatorT.allocator();
const Timer = @import("bench.zig").Timer;

pub fn main() !void {
    const t = Timer.start();
    for (0..100) |_| {
        try @import("movegen.zig").runTestCountPossibleGames();
    }
    std.debug.print("Ran perft in {}ms\n", .{t.end()});

    // const stdout_file = std.io.getStdOut().writer();
    // var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();

    // try debugPrintAllMoves("8/8/8/8/8/8/8/6PR", .White);
    // try debugPrintAllMoves("rnbqkbnr/pp1ppppp/2p5/3N4/8/8/PPPPPPPP/R1BQKBNR", .Black);
    // try debugPrintAllMoves("rnb1kbnr/ppqppppp/2p5/3N4/8/8/PPPPPPPP/R1BQKBNR", .White);
    


    // rbbqk2r/p2p1ppp/nB1P3n/4p2P/PPp1PPP1/8/8/RN1QKBNR .Black

    // var game = board.Board.initial();

    // // TODO: this is always the same sequence because I'm not seeding it. 
    // // try std.os.getrandom(buffer: []u8)
    // // TODO: can't chain because it decides to be const and can't shadow names so now I have to think of two names? this can't be right
    // var notTheRng = std.rand.DefaultPrng.init(0);
    // var rng = notTheRng.random();
    // const ss = try game.displayString(alloc);
    // try stdout.print("{s}\n", .{ss});
    // const start = std.time.nanoTimestamp();
    // for (0..15) |i| {  // TODO: this number is half the one in bench.zig
    //     if (!try debugPlayOne(&game, i, .White, &rng, stdout)) {
    //         break;
    //     }
    //     try bw.flush();
    //     if (!try debugPlayOne(&game, i, .Black, &rng, stdout)) {
    //         break;
    //     }
    //     try bw.flush();
    // }
    // try stdout.print("Finished in {}ms.\n", .{@divFloor((std.time.nanoTimestamp() - start), @as(i128, std.time.ns_per_ms))});

    // try bw.flush();
}


fn debugPrintAllMoves(fen: [] const u8, colour: board.Colour) !void {
    var game = try board.Board.fromFEN(fen);
    const start = try game.displayString(alloc);
    defer alloc.free(start);
    std.debug.print("Initial Position:\n{s}\n", .{start});
    // TODO: check
    const allMoves = try moves.genAllMoves.possibleMoves(&game, colour, alloc);
    std.debug.print("{} has {} possible moves.\n", .{colour, allMoves.len});
    const strat = moves.Strategy(.{ .beDeterministicForTest=true });
    defer alloc.free(allMoves);
    var memo = strat.MemoMap.init(alloc);
    try memo.ensureTotalCapacity(10000);
    defer memo.deinit();
    for (allMoves, 1..) |move, i| {
        const unMove = try game.play(move);
        defer game.unplay(unMove);
        const s = try game.displayString(alloc);
        defer alloc.free(s);
        var thing: usize = 0;
        const ss = try game.toFEN(alloc);
        defer alloc.free(ss);

        const eval = try strat.walkEval(&game, colour, 3, 5, -99999999, -99999999, alloc, &thing, &memo, false);
        std.debug.print("{}. eval: {}\n{s}\n{s}\n", .{i, eval, ss, s});
        
    }
}

///////
/// TODO: formalize a script for comparing different versions.  
// For profiling, run it then get the process id from activity monitor or whatever. 
// sample <pid> -f zig-out/temp_profile_info.sample
// filtercalltree zig-out/temp_profile_info.sample
///////

// TODO: how to refer to the writer interface 
fn debugPlayOne(game: *board.Board, i: usize, colour: board.Colour, rng: *std.rand.Random, stdout: anytype) !bool {
    _ = rng;
    try stdout.print("_________________\n", .{});
    const allMoves = try moves.genAllMoves.possibleMoves(game, colour, alloc);
    try stdout.print("{} has {} legal moves. \n", .{colour, allMoves.len});
    defer alloc.free(allMoves);
    if (allMoves.len == 0) {
        return false;
    }

    const start = std.time.nanoTimestamp();
    const move = try moves.Strategy(.{ .beDeterministicForTest=true }).bestMove(game, colour);
    try stdout.print("Found move in {}ms\n", .{@divFloor((std.time.nanoTimestamp() - start), @as(i128, std.time.ns_per_ms))});
    try stdout.print("{} move {} is {}\n", .{colour, i, move});
    _ = try game.play(move);


    const ss = try game.toFEN(alloc);
    defer alloc.free(ss);
    try stdout.print("{s}\n\n", .{ss});

    const s = try game.displayString(alloc);
    defer alloc.free(s);
    try stdout.print("{s}", .{s});

    return true;
}

test {
    // Runs tests in other files if there's a chain through @import-s somewhere in this file. 
    std.testing.refAllDeclsRecursive(@This());
}
