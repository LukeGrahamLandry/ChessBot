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

    engineATimeLimitMS: u64 = 50,
    engineBTimeLimitMS: u64 = 5,

    // These control my strength. The search stops when either time or depth is exceeded.
    // Limiting my time and allowing high depth like real games rewards performance improvements.
    // myTimeLimitMS: i128 = 50,
    // myMaxDepth: usize = 50, // anything above 10 is basically unlimited other than endgame.
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
            .thread = try std.Thread.spawn(.{}, workerFn, .{&workers[i]}),
            .gamesPlayed = &played,
            .stats = &stats,
            .config = config,
            .engineA = try Stockfish.initOther("/Users/luke/test/zig-out/bin/uci", forever),
            // .engineB = try Stockfish.initOther("/Users/luke/test/zig-out/bin/uci", forever),
            .engineB = try Stockfish.initOther("stockfish", forever),
        };
    }

    for (workers) |worker| {
        worker.thread.join();
    }

    print("[info]: Done! Played {} games in {}ms.\n", .{ config.gameCount, gt.get() });
}

const Shared = std.atomic.Value(usize);

const Stats = struct {
    winA: Shared = Shared.init(0),
    winB: Shared = Shared.init(0),
    draw: Shared = Shared.init(0),
    fail: Shared = Shared.init(0),

    fn log(self: Stats) void {
        print("[info]: A Wins {}. B Wins {}. Draw {}. Error {}.\n", .{ self.winA.raw, self.winB.raw, self.draw.raw, self.fail.raw });
    }
};

const Worker = struct {
    thread: std.Thread,
    config: Opts = .{},
    ctx: search.SearchGlobals,
    engineA: Stockfish,
    engineB: Stockfish,
    arena: std.heap.ArenaAllocator,
    stats: *Stats,
    gamesPlayed: *Shared,
};

pub fn workerFn(self: *Worker) !void {
    std.time.sleep(std.time.ns_per_ms * 50);

    try self.engineA.send(.Init);
    try self.engineB.send(.Init);
    self.engineA.blockUntilRecieve(.InitOk);
    self.engineB.blockUntilRecieve(.InitOk);

    const fishLevelStr = try std.fmt.allocPrint(self.arena.allocator(), "{}", .{self.config.fishSkillLevel});
    try self.engineB.send(.{ .SetOption = .{ .name = "Skill Level", .value = fishLevelStr } });
    // try self.engineA.send(.{ .SetOption = .{ .name = "Skill Level", .value = fishLevelStr } });

    while (true) {
        const g = self.gamesPlayed.fetchAdd(1, .seq_cst);
        if (g >= self.config.gameCount) break;
        print("[info]: Game {}/{}.\n", .{ g, self.config.gameCount });
        self.ctx.resetMemoTable();

        const result = playOneGame(self) catch |err| {
            _ = self.stats.fail.fetchAdd(1, .seq_cst);
            print("[info]: Game failed! {}\n", .{err});
            continue;
        };

        _ = switch (result) {
            .Continue => @panic("game done but continue?"),
            .WhiteWins => self.stats.winA.fetchAdd(1, .seq_cst),
            .BlackWins => self.stats.winB.fetchAdd(1, .seq_cst),
            else => self.stats.draw.fetchAdd(1, .seq_cst),
        };

        self.stats.log();
        _ = self.arena.reset(.retain_capacity);
    }

    try self.engineA.deinit();
    try self.engineB.deinit();
}

// TODO: output pgn
// TODO: alternate who plays white
pub fn playOneGame(self: *Worker) !GameOver {
    const gt = Timer.start();

    try self.engineA.send(.NewGame);
    try self.engineA.send(.AreYouReady);
    try self.engineB.send(.NewGame);
    try self.engineB.send(.AreYouReady);
    self.engineA.blockUntilRecieve(.ReadyOk);
    self.engineB.blockUntilRecieve(.ReadyOk);

    var moveHistory = std.ArrayList([5]u8).init(self.arena.allocator());
    var board = try Board.initial();
    for (0..self.config.maxMoves) |_| {
        const move = search.bestMove(.{}, &self.ctx, &board, 50, self.config.engineATimeLimitMS) catch |err| {
            // playUciMove(self, &self.engineA, self.config.engineATimeLimitMS, &board, &moveHistory) catch |err| {
            return try logGameOver(err, &board, &moveHistory, gt, &self.ctx.lists);
        };
        const moveStr = UCI.writeAlgebraic(move);
        try moveHistory.append(moveStr);
        _ = board.play(move);
        // board.debugPrint();

        playUciMove(self, &self.engineB, self.config.engineBTimeLimitMS, &board, &moveHistory) catch |err| {
            return try logGameOver(err, &board, &moveHistory, gt, &self.ctx.lists);
        };

        // board.debugPrint();
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
                // TODO: print engine names.
                .WhiteWins => "Engine A wins.",
                .BlackWins => "Engine B wins.",
            };
            print("[info]: {s} The game lasted {} ply ({} ms). \n", .{ msg, moveHistory.items.len, gt.get() });
            board.debugPrint();
            return result;
        },
        else => return err,
    }
}

