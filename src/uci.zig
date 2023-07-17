const std = @import("std");
const Board = @import("board.zig").Board;
const Move = @import("board.zig").Move;
const search = @import("search.zig").default;
const Timer = @import("bench.zig").Timer;
const GameOver = @import("board.zig").GameOver;

// TODO: split into uci.zig and fish.zig
// TODO: for just using support wasm32-wasi and wasm-freestanding (browser by exposing a uci_send(ptr, len) and uci_recieve(ptr, maxLen)->len function).
// TODO: threads!!! 8x speed = goooood times.

const fishTimeLimitMS = 1;
const maxMoves = 200;
const gameCount = 100;

pub fn main() !void {
    var fish = try Stockfish.init();
    try fish.send(.Init);
    fish.blockUntilRecieve(.InitOk);
    try fish.send(.{ .SetOption = .{ .name = "UCI_LimitStrength", .value = "true" } });
    try fish.send(.{ .SetOption = .{ .name = "UCI_Elo", .value = "1320" } });
    try fish.send(.{ .SetOption = .{ .name = "Skill Level", .value = "0" } });

    var gt = Timer.start();
    var failed: u32 = 0;
    var results = std.AutoHashMap(GameOver, u32).init(general.allocator());
    for (0..gameCount) |g| {
        if (g != 0) {
            for (std.enums.values(GameOver)) |key| {
                print("[info]: {} = {}.\n", .{ key, results.get(key) orelse 0 });
            }
            print("[info]: errors = {}.\n", .{failed});
            print("[info]: errors = {}.\n", .{failed});
        }

        const result = playOneGame(&fish, g, gameCount) catch |err| {
            failed += 1;
            print("[info]: Game failed! {}\n", .{err});
            search.resetMemoTable();
            continue;
        };
        search.resetMemoTable();
        const count = (results.get(result) orelse 0) + 1;
        try results.put(result, count);
    }

    for (std.enums.values(GameOver)) |key| {
        print("[info]: {} = {}.\n", .{ key, results.get(key) orelse 0 });
    }
    print("[info]: errors = {}.\n", .{failed});
    const time = gt.end();
    print("[info]: Done! Played {} games in {}ms.\n", .{ gameCount, time });
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
    var stats: Stats = .{};
    board.debugPrint();

    for (0..maxMoves) |i| {
        print("[info]: Move {}. Game {}/{}.\n", .{ i, gameIndex, gamesTotal });
        print("[info]: I'm thinking.\n", .{});
        var t = Timer.start();
        const move = search.bestMove(&board, board.nextPlayer, null) catch |err| {
            return try logGameOver(err, &board, &moveHistory, gt, &stats);
        };

        const moveStr = try writeAlgebraic(move);
        try moveHistory.append(moveStr);
        _ = board.play(move);
        print("[info]: I played {s} in {}ms.\n", .{ moveStr, t.end() });
        board.debugPrint();

        playUciMove(fish, &board, &moveHistory, &stats) catch |err| {
            return try logGameOver(err, &board, &moveHistory, gt, &stats);
        };
        board.debugPrint();
    } else {
        print("[info]: Played {} moves each. Stopping the game because nobody cares. \n", .{maxMoves});
        return error.GameTooLong;
    }
}

var buffer = std.io.bufferedWriter(std.io.getStdOut());
pub fn print(comptime fmt: []const u8, args: anytype) void {
    // buffer.writer().print(fmt, args) catch return;  // TODO: need to change debugPrint() to be buffered
    std.debug.print(fmt, args);
}

// https://gist.github.com/DOBRO/2592c6dad754ba67e6dcaec8c90165bf
// TODO: do I want to use the same names as the commands?
const UciCommand = union(enum) {
    Init,
    AreYouReady,
    NewGame,
    SetPositionInitial,
    SetPositionMoves: struct { board: *Board, moves: [][5]u8 }, // lifetime! don't save these pointers!
    Go: struct { maxSearchTimeMs: ?u64 = null, maxDepthPly: ?u64 = null },
    Stop,
    SetOption: struct { name: []const u8, value: []const u8 },
};

const UciInfo = struct {
    depth: ?u64 = null,
    seldepth: ?u64 = null,
    multipv: ?u64 = null,
    score_cp: ?i64 = null,
    nodes: ?u64 = null,
    nps: ?u64 = null,
    hashfull: ?u64 = null,
    tbhits: ?u64 = null,
    time: ?u64 = null,
    pv: ?[]const u8 = null, // algebraic notation moves seperated by spaces. Has the lifetime of the string it was parsed from!
    pvFirstMove: ?[5]u8 = null, // If you just want the first move, and not need to deal with lifetimes.
    mate: ?i64 = null,
    cp: ?i64 = null,
};

