//! Uses UCI to run games between my engine and a crippled version of stockfish.

const std = @import("std");
const Board = @import("board.zig").Board;
const Move = @import("board.zig").Move;
const search = @import("search.zig");
const Timer = @import("common.zig").Timer;
const GameOver = @import("board.zig").GameOver;
const Learned = @import("learned.zig");
const assert = @import("common.zig").assert;
const print = @import("common.zig").print;
const UCI = @import("uci.zig");
const ListPool = @import("movegen.zig").ListPool;

// TODO: auto run shorter matches while increasing my time until equal skill.
const Opts = struct {
    maxMoves: usize = 250,
    gameCount: usize = 100,

    // These are passed to stockfish to limit its strength.
    fishSkillLevel: usize = 0, // 0-20.
    fishTimeLimitMS: u64 = 5,

    // These control my strength. The search stops when either time or depth is exceeded.
    // Limiting my time and allowing high depth like real games rewards performance improvements.
    myTimeLimitMS: i128 = 50,
    myMaxDepth: usize = 50, // anything above 10 is basically unlimited other than endgame.
    myMemoMB: usize = 100,
};

pub fn main() !void {
    const gt = Timer.start();

    // For things I don't care about freeing.
    var foreverArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var forever = foreverArena.allocator();

    const config: Opts = .{};
    print("[info]: {}\n", .{config});

    const cores = 4;
    var played = Shared.init(0);
    var stats: Stats = .{};
    var workers = try forever.alloc(Worker, cores);
    for (0..cores) |i| {
        workers[i] = .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .ctx = @import("common.zig").setup(config.myMemoMB),
            .fish = try Stockfish.init(forever),
            .thread = try std.Thread.spawn(.{}, workerFn, .{&workers[i]}),
            .gamesPlayed = &played,
            .stats = &stats,
            .config = config,
        };
    }

    for (workers) |worker| {
        worker.thread.join();
    }

    print("[info]: Done! Played {} games in {}ms.\n", .{ config.gameCount, gt.get() });
}

const Shared = std.atomic.Atomic(usize);

const Stats = struct {
    win: Shared = Shared.init(0),
    lose: Shared = Shared.init(0),
    draw: Shared = Shared.init(0),
    fail: Shared = Shared.init(0),

    fn log(self: Stats) void {
        print("[info]: Win {}. Lose {}. Draw {}. Error {}.\n", .{ self.win.loadUnchecked(), self.lose.loadUnchecked(), self.draw.loadUnchecked(), self.fail.loadUnchecked() });
    }
};

const Worker = struct {
    thread: std.Thread,
    config: Opts = .{},
    ctx: search.SearchGlobals,
    fish: Stockfish,
    arena: std.heap.ArenaAllocator,
    stats: *Stats,
    gamesPlayed: *Shared,
};

pub fn workerFn(self: *Worker) !void {
    try self.fish.send(.Init);
    self.fish.blockUntilRecieve(.InitOk);
    const fishLevelStr = try std.fmt.allocPrint(self.arena.allocator(), "{}", .{self.config.fishSkillLevel});
    try self.fish.send(.{ .SetOption = .{ .name = "Skill Level", .value = fishLevelStr } });

    while (true) {
        const g = self.gamesPlayed.fetchAdd(1, .SeqCst);
        if (g >= self.config.gameCount) break;
        print("[info]: Game {}/{}.\n", .{ g, self.config.gameCount });
        self.ctx.resetMemoTable();

        const result = playOneGame(self) catch |err| {
            _ = self.stats.fail.fetchAdd(1, .SeqCst);
            print("[info]: Game failed! {}\n", .{err});
            continue;
        };

        _ = switch (result) {
            .Continue => @panic("game done but continue?"),
            .WhiteWins => self.stats.win.fetchAdd(1, .SeqCst),
            .BlackWins => self.stats.lose.fetchAdd(1, .SeqCst),
            else => self.stats.draw.fetchAdd(1, .SeqCst),
        };

        self.stats.log();
        _ = self.arena.reset(.retain_capacity);
    }

    try self.fish.deinit();
}

