const std = @import("std");
const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;
const StratOpts = @import("moves.zig").StratOpts;
const Strategy = @import("moves.zig").Strategy;
const MoveFilter = @import("movegen.zig").MoveFilter;
const reverseFromKingIsInCheck = @import("movegen.zig").reverseFromKingIsInCheck;
const Move = @import("moves.zig").Move;
const assert = std.debug.assert;


// TODO: tests dont pass on maxDepth=2
const testFast = Strategy(.{ .beDeterministicForTest=true, .checkDetection=.Ignore, .doPruning=true, .maxDepth=3 });
const testSlow = Strategy(.{ .beDeterministicForTest=true, .checkDetection=.Ignore, .doPruning=false, .maxDepth=3 });
const Timer = @import("bench.zig").Timer;

// TODO: this should be generic over a the strategies to compare. 
fn testPruning(fen: [] const u8, me: Colour) !void {
    var game = try Board.fromFEN(fen);
    game.nextPlayer = me; // TODO
    var t = Timer.start();
    const slow = try testSlow.bestMove(&game, me);
    const t1 = t.end();
    t = Timer.start();
    const fast = try testFast.bestMove(&game, me);
    const t2 = t.end();

    if (!std.meta.eql(slow, fast)){
        std.debug.print("Moves did not match.\nInitial ({} to move):\n", .{ me });
        game.debugPrint();
        std.debug.print("Without pruning: \n", .{});
        game.copyPlay(slow).debugPrint();
        std.debug.print("With pruning: \n", .{});
        game.copyPlay(fast).debugPrint();
        return error.TestFailed;
    }
    if (t2 > t1 or t1 > 250) std.log.info("- testPruning (slow: {}ms, fast: {}ms) {s}\n", .{t1, t2, fen});

    var initial = try Board.fromFEN(fen);
    initial.nextPlayer = me;  // TODO

    try initial.expectEqual(&game); // undo move sanity check
}

// Tests that alpha-beta pruning chooses the same best move as a raw search. 
// Doesn't check if king is in danger to ignore move. // TODO: skip if no legal moves instead 
pub fn runTestComparePruning() !void {
    // TODO: need to include player in the fen because some positions have check and dont make sense for both
    // Not all of @import("movegen.zig").fensToTest because they're super slow.
    const fensToTest2 = [_] [] const u8 {
        "7K/p7/8/8/8/4b3/P2P4/7k",
        "7K/8/7B/8/8/8/Pq6/kN6",
        "7K/7p/8/8/8/r1q5/1P5P/k7", // Check and multiple best moves for black
        // "rn1q1bnr/1p2pkp1/2p2p1p/p2p1b2/1PP4P/3PQP2/P2KP1PB/RN3BNR", // hang a queen. super slow to run rn
    };
    inline for (fensToTest2) |fen| {
        inline for (.{Colour.White, Colour.Black}) |me| {
            try testPruning(fen, me);
        }
    }
}

test "simple compare pruning" {
    try runTestComparePruning();
}

