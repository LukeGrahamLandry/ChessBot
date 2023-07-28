const std = @import("std");
const board = @import("board.zig");
const search = @import("search.zig");
const Learned = @import("learned.zig");
const Timer = @import("common.zig").Timer;
const print = @import("common.zig").print;

// TODO: arena
var allocatorT = std.heap.GeneralPurposeAllocator(.{}){};
var alloc = allocatorT.allocator();

const maxDepth = 4;
const maxTime = 10000;
var ctx: search.SearchGlobals = undefined;

const gameStr = "b1c3 d7d5 a1b1 d5d4 c3b5 g8f6 b1a1 d4d3 g1h3 e7e5 h1g1 f8c5 g1h1 c8h3 a2a3 d3e2 d1e2 h3e6 f2f4 c5a3 a1a3 d8d2 e1d2 e5e4 b5c7 e8e7 c7a8 e4e3 d2e3 b8a6 b2b3 h8d8 a8c7 e6b3 a3a6 b3c2 a6a7 c2d3 e2b2 e7d7 b2d4 d7c7 a7b7 c7c8 b7b8 c8b8 d4d8 b8b7 f1d3 f6g4 e3e2 b7a7 d8c8 f7f5 c8c7 a7a8 c1b2";
// const gameStr = "b2b3 g8f6 f2f3 a7a6 c1a3 d7d5 e2e3 g7g6 a3b2 f8g7 f1d3 c7c5 b2e5 h7h5 e1e2 h5h4 d1e1 b8d7 e5c3 b7b5 e1d1 d5d4 e3d4 b5b4 c3b2 a6a5 d4c5 c8a6 c5c6 d7b8 d3a6 a8a6 e2f2 f6g4 f2e1 g7b2 f3g4 e8g8 d1e2 b8c6 e2a6 d8d6 g1f3 f8b8 e1e2 c6d4 f3d4 d6a6 e2e1 b2d4 c2c3 d4a7 g4g5 a6e6 e1d1 e6c6 d1c1 c6g2 h1e1 b4c3 b1c3 e7e5 a1b1 b8d8 e1d1 h4h3 c1c2 a7d4 d1e1 d8c8 c2c1 g8f8 c1d1 f8g7 b3b4 c8d8 c3e4 g2f3 d1c2 f3a3 c2d1 a3a2 d1e2 a2c2 b1c1 c2a2 c1c6 d4a7 e1d1 a2d5 c6g6 f7g6 e4f2 a5b4 f2h3 d5e4 e2f1 d8f8 h3f2 f8f2 f1g1";
// const gameStr = "b2b3 e7e6 c1b2 d7d5 g1f3 b8d7 h1g1 g8f6 c2c4 c7c6 c4d5 f6d5 e2e4 d5b4 b2c3 e6e5 d2d4 e5d4 f3d4 d7f6 d1e2 c8g4 f2f3 g4c8 g1h1 h7h6 a2a3 b4a6 d4c2 a6c7 b1d2 c8e6 e1c1 f8c5 b3b4 c5b6 d2c4 f6d7 c4b6 a7b6 e2d2 f7f6 c1b2 d8e7 d2d6 b6b5 d6c7 e8g8 c3d4 a8c8 c7b7 c8b8 b7a7 b8a8 d4c5 e7e8 a7c7 d7c5 b4c5 g8h7 d1e1 b5b4 c2b4 f8f7 c7c6 e6d7 c6b6 e8e5 b2b1 a8a3 b4c2 a3a8 f1a6 a8b8 a6b7 h7h8 c5c6 d7c6 b6c6 b8b7 b1c1 e5b2 c1d2 f7c7 c6e8 h8h7 e1c1";
pub fn main() !void {
    ctx = @import("common.zig").setup(100);
    print("maxDepth={}. maxTime={}ms. \nGame: {s} \n", .{ maxDepth, maxTime, gameStr });
    _ = try replayGame(.{});
    // _ = try replayGame(.{ .doIterative = false });
    // _ = try replayGame(.{ .doMemo = false });
    // _ = try replayGame(.{ .doMemo = false, .doIterative = false });
    // // _ = try replayGame(.{ .doPruning = false });  // Takes sooooo long

    // // For working on move gen.
    // try (@import("tests.zig").PerftTest{
    //     .possibleGames = &[_]u64{ 20, 400, 8902, 197281, 4865609, 119060324 },  //, 3195901860
    //     .possibleMates = &[_]u64{ 0, 0, 0, 8, 347, 10828 },  //, 435767
    //     .fen = @import("board.zig").INIT_FEN,
    // }).run();
}

var lists = &@import("common.zig").lists;

fn replayGame(comptime opts: search.StratOpts) !std.ArrayList(board.Move) {
    ctx.resetMemoTable();
    var moves = std.mem.splitScalar(u8, gameStr, ' ');
    const t = Timer.start();
    var game = try board.Board.initial();
    var bestMoves = std.ArrayList(board.Move).init(alloc);
    var undoStack = std.ArrayList(board.OldMove).init(alloc);
    var m: usize = 0;
    while (true) {
        // TODO: catch gameover on last move.
        try bestMoves.append(try search.bestMove(opts, &ctx, &game, maxDepth, maxTime));

        const word = moves.next() orelse break;
        std.debug.assert(word.len == 4 or word.len == 5);
        var moveStr = std.mem.zeroes([5]u8);
        @memcpy(moveStr[0..word.len], word);

        try undoStack.append(try @import("uci.zig").playAlgebraic(&game, moveStr, &ctx.lists));
        // game.debugPrint();
        m += 1;
    }

    for (0..undoStack.items.len) |i| {
        const index = undoStack.items.len - 1 - i;
        game.unplay(undoStack.items[index]);
    }

    try std.testing.expectEqual(game.zoidberg, 1);
    print("\nFinished game in {}ms. {}. {}\n", .{ t.get(), try game.gameOverReason(&ctx.lists), opts });
    return bestMoves;
}