// TODO: output pgn
// TODO: alternate who plays white
pub fn playOneGame(self: *Worker) !GameOver {
    const gt = Timer.start();
    try self.fish.send(.NewGame);
    try self.fish.send(.AreYouReady);
    self.fish.blockUntilRecieve(.ReadyOk);

    var moveHistory = std.ArrayList([5]u8).init(self.arena.allocator());
    var board = try Board.initial();
    for (0..self.config.maxMoves) |i| {
        _ = i;
        const move = search.bestMove(.{}, &self.ctx, &board, self.config.myMaxDepth, self.config.myTimeLimitMS) catch |err| {
            return try logGameOver(err, &board, &moveHistory, gt, &self.ctx.lists);
        };

        const moveStr = UCI.writeAlgebraic(move);
        try moveHistory.append(moveStr);
        _ = board.play(move);

        playUciMove(self, &board, &moveHistory) catch |err| {
            return try logGameOver(err, &board, &moveHistory, gt, &self.ctx.lists);
        };
    } else {
        print("[info]: Played {} moves each. Stopping the game because nobody cares. \n", .{self.config.maxMoves});
        board.debugPrint();
        return error.GameTooLong;
    }
}

fn logGameOver(err: anyerror, board: *Board, moveHistory: *std.ArrayList([5]u8), gt: Timer, lists: *ListPool) !GameOver {
    // for (moveHistory.items) |m| {
    //     print("{s} ", .{m});
    // }
    // print("\n", .{});

    switch (err) {
        error.GameOver => {
            const result = try board.gameOverReason(lists);
            const msg = switch (result) {
                .Continue => return err,
                .Stalemate => "Draw (stalemate).",
                .FiftyMoveDraw => "Draw (50 move rule).",
                .MaterialDraw => "Draw (insufficient material).",
                .RepetitionDraw => "Draw (3 repetition).",
                .WhiteWins => "White (luke) wins.",
                .BlackWins => "Black (fish) wins.",
            };
            print("[info]: {s} The game lasted {} ply ({} ms). \n", .{ msg, moveHistory.items.len, gt.get() });
            board.debugPrint();
            return result;
        },
        else => return err,
    }
}

fn playUciMove(self: *Worker, board: *Board, moveHistory: *std.ArrayList([5]u8)) !void {
    try self.fish.send(.AreYouReady);
    self.fish.blockUntilRecieve(.ReadyOk);
    if (moveHistory.items.len == 0) {
        try self.fish.send(.SetPositionInitial);
    } else {
        try self.fish.send(.{ .SetPositionMoves = .{ .board = board, .moves = moveHistory.items } });
    }
    try self.fish.send(.{ .Go = .{ .maxSearchTimeMs = self.config.fishTimeLimitMS } });

    const moveStr = m: {
        var bestMove: ?[5]u8 = null;
        var moveTime: u64 = 0;
        while (true) {
            const infoMsg = try self.fish.recieve();
            switch (infoMsg) {
                .Info => |info| {
                    if (info.time) |time| {
                        if (time <= self.config.fishTimeLimitMS) {
                            if (info.pvFirstMove) |move| {
                                bestMove = move;
                                moveTime = time;
                            }
                        } else {
                            try self.fish.send(.Stop);
                            // Not breaking out of the loop because still want to consume all calculations that took too long.
                        }
                    }
                },
                .BestMove => |bestmove| {
                    if (bestmove) |move| {
                        if (bestMove == null) {
                            print("[info]: The fish didn't move in time.\n", .{});
                            board.debugPrint();
                            return error.FishTooSlow;
                        } else {
                            break :m move;
                        }
                    } else {
                        // The fish knows it has no moves!
                        return error.GameOver;
                    }
                },
                else => continue,
            }
        }
        unreachable;
    };

    _ = try UCI.playAlgebraic(board, moveStr, &self.ctx.lists);
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
        try process.spawn(); // TODO: helpful error message if stockfish isnt installed.
        return .{
            .process = process,
            .buffer = .{ .unbuffered_reader = process.stdout.?.reader() },
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
            std.Thread.yield() catch continue;
            const msg = self.recieve() catch continue;
            if (std.meta.eql(msg, expected)) break;
        }
    }
};