// When I was sharing alpha-beta values between loop iterations when making best move list, it thought all the moves were equal.  
test "bestMoves eval equal" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var quickAlloc = arena.allocator();
    inline for (fensToTest) |fen| {
        inline for (.{Colour.White, Colour.Black}) |me| {
            defer assert(arena.reset(.retain_capacity));
            var initial = try Board.fromFEN(fen);
            initial.nextPlayer = me; // TODO
            var game = try Board.fromFEN(fen);
            game.nextPlayer = me; // TODO
            const bestMoves = try testFast.allEqualBestMoves(&game, me, quickAlloc);

            const allMoves = try MoveFilter.Any.get().possibleMoves(&game, me, quickAlloc);
            try std.testing.expect(allMoves.len >= bestMoves.items.len);  // sanity
            
            var memo = try testFast.MemoTable.initWithCapacity(10, quickAlloc);
            var expectedEval: ?i32 = null;
            for (bestMoves.items, 0..) |move, i| {
                const unMove = try game.play(move);
                defer game.unplay(unMove);
                try std.testing.expect(!(try testFast.inCheck(&game, me, quickAlloc)));

                var thing: usize = 0;
                // pay attention to negative sign
                const eval = -(try testFast.walkEval(&game, me.other(), testFast.config.maxDepth, testFast.config.followCaptureDepth, -99999999, -99999999, quickAlloc, &thing, &memo, false));
                if (expectedEval) |expected| {
                    if (eval != expected) {
                        std.debug.print("{} best moves but evals did not match.\nInitial ({} to move):\n", .{ bestMoves.items.len, me });
                        initial.debugPrint();
                        std.debug.print("best[0] (eval={}): \n", .{ expected});
                        initial.copyPlay(bestMoves.items[0]).debugPrint();
                        std.debug.print("best[{}]: (eval={})\n", .{ i, eval });
                        game.debugPrint();
                        return error.TestFailed;
                    }
                } else {
                    expectedEval = eval;
                }
            }

            try initial.expectEqual(&game); // undo move sanity check
        }
    }
}



var tst = std.testing.allocator;


const PerftResult = struct {
    games: u64 = 0,
    checkmates: u64 = 0,
};

