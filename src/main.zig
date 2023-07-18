const std = @import("std");
const board = @import("board.zig");
const search = @import("search.zig");
var allocatorT = std.heap.GeneralPurposeAllocator(.{}){};
var alloc = allocatorT.allocator();
const Timer = @import("bench.zig").Timer;
const print = if (@import("builtin").target.isWasm()) @import("web.zig").consolePrint else std.debug.print;

pub fn main() !void {
    // const t = Timer.start();
    // for (0..1) |_| {
    //     try @import("tests.zig").runTestCountPossibleGames();
    // }
    // print("Ran perft in {}ms\n", .{t.end()});

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    // try debugPrintAllMoves("8/8/8/8/8/8/8/6PR", .White);
    // try debugPrintAllMoves("rnb1kb1r/1p1ppppp/1qp2n2/p7/1PPP4/8/P3PPPP/R1BQKBNR", .Black);
    // try debugPrintAllMoves("rnb1kbnr/ppqppppp/2p5/3N4/8/8/PPPPPPPP/R1BQKBNR", .Black);
    // try debugPrintAllMoves("rnbqkbnr/5ppp/1p2p3/p1p5/P1P5/BPQ5/3PPPPP/R3KBNR w", .White);
    // TODO: need to have fen parse french rights
    // try debugPrintAllMoves("rnbqkbnr/2p1pppp/1p6/3p4/pP6/P1P1PQ2/3P1PPP/RNB1KBNR b", .Black);

    // try debugPrintAllMoves("rnbqkbnr/pp1ppppp/2p5/3N4/8/8/PPPPPPPP/R1BQKBNR", .Black);
    // try debugPrintAllMoves("rnb1kbnr/ppqppppp/2p5/3N4/8/8/PPPPPPPP/R1BQKBNR", .White);
    // rnbqkbnr/pp1ppppp/2p5/8/1N6/8/PPPPPPPP/R1BQKBNR
    // rbbqk2r/p2p1ppp/nB1P3n/4p2P/PPp1PPP1/8/8/RN1QKBNR .Black

    var game = board.Board.initial();

    // // TODO: this is always the same sequence because I'm not seeding it.
    // // try std.os.getrandom(buffer: []u8)
    // // TODO: can't chain because it decides to be const and can't shadow names so now I have to think of two names? this can't be right
    var notTheRng = std.rand.DefaultPrng.init(0);
    var rng = notTheRng.random();
    const ss = try game.displayString(alloc);
    try stdout.print("{s}\n", .{ss});
    // const start = std.time.nanoTimestamp();
    for (0..500) |i| { // TODO: this number is half the one in bench.zig
        if (!try debugPlayOne(&game, i, .White, &rng, stdout)) {
            break;
        }
        try bw.flush();
        if (!try debugPlayOne(&game, i, .Black, &rng, stdout)) {
            break;
        }
        try bw.flush();
    }
    // try stdout.print("Finished in {}ms.\n", .{@divFloor((std.time.nanoTimestamp() - start), @as(i128, std.time.ns_per_ms))});

    // try bw.flush();
}

// TODO: pruning does not work on maxDepth=2
fn debugPrintBestMoves(fen: []const u8, colour: board.Colour) !void {
    const strat = search.Strategy(.{ .beDeterministicForTest = true, .maxDepth = 3 });
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var quickAlloc = arena.allocator();
    defer std.debug.assert(arena.reset(.retain_capacity));

    var game = try board.Board.fromFEN(fen);
    print("Initial Position:\n", .{});
    game.debugPrint();
    // TODO: check
    // const allMoves = try moves.genAllMoves.possibleMoves(&game, colour, alloc);
    // print("{} has {} possible moves.\n", .{colour, allMoves.len});
    const allMoves = try strat.allEqualBestMoves(&game, colour, quickAlloc);
    // defer allMoves.deinit();
    print("{} has {} best moves.\n", .{ colour, allMoves.items.len });

    defer allMoves.deinit();
    var memo = try strat.MemoTable.initWithCapacity(10, quickAlloc);
    for (allMoves.items, 1..) |move, i| {
        const unMove = game.play(move);
        defer game.unplay(unMove);

        var thing: usize = 0;
        // pay attention to negative sign
        const eval = try strat.walkEval(&game, colour.other(), strat.config.maxDepth, strat.config.followCaptureDepth, -99999999, -99999999, quickAlloc, &thing, &memo, false);
        print("{}. eval: {}\n{}\n", .{ i, -eval, move });
        game.debugPrint();
    }
}

fn debugPrintAllMoves(fen: []const u8, colour: board.Colour) !void {
    const strat = search.Strategy(.{ .beDeterministicForTest = true, .maxDepth = 3 });
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var quickAlloc = arena.allocator();
    defer std.debug.assert(arena.reset(.retain_capacity));

    var initial = try board.Board.fromFEN(fen);
    initial.nextPlayer = colour;
    var game = try board.Board.fromFEN(fen);
    game.nextPlayer = colour;
    print("Initial Position:\n", .{});
    game.debugPrint();
    // TODO: check
    const allMoves = try search.genAllMoves.possibleMoves(&game, colour, alloc);
    print("{} has {} possible moves.\n", .{ colour, allMoves.len });
    try initial.expectEqual(&game); // undo move sanity check

    var memo = try strat.MemoTable.initWithCapacity(10, quickAlloc);
    defer memo.deinit();
    for (allMoves, 1..) |move, i| {
        const unMove = game.play(move);
        defer game.unplay(unMove);

        var thing: usize = 0;
        // pay attention to negative sign
        const eval = try strat.walkEval(&game, colour.other(), strat.config.maxDepth, strat.config.followCaptureDepth, -99999999, -99999999, quickAlloc, &thing, &memo, false);
        print("{}. eval: {}\n{}\n", .{ i, -eval, move });
        game.debugPrint();
    }

    try initial.expectEqual(&game); // undo move sanity check
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
    const allMoves = try search.genAllMoves.possibleMoves(game, colour, alloc);
    try stdout.print("{} has {} legal moves. \n", .{ colour, allMoves.len });
    defer alloc.free(allMoves);
    if (allMoves.len == 0) {
        return false;
    }

    const start = std.time.nanoTimestamp();
    const move = try search.Strategy(.{ .beDeterministicForTest = true }).bestMove(game, colour);
    try stdout.print("Found move in {}ms\n", .{@divFloor((std.time.nanoTimestamp() - start), @as(i128, std.time.ns_per_ms))});
    try stdout.print("{} move {} is {}\n", .{ colour, i, move });
    _ = game.play(move);

    const ss = try game.toFEN(alloc);
    defer alloc.free(ss);
    try stdout.print("{s}\n\n", .{ss});

    const s = try game.displayString(alloc);
    defer alloc.free(s);
    try stdout.print("{s}", .{s});

    return true;
}
