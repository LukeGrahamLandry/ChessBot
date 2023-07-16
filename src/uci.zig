const std = @import("std");
const Board = @import("board.zig").Board;
const Move = @import("board.zig").Move;
const search = @import("search.zig").default;

// TODO: split into uci.zig and fish.zig 

// https://gist.github.com/DOBRO/2592c6dad754ba67e6dcaec8c90165bf
const UciCommand = union(enum) {
    Init,
    AreYouReady,
    NewGame,
    SetPositionInitial,
    SetPositionMoves: struct { board: *Board, moves: [] [5] u8},  // lifetime! don't save these pointers!
    Go,
    Stop,
};

const UciInfo = struct {
    depth: ?u64 = null,
    seldepth: ?u64 = null,
    multipv: ?u64 = null,
    score_cp: ?u64 = null,
    nodes: ?u64 = null,
    nps: ?u64 = null,
    hashfull: ?u64 = null,
    tbhits: ?u64 = null,
    time: ?u64 = null,
    pv: ?[] const u8 = null, // algebraic notation moves seperated by spaces. Has the lifetime of the string it was parsed from!
    pvFirstMove: ?[5] u8 = null,  // If you just want the first move, and not need to deal with lifetimes.
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
    BestMove: [5] u8,

    pub fn parse(str: [] const u8) !UciResult {
        // TODO: this sucks
        if (std.mem.eql(u8, str, "uciok")) {
            return .InitOk;
        }
        else if (std.mem.eql(u8, str, "readyok")) {
            return .ReadyOk;
        } 
        else if (std.mem.startsWith(u8, str, "info")) {
            var words = std.mem.splitScalar(u8, str, ' ');
            var result: UciInfo = .{};
            std.debug.assert(std.mem.eql(u8, words.next().?, "info"));
            while(true) {
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
                    } else if (std.mem.eql(u8, word, "pv")) {
                        result.pv = str[words.index.?..str.len];
                        const first = words.next() orelse break;
                        if (first.len <= 5) {
                            result.pvFirstMove = std.mem.zeroes([5] u8);
                            @memcpy(result.pvFirstMove.?[0..first.len], first);
                        }
                        break;
                    }
                } else {
                    break;
                }
            }
            return .{.Info=result};
        }
        else if (std.mem.startsWith(u8, str, "bestmove")) {
            var words = std.mem.splitScalar(u8, str, ' ');
            std.debug.assert(std.mem.eql(u8, words.next().?, "bestmove"));
            const first = words.next() orelse return error.UnknownUciStr;
            if (first.len <= 5) {
                var move = std.mem.zeroes([5] u8);
                @memcpy(move[0..first.len], first);
                // TODO: this is ignoring the ponder request.
                return .{.BestMove=move};
            }
        }

        return error.UnknownUciStr;
    }
};

var general = (std.heap.GeneralPurposeAllocator(.{}){});

pub fn main() !void {
    var alloc = general.allocator();
    var moveHistory = std.ArrayList([5] u8).init(alloc);
    var board = Board.initial();
    var fish = try Stockfish.init();
    
    try fish.send(.Init);
    fish.blockUntilRecieve(.InitOk);
    try fish.send(.NewGame);
    try fish.send(.AreYouReady);
    fish.blockUntilRecieve(.ReadyOk);

    board.debugPrint();

    while (true) {
        try playUciMove(&fish, &board, &moveHistory);
        board.debugPrint();

        const move = search.bestMove(&board, board.nextPlayer) catch |err| {
            switch (err) {
                error.GameOver => {
                    std.debug.print("Game Over!\n", .{});
                    break;
                },
                else => return err,
            }
        };

        try moveHistory.append(try writeAlgebraic(move));
        
        _ = board.play(move);
        board.debugPrint();
    }
    
    


    
    try fish.deinit();

    std.debug.print("[    ]: Done!\n", .{});
}

fn playUciMove(fish: *Stockfish, board: *Board, moveHistory: *std.ArrayList([5] u8)) !void {
    if (moveHistory.items.len == 0) {
        try fish.send(.SetPositionInitial);
    } else {
        try fish.send(.{.SetPositionMoves=.{ .board=board, .moves=moveHistory.items }});
    }
    try fish.send(.Go);
    const moveStr = try getBestMove(fish, 10);
    std.debug.print("move: {?s}\n", .{moveStr});
    const fromFile = try letterToFile(moveStr[0]);
    const fromRank = try letterToRank(moveStr[1]);
    const toFile = try letterToFile(moveStr[2]);
    const toRank = try letterToRank(moveStr[3]);
    const fromIndex = fromRank*8 + fromFile;
    const toIndex = toRank*8 + toFile;
    _ = try @import("board.zig").inferPlayMove(board, fromIndex, toIndex, general.allocator());
    try moveHistory.append(moveStr);
}

