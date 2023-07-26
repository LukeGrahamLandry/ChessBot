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
var theLists = &@import("common.zig").lists;
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
    setup(defaultMemoMB);
    // https://en.wikipedia.org/wiki/Shannon_number
    try (PerftTest{
        .possibleGames = &[_]u64{ 20, 400, 8902, 197281, 4865609 }, // 119060324, 3195901860 is too slow to deal with but passes
        .possibleMates = &[_]u64{ 0, 0, 0, 8, 347 }, //                    10828      435767
        .fen = @import("board.zig").INIT_FEN,
    }).run();
}


test "another perft" {
    setup(defaultMemoMB);
    // http://www.rocechess.ch/perft.html
    try (PerftTest{
        .possibleGames = &[_]u64{ 48, 2039, 97862, 4085603 },
        .possibleMates = &[_]u64{0,0,0,0},
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
    countMates: bool = false,  // TODO: bring back

    pub fn run(self: PerftTest) !void {
        const initial = try Board.fromFEN(self.fen);
        var game = initial;
        for (self.possibleGames, self.possibleMates, 1..) |expectedGames, expectedMates, i| {
            const start = std.time.nanoTimestamp();
            const found = try countPossibleGames(&game, .White, i, theLists, self.countMates);
            const expected: PerftResult = .{ .games = expectedGames, .checkmates = (if (self.countMates) expectedMates else 0) };
            try std.testing.expectEqual(expected.games, found.games);
            if (!@import("builtin").is_test) print("- [{s}] Explored depth {} in {}ms.\n", .{ self.fen, i, @divFloor((std.time.nanoTimestamp() - start), @as(i128, std.time.ns_per_ms)) });

            // Ensure that repeatedly calling unplay didn't mutate the board.
            game.pastBoardHashes = initial.pastBoardHashes;  // undoing leaves junk in extra array space 
            try std.testing.expectEqual(game, initial);
            _ = arena.reset(.retain_capacity);
        }
    }
};

test "perft 3" {
    setup(defaultMemoMB);
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
    setup(defaultMemoMB);
    try expectNoDuplicates(u64, &@import("common.zig").Learned.ZOIDBERG);
}

test "dir" {
    try std.testing.expectEqual(Colour.White.dir(), 1);
    try std.testing.expectEqual(Colour.Black.dir(), -1);
}

fn expectNoDuplicates(comptime T: type, items: []T) !void {
    for (items) |val| {
        var count: usize = 0;
        for (items) |check| {
            if (std.meta.eql(val, check)) count += 1;
        }
        try std.testing.expectEqual(count, 1);
    }
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
};

fn doesStratMakeBestMove(comptime opts: StratOpts) !void {
    for (bestMoveTests) |position| {
        resetMemoTable();
        var game = try Board.fromFEN(position.fen);
        const initialHash = game.zoidberg;
        const move = try bestMove(opts, &game, maxDepth, maxTime);

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
    setup(defaultMemoMB);
    try doesStratMakeBestMove(.{});
}

// Run the same test with different strategies to narrow down problems.
// If only one part is wrong, the test with it disabled will still pass.

test "no memo makes best move" {
    setup(defaultMemoMB);
    try doesStratMakeBestMove(.{ .doMemo = false });
}

test "no prune makes best move" {
    setup(defaultMemoMB);
    try doesStratMakeBestMove(.{ .doPruning = false });
}

test "no iter makes best move" {
    setup(defaultMemoMB);
    try doesStratMakeBestMove(.{ .doIterative = false });
}

test "precalc" {
    _ = @import("precalc.zig");
}