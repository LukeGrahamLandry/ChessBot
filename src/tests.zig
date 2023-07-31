const std = @import("std");
const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;
const StratOpts = @import("search.zig").StratOpts;
const bestMove = @import("search.zig").bestMove;
const resetMemoTable = @import("search.zig").resetMemoTable;
const Move = @import("board.zig").Move;
const Stats = @import("search.zig").Stats;
const writeAlgebraic = @import("uci.zig").writeAlgebraic;
const print = @import("common.zig").print;
const assert = @import("common.zig").assert;
const setup = @import("common.zig").setup;
const Timer = @import("bench.zig").Timer;
const ListPool = @import("movegen.zig").ListPool;
const countPossibleGames = @import("perft.zig").countPossibleGames;

pub const PerftResult = struct {
    games: u64 = 0,
    checkmates: u64 = 0,
};

const defaultMemoMB = 100;

// Tests that the move generation gets the right number of nodes at each depth.
// Also exercises the Board.unplay function.
// Can call this in a loop to test speed of raw movegen.
// TODO: parse from string like big perft does
test "count possible games" {
    // https://en.wikipedia.org/wiki/Shannon_number
    try (PerftTest{
        .possibleGames = &[_]u64{ 20, 400, 8902, 197281, 4865609 }, // 119060324, 3195901860 is too slow to deal with but passes
        .possibleMates = &[_]u64{ 0, 0, 0, 8, 347 }, //                    10828      435767
        .fen = @import("board.zig").INIT_FEN,
    }).run();
}

test "another perft" {
    // http://www.rocechess.ch/perft.html
    try (PerftTest{
        .possibleGames = &[_]u64{ 48, 2039, 97862, 4085603 },
        .possibleMates = &[_]u64{ 0, 0, 0, 0 },
        .fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        .countMates = false,
    }).run();
}

// This relies on tests not being run in parallel!
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub const PerftTest = struct {
    possibleGames: []const u64,
    possibleMates: []const u64,
    fen: []const u8,
    countMates: bool = false, // TODO: bring back

    pub fn run(self: PerftTest) !void {
        var ctx = setup(0);
        const initial = try Board.fromFEN(self.fen);
        var game = initial;
        for (self.possibleGames, self.possibleMates, 1..) |expectedGames, expectedMates, i| {
            const start = std.time.nanoTimestamp();
            const found = try countPossibleGames(&game, .White, i, &ctx.lists, self.countMates);
            const expected: PerftResult = .{ .games = expectedGames, .checkmates = (if (self.countMates) expectedMates else 0) };
            try std.testing.expectEqual(expected.games, found.games);
            if (!@import("builtin").is_test) print("- [{s}] Explored depth {} in {}ms.\n", .{ self.fen, i, @divFloor((std.time.nanoTimestamp() - start), @as(i128, std.time.ns_per_ms)) });

            // Ensure that repeatedly calling unplay didn't mutate the board.
            game.pastBoardHashes = initial.pastBoardHashes; // undoing leaves junk in extra array space
            try std.testing.expectEqual(game, initial);
            _ = arena.reset(.retain_capacity);
        }
    }
};

test "perft 3" {
    // https://www.chessprogramming.org/Perft_Results
    try (PerftTest{
        .possibleGames = &[_]u64{ 14, 191, 2812, 43238, 674624 }, // 11030083, 178633661 slow but passes
        .possibleMates = &[_]u64{ 0, 0, 0, 17, 0 }, // 2733, 87
        .fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w",
    }).run();
}

test "write fen" {
    var b = try Board.initial();
    const fen = try b.toFEN(arena.allocator());
    try std.testing.expect(std.mem.eql(u8, fen, @import("board.zig").INIT_FEN));
}

test "sane zobrist numbers" {
    _ = setup(0);

    const items = &@import("learned.zig").ZOIDBERG;
    for (items) |val| {
        var count: usize = 0;
        for (items) |check| {
            if (std.meta.eql(val, check)) count += 1;
        }
        if (val == 0) {
            // 0 is used for empty squares that I don't want to change the hash because I don't think they're tracked rigorously. 64 squares for each colour.
            try std.testing.expectEqual(count, 128);
        } else {
            try std.testing.expectEqual(count, 1);
        }
    }
}

test "dir" {
    try std.testing.expectEqual(Colour.White.dir(), 1);
    try std.testing.expectEqual(Colour.Black.dir(), -1);
}

const TestCase = struct {
    fen: []const u8,
    best: []const u8,
};