// TODO: packed struct for move strings
// const UciMove = packed struct {
//     fromFileChar: u8,
//     fromRankChar: u8,
//     toFileChar: u8,
//     toRankChar: u8,
//     promoteChar: u8,
// };

const UciResult = union(enum) {
    InitOk,
    ReadyOk,
    Info: UciInfo,
    BestMove: ?[5]u8,

    pub fn parse(str: []const u8) !UciResult {
        // TODO: this sucks
        if (std.mem.eql(u8, str, "uciok")) {
            return .InitOk;
        } else if (std.mem.eql(u8, str, "readyok")) {
            return .ReadyOk;
        } else if (std.mem.startsWith(u8, str, "info")) {
            var words = std.mem.splitScalar(u8, str, ' ');
            var result: UciInfo = .{};
            std.debug.assert(std.mem.eql(u8, words.next().?, "info"));
            while (true) {
                if (words.next()) |word| {
                    if (std.mem.eql(u8, word, "depth")) {
                        result.depth = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                    } else if (std.mem.eql(u8, word, "seldepth")) {
                        result.seldepth = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                    } else if (std.mem.eql(u8, word, "multipv")) {
                        result.multipv = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                    } else if (std.mem.eql(u8, word, "nps")) {
                        result.nps = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                    } else if (std.mem.eql(u8, word, "hashfull")) {
                        result.hashfull = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                    } else if (std.mem.eql(u8, word, "tbhits")) {
                        result.tbhits = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                    } else if (std.mem.eql(u8, word, "time")) {
                        result.time = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                    } else if (std.mem.eql(u8, word, "score")) {
                        const units = words.next() orelse break;
                        if (std.mem.eql(u8, units, "cp")) {
                            result.cp = std.fmt.parseInt(i64, words.next() orelse break, 10) catch continue;
                        } else if (std.mem.eql(u8, units, "mate")) {
                            result.mate = std.fmt.parseInt(i64, words.next() orelse break, 10) catch continue;
                        }
                    } else if (std.mem.eql(u8, word, "pv")) {
                        result.pv = str[words.index.?..str.len];
                        const first = words.next() orelse break;
                        if (first.len <= 5) {
                            result.pvFirstMove = std.mem.zeroes([5]u8);
                            @memcpy(result.pvFirstMove.?[0..first.len], first);
                        }
                        break;
                    }
                } else {
                    break;
                }
            }
            return .{ .Info = result };
        } else if (std.mem.startsWith(u8, str, "bestmove")) {
            var words = std.mem.splitScalar(u8, str, ' ');
            std.debug.assert(std.mem.eql(u8, words.next().?, "bestmove"));
            const first = words.next() orelse return error.UnknownUciStr;
            if (std.mem.eql(u8, first, "(none)")) {
                return .{ .BestMove = null };
            } else if (first.len <= 5) {
                var move = std.mem.zeroes([5]u8);
                @memcpy(move[0..first.len], first);
                // TODO: this is ignoring the ponder request.
                return .{ .BestMove = move };
            }
        }

        return error.UnknownUciStr;
    }
};

var general = (std.heap.GeneralPurposeAllocator(.{}){});

const Stats = struct {
    fishRandom: u64 = 0,
    fishOnTime: u64 = 0,
};

fn logGameOver(err: anyerror, board: *Board, moveHistory: *std.ArrayList([5]u8), gt: Timer, stats: *Stats) !GameOver {
    switch (err) {
        error.GameOver => {
            const result = try search.isGameOver(board, general.allocator());
            const msg = switch (result) {
                .Continue => "Game over but player can still move? This is a bug!",
                .Stalemate => "Draw (stalemate).",
                .FiftyMoveDraw => "Draw (50 move rule).",
                .WhiteWins => "White (luke) wins.",
                .BlackWins => "Black (fish) wins.",
            };
            const time = gt.end();
            print("[info]: {s} The game lasted {} ply ({} ms). \n", .{ msg, moveHistory.items.len, time });
            print("[info]: The fish played {}/{} moves randomly.\n", .{ stats.fishRandom, stats.fishOnTime + stats.fishRandom });
            return result;
        },
        else => return err,
    }
}

