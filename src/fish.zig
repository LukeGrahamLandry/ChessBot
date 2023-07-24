//! Uses UCI to run games between my engine and a crippled version of stockfish. 

const std = @import("std");
const Board = @import("board.zig").Board;
const Move = @import("board.zig").Move;
const search = @import("search.zig");
const Timer = @import("common.zig").Timer;
const GameOver = @import("board.zig").GameOver;
const Magic = @import("common.zig").Magic;
const assert = @import("common.zig").assert;
const UCI = @import("uci.zig");

// TODO: auto run shorter matches while increasing my time until equal skill.
const Opts = struct {
    maxMoves: usize = 250,
    gameCount: usize = 100,

    // These are passed to stockfish to limit its strength.
    fishSkillLevel: usize = 0, // 0-20.
    fishTimeLimitMS: i128 = 2,

    // These control my strength. The search stops when either time or depth is exceeded.
    // Limiting my time and allowing high depth like real games rewards performance improvements.
    myTimeLimitMS: i128 = 26,
    myMaxDepth: usize = 50, // anything above 10 is basically unlimited other than endgame.
    myMemoMB: usize = 100,
};

const config: Opts = .{};
var shouldPrint = false;

pub fn main() !void {
    @import("common.zig").setup(config.myMemoMB);
    std.debug.print("[info]: {}\n", .{config});
    const fishLevelStr = try std.fmt.allocPrint(general.allocator(), "{}", .{config.fishSkillLevel});
    defer general.allocator().free(fishLevelStr);
    var fish = try Stockfish.init(general.allocator());
    try fish.send(.Init);
    fish.blockUntilRecieve(.InitOk);
    try fish.send(.{ .SetOption = .{ .name = "Skill Level", .value = fishLevelStr } });

    var gt = Timer.start();
    var failed: u32 = 0;
    // TODO: its morally wrong for this to not be an array
    var results = std.AutoHashMap(GameOver, u32).init(general.allocator());
    for (1..config.gameCount + 1) |g| {
        if (g != 0) {
            std.debug.print("[info]: Win {}. Lose {}. Draw {}. Error {}.\n", .{ results.get(.WhiteWins) orelse 0, results.get(.BlackWins) orelse 0, (results.get(.Stalemate) orelse 0) + (results.get(.FiftyMoveDraw) orelse 0) + (results.get(.MaterialDraw) orelse 0), failed });
        }
        std.debug.print("[info]: Game {}/{}.\n", .{ g, config.gameCount });
        const result = playOneGame(&fish, g, config.gameCount) catch |err| {
            failed += 1;
            std.debug.print("[info]: Game failed! {}\n", .{err});
            search.resetMemoTable();
            continue;
        };
        search.resetMemoTable();
        const count = (results.get(result) orelse 0) + 1;
        try results.put(result, count);
    }

    const time = gt.get();
    std.debug.print("[info]: Done! Played {} games in {}ms.\n", .{ config.gameCount, time });
    std.debug.print("[info]: Win {}. Lose {}. Draw {}. Error {}.\n", .{ results.get(.WhiteWins) orelse 0, results.get(.BlackWins) orelse 0, (results.get(.Stalemate) orelse 0) + (results.get(.FiftyMoveDraw) orelse 0) + (results.get(.MaterialDraw) orelse 0), failed });
    std.debug.print("[info] {}\n", .{config});
    try fish.deinit();
}

// TODO: output pgn
// TODO: alternate who plays white
pub fn playOneGame(fish: *Stockfish, gameIndex: usize, gamesTotal: u32) !GameOver {
    try fish.send(.NewGame);
    try fish.send(.AreYouReady);
    fish.blockUntilRecieve(.ReadyOk);

    var alloc = general.allocator();
    var moveHistory = std.ArrayList([5]u8).init(alloc);
    var gt = Timer.start();
    var board = Board.initial();
    if (shouldPrint) board.debugPrint();

    for (0..config.maxMoves) |i| {
        log("[info]: Move {}. Game {}/{}.\n", .{ i, gameIndex, gamesTotal });
        log("[info]: I'm thinking.\n", .{});
        var t = Timer.start();
        const move = search.bestMove(.{}, &board, config.myMaxDepth, config.myTimeLimitMS) catch |err| {
            return try logGameOver(err, &board, &moveHistory, gt);
        };

        const moveStr = UCI.writeAlgebraic(move);
        try moveHistory.append(moveStr);
        _ = board.play(move);
        log("[info]: I played {s} in {}ms.\n", .{ moveStr, t.get() });
        if (shouldPrint) board.debugPrint();

        playUciMove(fish, &board, &moveHistory) catch |err| {
            return try logGameOver(err, &board, &moveHistory, gt);
        };
        if (shouldPrint) board.debugPrint();
    } else {
        log("[info]: Played {} moves each. Stopping the game because nobody cares. \n", .{config.maxMoves});
        board.debugPrint();
        return error.GameTooLong;
    }
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (shouldPrint) std.debug.print(fmt, args);
}