fn playUciMove(self: *Worker, engine: *Stockfish, timeLimitMS: u64, board: *Board, moveHistory: *std.ArrayList([5]u8)) !void {
    // print("----------\n", .{});
    try engine.send(.AreYouReady);
    engine.blockUntilRecieve(.ReadyOk);
    try engine.send(.{ .SetPositionMoves = .{ .board = board } });
    try engine.send(.{ .Go = .{ .maxSearchTimeMs = timeLimitMS } });

    const moveStr = m: {
        var bestMove: ?[5]u8 = null;
        var moveTime: u64 = 0;
        while (true) {
            const infoMsg = try engine.recieve();
            // print("{}\n", .{infoMsg});
            switch (infoMsg) {
                .Info => |info| {
                    // print("info: {s}\n", .{info.pvFirstMove.?});
                    if (info.time) |time| {
                        if (time <= timeLimitMS) {
                            if (info.pvFirstMove) |move| {
                                bestMove = move;
                                moveTime = time;
                            }
                        } else {
                            try engine.send(.Stop);
                            // Not breaking out of the loop because still want to consume all calculations that took too long.
                        }
                    }
                },
                .BestMove => |engineBestMove| {
                    if (engineBestMove) |move| {
                        if (bestMove == null) {
                            print("[info]: The fish didn't move in time.\n", .{});
                            board.debugPrint();
                            return error.FishTooSlow;
                        } else {
                            // print("{}\n", .{std.mem.eql(u8, &move, &bestMove.?)});
                            break :m move;
                            // break :m bestMove.?;  // TODO: why does this seem to play better?
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

    // board.debugPrint();
    // print("Move: {s}\n", .{moveStr});
    // print("----------\n", .{});
    _ = try UCI.playAlgebraic(board, moveStr, &self.ctx.lists);
    try moveHistory.append(moveStr);

    const reason = try board.gameOverReason(&self.ctx.lists);
    if (reason != .Continue) return error.GameOver;
}

pub const Stockfish = struct {
    process: std.process.Child,

    // I think the allocator is just used for arg strings and stuff.
    // TODO: make sure its not putting all output there but that seems dumb and I think I would notice.
    pub fn init(alloc: std.mem.Allocator) !@This() {
        // TODO: helpful error message if stockfish isnt installed.
        return try Stockfish.initOther("stockfish", alloc);
    }

    pub fn initOther(command: []const u8, alloc: std.mem.Allocator) !@This() {
        var process = std.process.Child.init(&[_][]const u8{command}, alloc);
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Inherit;
        // process.stdout = std.io.getStdIn();
        try process.spawn();
        return .{
            .process = process,
        };
    }

    pub fn deinit(self: *@This()) !void {
        _ = try self.process.kill();
    }

    pub fn send(self: *@This(), cmd: UCI.UciCommand) !void {
        try cmd.writeTo(self.process.stdin.?.writer());
    }

    pub fn recieve(self: *@This()) !UCI.UciResult {
        var buf: [16384]u8 = undefined;
        var resultStream = std.io.fixedBufferStream(&buf);
        // Don't care about the max because fixedBufferStream will give a write error if it overflows.
        try self.process.stdout.?.reader().streamUntilDelimiter(resultStream.writer(), '\n', null);
        const msg = resultStream.getWritten();
        // print("[] {s}\n", .{msg});
        return try UCI.UciResult.parse(msg);
    }

    pub fn blockUntilRecieve(self: *@This(), expected: UCI.UciResult) void {
        // TODO: timeout detect to if it died
        while (true) {
            std.Thread.yield() catch continue;
            const msg = self.recieve() catch continue;
            if (std.meta.eql(msg, expected)) break;
        }
    }
};