const genKingCapturesOnly = @import("movegen.zig").MoveFilter.KingCapturesOnly.get();
fn countPossibleGames(game: *Board, me: Colour, remainingDepth: usize, alloc: std.mem.Allocator, comptime countMates: bool) !PerftResult {
    var results: PerftResult = .{};

    if (remainingDepth == 0) {
        if (!countMates) @panic("Should early exit on remainingDepth == 0");
        
        if (try reverseFromKingIsInCheck(game, me)) {
            const allMoves = try MoveFilter.Any.get().possibleMoves(game, me, alloc);
            defer alloc.free(allMoves);
            var anyLegalMoves = false;
            for (allMoves) |move| {
                const unMove = try game.play(move);
                defer game.unplay(unMove);
                if (try reverseFromKingIsInCheck(game, me)) continue; // move illigal
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
    const allMoves = try MoveFilter.Any.get().possibleMoves(game, me, alloc);
    defer alloc.free(allMoves);
    
    for (allMoves) |move| {
        const unMove = try game.play(move);
        defer game.unplay(unMove);
        if (try reverseFromKingIsInCheck(game, me)) continue; // move illigal

        if (!countMates and (remainingDepth - 1) == 0) {
            results.games += 1;
        } else {
            const next = try countPossibleGames(game, me.other(), remainingDepth - 1, alloc, countMates);
            results.games += next.games;
            results.checkmates += next.checkmates;
        }
    }

    // Not checking for mate here, we only care about the ones on the bottom level. 

    return results;
}

// Tests that the move generation gets the right number of nodes at each depth. 
// Also exercises the Board.unplay function.
// Can call this in a loop to test speed of raw movegen. 
pub fn runTestCountPossibleGames() !void {
    // https://en.wikipedia.org/wiki/Shannon_number
    try (PerftTest {
        .possibleGames = &[_] u64 { 20, 400, 8902, 197281, 4865609, 119060324 },  // 3195901860 is too slow to deal with but also fails TODO
        .possibleMates = &[_] u64 {  0,   0,    0,      8,     347,     10828 },  //     435767
        .fen = @import("board.zig").INIT_FEN,
    }).run();
}

test "count possible games" {
    try runTestCountPossibleGames();
}

const PerftTest = struct { 
    possibleGames: [] const u64,
    possibleMates: [] const u64,
    fen: [] const u8,
    comptime countMates: bool = true,

    fn run(self: PerftTest) !void{
        var tempA = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer tempA.deinit();
        var game = try Board.fromFEN(self.fen);
        for (self.possibleGames, self.possibleMates, 1..) |expectedGames, expectedMates, i| {
            const start = std.time.nanoTimestamp();
            // These parameters are backwards because it can't infer type from a comptime_int. This seems dumb. 
            const found = try countPossibleGames(&game, .White, i, tempA.allocator(), self.countMates);
            const expected: PerftResult = .{ .games=expectedGames, .checkmates=(if (self.countMates) expectedMates else 0) };
            try std.testing.expectEqual(expected.games, found.games);
            std.debug.print("- [{s}] Explored depth {} in {}ms.\n", .{self.fen, i, @divFloor((std.time.nanoTimestamp() - start), @as(i128, std.time.ns_per_ms))});
            // Ensure that repeatedly calling unplay didn't mutate the board.
            try std.testing.expectEqual(game, try Board.fromFEN(self.fen));
            // _ = tempA.reset(.retain_capacity);
        }
    }
};

test "perft 3" {
    // https://www.chessprogramming.org/Perft_Results
    try (PerftTest {
        .possibleGames = &[_] u64 { 14, 191, 2812, 43238, 674624, 11030083, }, // 178633661 slow but passes
        .possibleMates = &[_] u64 {  0,   0,    0,    17,      0,     2733,  }, // 87
        .fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w",
    }).run();
}

const MoveList = std.ArrayList(Move);
fn testCapturesOnly(fen: [] const u8) !void {
    inline for (.{Colour.White, Colour.Black}) |me| {
        var game = try Board.fromFEN(fen);
        game.nextPlayer = me; // TODO
        const big = try MoveFilter.Any.get().possibleMoves(&game, me, tst);
        // var notCaptures = MoveList.fromOwnedSlice(tst, big);
        defer tst.free(big);
        const small = try MoveFilter.CapturesOnly.get().possibleMoves(&game, me, tst);
        defer tst.free(small);

        // Every capture is a move but not all moves are captures. 
        try std.testing.expect(big.len >= small.len);

        // Count material to make sure it really captured something. 
        const initialMaterial = MoveFilter.Any.get().simpleEval(&game);
        for (small) |move| {
            const unMove = try game.play(move);
            defer game.unplay(unMove);
            const newMaterial = MoveFilter.Any.get().simpleEval(&game);
            try std.testing.expect(initialMaterial != newMaterial);

            // Captures should have the flag set.
            try std.testing.expect(move.isCapture);
        }
        var initial = try Board.fromFEN(fen);
        initial.nextPlayer = me; // TODO
        try initial.expectEqual(&game); // undo move sanity check

        // Inverse of the above. 
        for (big) |move| {
            for (small) |check| {
                if (std.meta.eql(move, check)) break;
            } else {
                const unMove = try game.play(move);
                defer game.unplay(unMove);
                const newMaterial = MoveFilter.Any.get().simpleEval(&game);
                try std.testing.expect(initialMaterial == newMaterial);
                try std.testing.expect(!move.isCapture);
            }
        }

        try initial.expectEqual(&game); // undo move sanity check
    }
}


// TODO: need to include player in the fen because some positions have check and dont make sense for both
pub const fensToTest = [_] [] const u8 {
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR",  // The initial position has many equal moves, this makes sure I'm not accidently making random choices while testing. 
    "rnb1kbnr/ppqppppp/2p5/3N4/8/8/PPPPPPPP/R1BQKBNR",
    "rnbqkbnr/pp1ppppp/2p5/3N4/8/8/PPPPPPPP/R1BQKBNR",
    "7K/p7/8/8/8/4b3/P2P4/7k",
    "7K/8/7B/8/8/8/Pq6/kN6",
    "7K/7p/8/8/8/r1q5/1P5P/k7", // Check and multiple best moves for black
    // "rn1q1bnr/1p2pkp1/2p2p1p/p2p1b2/1PP4P/3PQP2/P2KP1PB/RN3BNR", // hang a queen
};

test "captures only" {
    inline for (fensToTest) |fen| {
        try testCapturesOnly(fen);
    }
}


test "write fen" {
    var b = Board.initial();
    const fen = try b.toFEN(tst);
    defer tst.free(fen);
    try std.testing.expect(std.mem.eql(u8, fen, @import("board.zig").INIT_FEN));
}