const maxDepth = 3;
const maxTime = 1000;
const bestMoveTests = [_]TestCase{
    .{ .fen = "rnbqk1nr/ppppbppp/8/4P3/6P1/8/PPPPP2P/RNBQKBNR b KQkq g3 0 3", .best = "e7h4" },
    .{ .fen = "rnbqkb1r/ppp1ppp1/5n2/3pP2p/3P4/8/PPP2PPP/RNBQKBNR w KQkq h6 0 4", .best = "e5f6" },
    .{ .fen = "6nk/2b3nn/1P6/8/8/8/1B6/6RK w - - 0 1", .best = "b2g7" },
    .{ .fen = "6nk/7n/5N2/8/8/2q5/1B2b3/6RK w - - 0 1", .best = "g1g8" },
};

fn doesStratMakeBestMove(comptime opts: StratOpts) !void {
    var ctx = setup(0);
    for (bestMoveTests) |position| {
        ctx.resetMemoTable();
        var game = try Board.fromFEN(position.fen);
        const initialHash = game.zoidberg;
        const move = try bestMove(opts, &ctx, &game, maxDepth, maxTime);

        if (!std.mem.eql(u8, position.best[0..4], writeAlgebraic(move)[0..4])) {
            game.debugPrint();
            print("Expected best move to be {s} but it was {s}. \n{}\n", .{ position.best, writeAlgebraic(move), opts });
            return error.TestExpectedEqual;
        }

        // Check the unplay usage in bestMove.
        try std.testing.expectEqual(initialHash, game.zoidberg);
        try std.testing.expectEqualStrings(position.fen, try game.toFEN(arena.allocator()));
    }
}

test "default strat makes best move" {
    try doesStratMakeBestMove(.{});
}

// Run the same test with different strategies to narrow down problems.
// If only one part is wrong, the test with it disabled will still pass.

test "no memo makes best move" {
    try doesStratMakeBestMove(.{ .doMemo = false });
}

test "no prune makes best move" {
    try doesStratMakeBestMove(.{ .doPruning = false });
}

test "no iter makes best move" {
    try doesStratMakeBestMove(.{ .doIterative = false });
}

test "precalc" {
    _ = @import("precalc.zig");
}

// TODO: should test all kinds of promotion
test "parse uci moves promotion" {
    var ctx = setup(0);
    const moves = "position startpos moves d2d4 d7d5 e2e3 g8f6 b1c3 e7e6 g1f3 c7c5 f1b5 c8d7 d4c5 f8d6 c5d6 d7b5 c3b5 d8a5 b5c3 a5c5 d1d4 c5d6 d4a4 e8e7 a4b5 d6c7 b5b4 e7e8 c1d2 a7a5 b4d4 a5a4 d4e5 c7e5 f3e5 b8c6 e5c6 b7c6 c3d5 f6d5 e3e4 c6c5 e4d5 e6d5 e1c1 a4a3 h1e1 e8d7 b2b4 d7c6 b4c5 a8a4 d2c3 a4g4 e1e7 f7f6 e7e6 c6c5 e6a6 g4g2 c3d4 c5b5 a6d6 g2h2 d6d5 b5c6 d5c5 c6b7 c5b5 b7a6 b5b3 h8d8 b3a3 a6b5 a3a7 h2g2 a7b7 b5c6 b7f7 g2g4 d4c3 d8d1 c1d1 g4g2 c3d4 c6d5 c2c3 d5e6 f7a7 g2g1 d1c2 e6f5 a7d7 f5g6 f2f4 g1e1 f4f5 g6h6 c2b3 e1e2 d7f7 e2e8 a2a4 e8g8 d4e3 h6h5 e3f4 h5g4 f4d6 g4f5 f7b7 f5e4 b7d7 e4d5 d6g3 d5e4 g3d6 h7h5 a4a5 e4d5 d6c7 d5e6 d7d6 e6f5 d6d5 f5g4 d5d7 g4f3 c7d6 f3f2 c3c4 f2e3 a5a6 e3e2 a6a7 e2e3 d6b8 g8e8 a7a8q";
    const expectedFenStart = "QB2r3/3R2p1/5p2/7p/2P5/1K2k3/8/8 b - - 0";
    const cmd = try @import("uci.zig").UciCommand.parse(moves, arena.allocator(), &ctx.lists);
    switch (cmd) {
        .SetPositionMoves => |info| {
            const foundFen = try info.board.toFEN(arena.allocator());
            try std.testing.expect(std.mem.startsWith(u8, foundFen, expectedFenStart));
        },
        else => return error.TestExpectedEqual,
    }
}
