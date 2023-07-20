// const std = @import("std");
// const board = @import("board.zig");
// const search = @import("search.zig");
// const Magic = @import("magic.zig");
// const Timer = @import("common.zig").Timer;

// // TODO: arena
// var allocatorT = std.heap.GeneralPurposeAllocator(.{}){};
// var alloc = allocatorT.allocator();

// // TODO: maybe one game then compare time to generate an eval of each position
// pub fn main() !void {
//     Magic.initZoidberg();
//     _ = try replayGame(example);
//     // const total = Timer.start();
//     // const count = 30;

//     // // print("Running behaviour tests...\n", .{});
//     // // try @import("movegen.zig").runTestCountPossibleGames();
//     // // try @import("moves.zig").runTestComparePruning();
//     // // print("Tests Passed! \n", .{});

//     // print("Warmup...", .{});
//     // _ = try checkGameTime(search.Strategy(.{ .beDeterministicForTest = true }), count);
//     // print(" Ready!\nDefault...\n", .{});
//     // const first = try checkGameTime(search.Strategy(.{ .beDeterministicForTest = true }), count);
//     // print("- [   ] (1.00x) default finished in {}ms.\n", .{first});

//     // // // Before: Timing these this way is safe because they don't effect move ordering so always plays the same game.
//     // // // TODO: asserts ^ and crashes for AutoHash cause i'm storing more info on the board
//     // // // TODO: these tests no longer work because I overwrite on hash <bucket> collissions
//     // // print("Comparing hash functions...\n", .{});
//     // // const algos = comptime std.enums.values(moves.HashAlgo);
//     // // inline for (algos, 0..) |hashAlgo, i| {
//     // //     if (hashAlgo == .StdAuto) continue;
//     // //     const strategy = comptime moves.Strategy(.{ .hashAlgo=hashAlgo, .beDeterministicForTest=true });
//     // //     const time = try checkGameTime(strategy, count);
//     // //     var multiplier: f64 = @as(f64, @floatFromInt(first)) / @as(f64, @floatFromInt(time));
//     // //     print("- [{}/{}] ({d:.2}x) {} finished in {}ms.\n", .{i+1, algos.len, multiplier, hashAlgo, time});
//     // // }

//     // // TODO: the memomap changes the game?? this is a problem!
//     // // {
//     // //     print("Trying without memo table...\n", .{});
//     // //     const noMemo = comptime moves.Strategy(.{ .memoMapSizeMB=0, .beDeterministicForTest=true });
//     // //     const time = try checkGameTime(noMemo, count);
//     // //     var multiplier: f64 = @as(f64, @floatFromInt(first)) / @as(f64, @floatFromInt(time));
//     // //     print("- [   ]({d:.2}x) moves.HashAlgo.None finished in {}ms.\n", .{multiplier, time});
//     // // }

//     // // TODO: Generally, timing these this way is not safe because they could play different games.
//     // //       But the checkGameTime checks for that and panics. If it panics here, its not really a test fail, its just that the timing info would be invalid.
//     // // TODO: new memo map means they play totally different games
//     // // print("Comparing check detection...\n", .{});
//     // // const algos2 = comptime std.enums.values(moves.CheckAlgo);
//     // // inline for (algos2, 0..) |checkAlgo, i| {
//     // //     const strategy = comptime moves.Strategy(.{ .checkDetection=checkAlgo, .beDeterministicForTest=true });
//     // //     const time = try checkGameTime(strategy, count);
//     // //     var multiplier: f64 = @as(f64, @floatFromInt(first)) / @as(f64, @floatFromInt(time));
//     // //     print("- [{}/{}] ({d:.2}x) {} finished in {}ms.\n", .{i+1, algos2.len, multiplier, checkAlgo, time});
//     // // }

//     // print("Ran full bench in {}ms.\n", .{total.get()});
// }