fn getBestMove(fish: *Stockfish, timeLimitMS: u64) ![5] u8 {
    std.time.sleep(timeLimitMS * std.time.ns_per_ms);
    try fish.send(.Stop);
    std.time.sleep(2 * std.time.ns_per_ms);  // give it a moment to be able to stop
    try fish.send(.AreYouReady);

    // Find the move it recommends after 2ms. 
    var bestMove: ?[5] u8 = null;
    while (true) {
        const infoMsg = try fish.recieve();
        switch (infoMsg) {
            .Info => |info| {
                if (info.time) |time|{
                    if (time > timeLimitMS) break;
                }
                if (info.pvFirstMove) |move| {
                    bestMove = move;
                }
            },
            else => continue,
        }
    }
    fish.blockUntilRecieve(.ReadyOk);
    if (bestMove) |move| {
        return move;
    } else {
        return error.NoMoveFound;
    }
}

const Stockfish = struct {
    process: std.ChildProcess,

    pub fn init() !Stockfish {
        var stockFishProcess = std.ChildProcess.init(&[_] [] const u8 {"stockfish"}, general.allocator());
        stockFishProcess.stdin_behavior = .Pipe;
        stockFishProcess.stdout_behavior = .Pipe;
        stockFishProcess.stderr_behavior = .Pipe;
        stockFishProcess.stdout = std.io.getStdIn();
        // TODO: helpful error message if stockfish isnt installed. 
        try stockFishProcess.spawn();
        return .{ .process=stockFishProcess };
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
    var buf: [1000]u8 = undefined;
    _ = buf;
    const msg = switch (cmd) {
        .Init => "uci\n",
        .AreYouReady => "isready\n",
        .NewGame => "ucinewgame\n",
        .SetPositionInitial => "position startpos\n",
        .Go => "go\n",
        .Stop => "stop\n",
        .SetPositionMoves => |state| {
            var letters = std.ArrayList(u8).init(general.allocator());
            try letters.appendSlice("position fen ");  // TODO
            try state.board.appendFEN(&letters);
            try letters.appendSlice(" moves ");
            for (state.moves) |move| {
                if (move[4] == 0) {
                    try letters.appendSlice(move[0..4]);
                } else {
                    try letters.appendSlice(move[0..]);
                }
                try letters.append(' ');
            }
            try letters.append('\n');
            std.debug.print("[luke]: {s}", .{letters.items});
            return out.writeAll(letters.items);
        }
    };

    std.debug.print("[luke]: {s}", .{msg});
    // TODO: retry on error?
    return out.writeAll(msg);
}

fn recieveUci(in: anytype) !UciResult {
    var buf: [1000]u8 = undefined;
    var resultStream = std.io.fixedBufferStream(&buf);
    // Don't care about the max because fixedBufferStream will give a write error if it overflows.
    try in.streamUntilDelimiter(resultStream.writer(), '\n', null);
    const msg = resultStream.getWritten();
    std.debug.print("[fish]: {s}\n", .{msg});
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
    resultQueue: std.ArrayList(UciResult),  // TODO: super slow! should be VecDeque!

    pub fn init(alloc: std.mem.Allocator) !Engine {
        return .{ 
            .board=Board.initial(), 
            .resultQueue=std.ArrayList(UciResult).init(alloc)
        };
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
                search.forceStop = true;  // TODO this will change when threads
                return;
            },
        };
        try self.resultQueue.append(result);
    }

    // TODO: This is different behaviour from the stockfish one. This should let the engine keep making progress instead of returning an error. 
    pub fn recieve(self: *Engine) !UciResult {
        if (self.resultQueue.items.len == 0) return error.NoUciResult;
        return self.resultQueue.orderedRemove(0);  // TODO: SLOW
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

fn writeAlgebraic(move: Move) ![5] u8 {
    var moveStr: [5] u8 = std.mem.zeroes([5] u8);
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
            _ = kind;
            std.debug.panic("TODO", .{});
        },
        else => {}
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
    if (letter < '1' or letter > '7') return error.UnknownUciStr;
    return @intCast(letter - '1');
}

// Two things: a binary that implements UCI and a binary that acts as the gui between two other UCI engines? 