fn playUciMove(fish: *Stockfish, board: *Board, moveHistory: *std.ArrayList([5]u8), stats: *Stats) !void {
    if (board.halfMoveDraw >= 100) return error.GameOver; // Draw

    try fish.send(.AreYouReady);
    fish.blockUntilRecieve(.ReadyOk);
    if (moveHistory.items.len == 0) {
        try fish.send(.SetPositionInitial);
    } else {
        try fish.send(.{ .SetPositionMoves = .{ .board = board, .moves = moveHistory.items } });
    }
    try fish.send(.{ .Go = .{ .maxSearchTimeMs = fishTimeLimitMS } });

    const moveStr = m: {
        std.time.sleep(fishTimeLimitMS * std.time.ns_per_ms);
        try fish.send(.Stop);
        std.time.sleep(5 * std.time.ns_per_ms); // give it a moment to be able to stop

        var bestMove: ?[5]u8 = null;
        var moveTime: u64 = 0;
        while (true) {
            const infoMsg = try fish.recieve();
            switch (infoMsg) {
                .Info => |info| {
                    if (info.time) |time| {
                        if (time <= fishTimeLimitMS) {
                            if (info.pvFirstMove) |move| {
                                bestMove = move;
                                moveTime = time;
                            }
                        }
                    }
                },
                .BestMove => |bestmove| {
                    try fish.send(.AreYouReady);
                    fish.blockUntilRecieve(.ReadyOk);
                    if (bestmove) |move| {
                        if (bestMove == null) {
                            const randomMove = try search.randomMove(board, board.nextPlayer, general.allocator());
                            const moveStr = try writeAlgebraic(randomMove);
                            stats.fishRandom += 1;
                            print("[info]: The fish wanted to play {s} but it took too long so I randomly played {s} for it instead!\n", .{ move, moveStr });
                            break :m moveStr;
                        } else {
                            stats.fishOnTime += 1;
                            print("[info]: The fish played {s} in {}ms.\n", .{ move, moveTime });
                            break :m move;
                        }
                    } else {
                        print("[info]: The fish knows it has no moves!\n", .{});
                        return error.GameOver;
                    }
                },
                else => continue,
            }
        }
        unreachable;
    };

    const fromFile = try letterToFile(moveStr[0]);
    const fromRank = try letterToRank(moveStr[1]);
    const toFile = try letterToFile(moveStr[2]);
    const toRank = try letterToRank(moveStr[3]);
    const fromIndex = fromRank * 8 + fromFile;
    const toIndex = toRank * 8 + toFile;
    _ = try @import("board.zig").inferPlayMove(board, fromIndex, toIndex, general.allocator());
    try moveHistory.append(moveStr);
}

const Stockfish = struct {
    process: std.ChildProcess,

    pub fn init() !Stockfish {
        var stockFishProcess = std.ChildProcess.init(&[_][]const u8{"stockfish"}, general.allocator());
        stockFishProcess.stdin_behavior = .Pipe;
        stockFishProcess.stdout_behavior = .Pipe;
        stockFishProcess.stderr_behavior = .Pipe;
        stockFishProcess.stdout = std.io.getStdIn();
        // TODO: helpful error message if stockfish isnt installed.
        try stockFishProcess.spawn();
        return .{ .process = stockFishProcess };
    }

    pub fn deinit(self: *Stockfish) !void {
        _ = try self.process.kill();
    }

    pub fn send(self: *Stockfish, cmd: UciCommand) !void {
        try sendUci(self.process.stdin.?.writer(), cmd);
    }

    pub fn recieve(self: *Stockfish) !UciResult {
        return recieveUci(self.process.stdout.?.reader());
    }

    pub fn blockUntilRecieve(self: *Stockfish, expected: UciResult) void {
        blockUntilRecieveUci(self.process.stdout.?.reader(), expected);
    }
};

fn sendUci(out: anytype, cmd: UciCommand) !void {
    var letters = try std.BoundedArray(u8, 2048).init(0); // Don't want to deal with passing down an allocator.
    switch (cmd) {
        .Init => try letters.appendSlice("uci"),
        .AreYouReady => try letters.appendSlice("isready"),
        .NewGame => try letters.appendSlice("ucinewgame"),
        .SetPositionInitial => try letters.appendSlice("position startpos"),
        .Go => |args| {
            try letters.appendSlice("go");
            if (args.maxSearchTimeMs) |movetime| {
                try letters.appendSlice(" movetime ");
                letters.len += @intCast(std.fmt.formatIntBuf(letters.unusedCapacitySlice(), movetime, 10, .lower, .{}));
            }
            if (args.maxDepthPly) |depth| {
                try letters.appendSlice(" depth ");
                letters.len += @intCast(std.fmt.formatIntBuf(letters.unusedCapacitySlice(), depth, 10, .lower, .{}));
            }
        },
        .Stop => try letters.appendSlice("stop"),
        .SetPositionMoves => |state| {
            try letters.appendSlice("position fen ");
            try state.board.appendFEN(&letters);
            try letters.appendSlice(" moves");
            for (state.moves) |move| {
                try letters.append(' ');
                if (move[4] == 0) {
                    try letters.appendSlice(move[0..4]);
                } else {
                    try letters.appendSlice(move[0..]);
                }
            }
        },
        .SetOption => |option| {
            try letters.appendSlice("setoption name ");
            try letters.appendSlice(option.name);
            try letters.appendSlice(" value ");
            try letters.appendSlice(option.value);
        },
    }

    try letters.append('\n');
    print("[luke]: {s}", .{letters.slice()});
    // TODO: retry on error?
    return out.writeAll(letters.slice());
}