var general = (std.heap.GeneralPurposeAllocator(.{}){});

fn logGameOver(err: anyerror, board: *Board, moveHistory: *std.ArrayList([5]u8), gt: Timer) !GameOver {
    for (moveHistory.items) |m| {
        log("{s} ", .{m});
    }
    log("\n", .{});

    switch (err) {
        error.GameOver => {
            const result = try board.gameOverReason(&@import("common.zig").lists);
            const msg = switch (result) {
                .Continue => "Game over but player can still move? This is a bug!",
                .Stalemate => "Draw (stalemate).",
                .FiftyMoveDraw => "Draw (50 move rule).",
                .MaterialDraw => "Draw (insufficient material).",
                .WhiteWins => "White (luke) wins.",
                .BlackWins => "Black (fish) wins.",
            };
            const time = gt.get();
            std.debug.print("[info]: {s} The game lasted {} ply ({} ms). \n", .{ msg, moveHistory.items.len, time });
            board.debugPrint();
            return result;
        },
        else => return err,
    }
}

fn playUciMove(fish: *Stockfish, board: *Board, moveHistory: *std.ArrayList([5]u8)) !void {
    try fish.send(.AreYouReady);
    fish.blockUntilRecieve(.ReadyOk);
    if (moveHistory.items.len == 0) {
        try fish.send(.SetPositionInitial);
    } else {
        try fish.send(.{ .SetPositionMoves = .{ .board = board, .moves = moveHistory.items } });
    }
    try fish.send(.{ .Go = .{ .maxSearchTimeMs = config.fishTimeLimitMS } });

    const moveStr = m: {
        var bestMove: ?[5]u8 = null;
        var moveTime: u64 = 0;
        while (true) {
            const infoMsg = try fish.recieve();
            switch (infoMsg) {
                .Info => |info| {
                    if (info.time) |time| {
                        if (time <= config.fishTimeLimitMS) {
                            if (info.pvFirstMove) |move| {
                                bestMove = move;
                                moveTime = time;
                            }
                        } else {
                            try fish.send(.Stop);
                            // Not breaking out of the loop because still want to consume all calculations that took too long.
                        }
                    }
                },
                .BestMove => |bestmove| {
                    if (bestmove) |move| {
                        if (bestMove == null) {
                            return error.GameOver;
                        } else {
                            log("[info]: The fish played {s} in {}ms.\n", .{ move, moveTime });
                            break :m move;
                        }
                    } else {
                        log("[info]: The fish knows it has no moves!\n", .{});
                        return error.GameOver;
                    }
                },
                else => continue,
            }
        }
        unreachable;
    };

    _ = try UCI.playAlgebraic(board, moveStr);
    try moveHistory.append(moveStr);
}

pub const Stockfish = struct {
    process: std.ChildProcess,
    buffer: Reader,
    const Reader = std.io.BufferedReader(4096, std.fs.File.Reader);

    // I think the allocator is just used for arg strings and stuff. 
    // TODO: make sure its not putting all output there but that seems dumb and I think I would notice. 
    pub fn init(alloc: std.mem.Allocator) !Stockfish {
        var process = std.ChildProcess.init(&[_][]const u8{"stockfish"}, alloc);
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Pipe;
        process.stdout = std.io.getStdIn();
        try process.spawn();  // TODO: helpful error message if stockfish isnt installed.
        return .{ 
            .process = process, 
            .buffer = .{ .unbuffered_reader=process.stdout.?.reader() },
        };
    }

    pub fn deinit(self: *Stockfish) !void {
        _ = try self.process.kill();
    }

    pub fn send(self: *Stockfish, cmd: UCI.UciCommand) !void {
        try cmd.writeTo(self.process.stdin.?.writer());
    }

    pub fn recieve(self: *Stockfish) !UCI.UciResult {
        var buf: [16384]u8 = undefined;
        var resultStream = std.io.fixedBufferStream(&buf);
        // Don't care about the max because fixedBufferStream will give a write error if it overflows.
        try self.buffer.reader().streamUntilDelimiter(resultStream.writer(), '\n', null);
        const msg = resultStream.getWritten();
        return try UCI.UciResult.parse(msg);
    }

    pub fn blockUntilRecieve(self: *Stockfish, expected: UCI.UciResult) void {
        // TODO: timeout detect to if it died
        while (true) {
            const msg = self.recieve() catch continue;
            if (std.meta.eql(msg, expected)) break;
        }
    }
};