// const example = "b1c3 d7d5 a1b1 d5d4 c3b5 g8f6 b1a1 d4d3 g1h3 e7e5 h1g1 f8c5 g1h1 c8h3 a2a3 d3e2 d1e2 h3e6 f2f4 c5a3 a1a3 d8d2 e1d2 e5e4 b5c7 e8e7 c7a8 e4e3 d2e3 b8a6 b2b3 h8d8 a8c7 e6b3 a3a6 b3c2 a6a7 c2d3 e2b2 e7d7 b2d4 d7c7 a7b7 c7c8 b7b8 c8b8 d4d8 b8b7 f1d3 f6g4 e3e2 b7a7 d8c8 f7f5 c8c7 a7a8 c1b2";
// // const example2 = "b2b3 g8f6 f2f3 a7a6 c1a3 d7d5 e2e3 g7g6 a3b2 f8g7 f1d3 c7c5 b2e5 h7h5 e1e2 h5h4 d1e1 b8d7 e5c3 b7b5 e1d1 d5d4 e3d4 b5b4 c3b2 a6a5 d4c5 c8a6 c5c6 d7b8 d3a6 a8a6 e2f2 f6g4 f2e1 g7b2 f3g4 e8g8 d1e2 b8c6 e2a6 d8d6 g1f3 f8b8 e1e2 c6d4 f3d4 d6a6 e2e1 b2d4 c2c3 d4a7 g4g5 a6e6 e1d1 e6c6 d1c1 c6g2 h1e1 b4c3 b1c3 e7e5 a1b1 b8d8 e1d1 h4h3 c1c2 a7d4 d1e1 d8c8 c2c1 g8f8 c1d1 f8g7 b3b4 c8d8 c3e4 g2f3 d1c2 f3a3 c2d1 a3a2 d1e2 a2c2 b1c1 c2a2 c1c6 d4a7 e1d1 a2d5 c6g6 f7g6 e4f2 a5b4 f2h3 d5e4 e2f1 d8f8 h3f2 f8f2 f1g1 e4g2";
// fn replayGame(gameStr: []const u8) !std.ArrayList(board.Move) {
//     const strat = search.Strategy(.{ .beDeterministicForTest = true });
//     var moves = std.mem.splitScalar(u8, gameStr, ' ');
//     const t = Timer.start();
//     var game = board.Board.initial();
//     var bestMoves = std.ArrayList(board.Move).init(alloc);
//     var undoStack = std.ArrayList(board.OldMove).init(alloc);
//     var m: usize = 0;
//     while (true) {
//         try bestMoves.append(try strat.bestMoveIterative(&game, game.nextPlayer, 5, 5000, &search.NoTrackLines.I));

//         const word = moves.next() orelse break;
//         std.debug.assert(word.len == 4 or word.len == 5);
//         var moveStr = std.mem.zeroes([5]u8);
//         @memcpy(moveStr[0..word.len], word);

//         print("{}. {b}. play {s}\n", .{ m, game.zoidberg, word });
//         try undoStack.append(try @import("uci.zig").playAlgebraic(&game, moveStr));
//         m += 1;
//     }

//     for (0..undoStack.items.len) |i| {
//         const index = undoStack.items.len - 1 - i;
//         print("undo {}\n", .{index});
//         game.unplay(undoStack.items[index]);
//     }

//     try std.testing.expectEqual(game.zoidberg, 1);
//     print("\nFinished game in {}ms.\n", .{t.get()});
//     return bestMoves;
// }

// var finalBoard: ?board.Board = null;
// fn checkGameTime(comptime strategy: type, comptime moveCount: comptime_int) !i128 {
//     var game = board.Board.initial();
//     const t = Timer.start();
//     var player = board.Colour.White;
//     for (0..moveCount) |_| {
//         const move = try strategy.bestMove(&game, player);
//         _ = game.play(move);
//         player = player.other();
//     }

//     // TODO: the memomap changes the game?? this is a problem!
//     // Since I want to compare times, each run must play the same game or it would be unfair.
//     // if (finalBoard) |expectedBoard| {
//     //     if (!std.meta.eql(game.squares, expectedBoard.squares)) @panic("Played different game. Time comparison invalid.");
//     // } else {
//     //     finalBoard = game;
//     // }
//     return t.get();
// }