fn recieveUci(in: anytype) !UciResult {
    var buf: [1000]u8 = undefined;
    var resultStream = std.io.fixedBufferStream(&buf);
    // Don't care about the max because fixedBufferStream will give a write error if it overflows.
    try in.streamUntilDelimiter(resultStream.writer(), '\n', null);
    const msg = resultStream.getWritten();
    print("[fish]: {s}\n", .{msg});
    return try UciResult.parse(msg);
}

fn blockUntilRecieveUci(in: anytype, expected: UciResult) void {
    // TODO: timeout detect to if it died
    while (true) {
        const msg = recieveUci(in) catch continue;
        if (std.meta.eql(msg, expected)) break;
    }
}

// TODO: another thread to do work.
// TODO: search has global variables so this struct isn't thread safe.
const Engine = struct {
    board: Board,
    resultQueue: std.ArrayList(UciResult), // TODO: super slow! should be VecDeque!

    pub fn init(alloc: std.mem.Allocator) !Engine {
        return .{ .board = Board.initial(), .resultQueue = std.ArrayList(UciResult).init(alloc) };
    }

    pub fn deinit(self: *Engine) !void {
        self.moveHistory.deinit();
        self.resultQueue.deinit();
    }

    pub fn send(self: *Engine, cmd: UciCommand) !void {
        const result: UciResult = switch (cmd) {
            .Init => .InitOk,
            .AreYouReady => .ReadyOk,
            .NewGame | .SetPositionInitial => {
                self.board = Board.initial();
                return;
            },
            .Go => {
                try self.evaluate();
                return;
            },
            .Stop => {
                search.forceStop = true; // TODO this will change when threads
                return;
            },
        };
        try self.resultQueue.append(result);
    }

    // TODO: This is different behaviour from the stockfish one. This should let the engine keep making progress instead of returning an error.
    pub fn recieve(self: *Engine) !UciResult {
        if (self.resultQueue.items.len == 0) return error.NoUciResult;
        return self.resultQueue.orderedRemove(0); // TODO: SLOW
    }

    // TODO: this is a problem because it's single threaded.
    pub fn blockUntilRecieve(self: *Engine, expected: UciResult) void {
        while (true) {
            if (self.resultQueue.items.len == 0) std.debug.panic("Engine.blockUntilRecieve {} would hang.", .{expected});
            const msg = self.recieve() catch continue;
            if (std.meta.eql(msg, expected)) break;
        }
    }

    pub fn evaluate(self: *Engine) !void {
        const move = search.bestMove(&self.board, self.board.nextPlayer);
        std.debug.panic("TODO", .{});
        _ = move;
    }
};

fn writeAlgebraic(move: Move) ![5]u8 {
    var moveStr: [5]u8 = std.mem.zeroes([5]u8);
    const fromRank = @divFloor(move.from, 8);
    const fromFile = @mod(move.from, 8);
    const toRank = @divFloor(move.to, 8);
    const toFile = @mod(move.to, 8);
    moveStr[0] = try fileToLetter(fromFile);
    moveStr[1] = try rankToLetter(fromRank);
    moveStr[2] = try fileToLetter(toFile);
    moveStr[3] = try rankToLetter(toRank);

    switch (move.action) {
        .promote => |kind| {
            const char = @as(u8, switch (kind) {
                .Queen => 'q',
                .Knight => 'n',
                .Rook => 'r',
                .Bishop => 'b',
                else => unreachable,
            });
            moveStr[4] = char;
        },
        else => {},
    }

    return moveStr;
}

fn fileToLetter(file: u6) !u8 {
    if (file >= 8) return error.UnknownUciStr;
    return @as(u8, @intCast(file)) + 'a';
}

fn letterToFile(letter: u8) !u6 {
    if (letter < 'a' or letter > 'h') return error.UnknownUciStr;
    return @intCast(letter - 'a');
}

fn rankToLetter(rank: u6) !u8 {
    if (rank >= 8) return error.UnknownUciStr;
    return @as(u8, @intCast(rank)) + '1';
}

fn letterToRank(letter: u8) !u6 {
    if (letter < '1' or letter > '8') return error.UnknownUciStr;
    return @intCast(letter - '1');
}

// Two things: a binary that implements UCI and a binary that acts as the gui between two other UCI engines?
