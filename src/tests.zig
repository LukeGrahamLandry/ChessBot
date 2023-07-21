const std = @import("std");
const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;
const StratOpts = @import("search.zig").StratOpts;
const bestMove = @import("search.zig").bestMove;
const resetMemoTable = @import("search.zig").resetMemoTable;
const MoveFilter = @import("movegen.zig").MoveFilter;
const Move = @import("board.zig").Move;
const Stats = @import("search.zig").Stats;
const writeAlgebraic = @import("uci.zig").writeAlgebraic;
const print = @import("common.zig").print;
const assert = @import("common.zig").assert;
const setup = @import("common.zig").setup;
const Timer = @import("bench.zig").Timer;

const PerftResult = struct {
    games: u64 = 0,
    checkmates: u64 = 0,
};

// TODO: try using a memo table here as well.
fn countPossibleGames(game: *Board, me: Colour, remainingDepth: usize, arenaAlloc: std.mem.Allocator, comptime countMates: bool) !PerftResult {
    var results: PerftResult = .{};

    if (remainingDepth == 0) {
        if (!countMates) @panic("Should early exit on remainingDepth == 0");

        if (game.inCheck(me)) {
            const allMoves = try MoveFilter.Any.get().possibleMoves(game, me, arenaAlloc);
            var anyLegalMoves = false;
            for (allMoves) |move| {
                const unMove = game.play(move);
                defer game.unplay(unMove);
                if (game.inCheck(me)) continue; // move illigal
                anyLegalMoves = true;
                break;
            }
            if (!anyLegalMoves) {
                results.checkmates += 1;
            }
        }

        results.games += 1;
        return results;
    }

    const allMoves = try MoveFilter.Any.get().possibleMoves(game, me, arenaAlloc);

    // Trying to do depth 7 in one arena started using swap and got super slow. 
    // TODO: does normal search have the same problem?
    var arena2 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var nextAlloc = if (remainingDepth == 7) arena2.allocator() else arenaAlloc;

    for (allMoves) |move| {
        const unMove = game.play(move);
        defer game.unplay(unMove);
        if (game.inCheck(me)) continue; // move illigal

        if (!countMates and (remainingDepth - 1) == 0) {
            results.games += 1;
        } else {
            const next = try countPossibleGames(game, me.other(), remainingDepth - 1, nextAlloc, countMates);
            results.games += next.games;
            results.checkmates += next.checkmates;
        }

        _ = arena2.reset(.retain_capacity);
    }
    arena2.deinit();

    // Not checking for mate here, we only care about the ones on the bottom level.
    return results;
}

// Tests that the move generation gets the right number of nodes at each depth.
// Also exercises the Board.unplay function.
// Can call this in a loop to test speed of raw movegen.
test "count possible games" {
    // https://en.wikipedia.org/wiki/Shannon_number
    try (PerftTest{
        .possibleGames = &[_]u64{ 20, 400, 8902, 197281, 4865609 }, // 119060324, 3195901860 is too slow to deal with but passes
        .possibleMates = &[_]u64{ 0, 0, 0, 8, 347 }, //                    10828      435767
        .fen = @import("board.zig").INIT_FEN,
    }).run();
}

// This relies on tests not being run in parallel!
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub const PerftTest = struct {
    possibleGames: []const u64,
    possibleMates: []const u64,
    fen: []const u8,
    comptime countMates: bool = true,

    pub fn run(self: PerftTest) !void {
        var game = try Board.fromFEN(self.fen);
        for (self.possibleGames, self.possibleMates, 1..) |expectedGames, expectedMates, i| {
            const start = std.time.nanoTimestamp();
            const found = try countPossibleGames(&game, .White, i, arena.allocator(), self.countMates);
            const expected: PerftResult = .{ .games = expectedGames, .checkmates = (if (self.countMates) expectedMates else 0) };
            try std.testing.expectEqual(expected.games, found.games);
            if (!@import("builtin").is_test) print("- [{s}] Explored depth {} in {}ms.\n", .{ self.fen, i, @divFloor((std.time.nanoTimestamp() - start), @as(i128, std.time.ns_per_ms)) });

            // Ensure that repeatedly calling unplay didn't mutate the board.
            try std.testing.expectEqual(game, try Board.fromFEN(self.fen));
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

// This doesn't really matter unless I bring back the continue searching until no captures thing.
test "captures only" {
    const alloc = arena.allocator();
    inline for (bestMoveTests) |position| {
        const fen = position.fen;
        var initial = try Board.fromFEN(fen);
        var game = initial;
        const allMoves = try MoveFilter.Any.get().possibleMoves(&game, game.nextPlayer, alloc);
        const captureMoves = try MoveFilter.CapturesOnly.get().possibleMoves(&game, game.nextPlayer, alloc);

        // Every capture is a move but not all moves are captures.
        try std.testing.expect(allMoves.len >= captureMoves.len);

        // Count material to make sure it really captured something.
        const initialMaterial = game.simpleEval;
        for (captureMoves) |move| {
            const unMove = game.play(move);
            defer game.unplay(unMove);
            try std.testing.expect(initialMaterial != game.simpleEval);
            try std.testing.expect(move.isCapture);
        }
        try initial.expectEqual(&game); // undo move sanity check

        // Inverse of the above.
        for (allMoves) |move| {
            for (captureMoves) |check| {
                if (std.meta.eql(move, check)) break;
            } else {
                const unMove = game.play(move);
                defer game.unplay(unMove);
                try std.testing.expect(initialMaterial == game.simpleEval);
                try std.testing.expect(!move.isCapture);
            }
        }
        try initial.expectEqual(&game); // undo move sanity check

        _ = arena.reset(.retain_capacity);
    }
}

test "write fen" {
    var b = Board.initial();
    const fen = try b.toFEN(arena.allocator());
    try std.testing.expect(std.mem.eql(u8, fen, @import("board.zig").INIT_FEN));
}

test "sane zobrist numbers" {
    setup();
    try expectNoDuplicates(u64, &@import("common.zig").Magic.ZOIDBERG);
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
    setup();
    try doesStratMakeBestMove(.{});
}

// Run the same test with different strategies to narrow down problems.
// If only one part is wrong, the test with it disabled will still pass.

test "no memo makes best move" {
    setup();
    try doesStratMakeBestMove(.{ .doMemo = false });
}

test "no prune makes best move" {
    setup();
    try doesStratMakeBestMove(.{ .doPruning = false });
}

test "no iter makes best move" {
    setup();
    try doesStratMakeBestMove(.{ .doIterative = false });
}
