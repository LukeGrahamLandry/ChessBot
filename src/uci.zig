//! Implements the universal chess interface: https://gist.github.com/DOBRO/2592c6dad754ba67e6dcaec8c90165bf
//! Utils for representing games as strings: FEN parsing, algebraic notation, etc.

const std = @import("std");
const Board = @import("board.zig").Board;
const Piece = @import("board.zig").Piece;
const Move = @import("board.zig").Move;
const search = @import("search.zig");
const Timer = @import("common.zig").Timer;
const GameOver = @import("board.zig").GameOver;
const OldMove = @import("board.zig").OldMove;
const inferPlayMove = @import("board.zig").inferPlayMove;
const Learned = @import("learned.zig");
const assert = @import("common.zig").assert;
const panic = @import("common.zig").panic;
const ListPool = @import("movegen.zig").ListPool;
const book = @import("book.zig");

// Should book.chess be included in the binary? Run book.zig first to generate it.
const INCLUDE_BOOK = false;
var openings: std.AutoHashMap(u64, Move) = undefined;

pub fn main() !void {
    var e: Engine = .{};
    try e.init();
    var forever = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var lists = try ListPool.init(forever.allocator());
    if (INCLUDE_BOOK) {
        const bookData = @embedFile("book.chess");
        openings = try book.deserializeBook(book.bytesToU64Slice(bookData[0..]), forever.allocator());
    }
    
    while (true) {
        const cmd = waitForUciCommand(std.io.getStdIn().reader(), e.arena.allocator(), &lists) catch |err| {
            std.debug.print("[uci] {}\n", .{err});
            if (err == error.EndOfStream) break;
            // be a slightly less hyper agressive spin loop
            std.time.sleep(5 * std.time.ns_per_ms);
            continue;
        };
        try e.handle(cmd);
    }
}

const Engine = struct {
    arena: std.heap.ArenaAllocator = undefined,
    worker: Worker = undefined,

    pub fn init(self: *Engine) !void {
        self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        self.worker = .{
            .ctx = @import("common.zig").setup(1500),
            .board = try Board.initial(),
            .thread = try std.Thread.spawn(.{}, engineWorker, .{&self.worker}),
        };
    }

    pub fn handle(self: *Engine, cmd: UciCommand) !void {
        switch (cmd) {
            .Init => {
                const result: UciResult = .InitOk;
                try result.writeTo(std.io.getStdOut().writer());
            },
            .AreYouReady => {
                const result: UciResult = .ReadyOk;
                try result.writeTo(std.io.getStdOut().writer());
            },
            .NewGame => {
                self.worker.isIdle.wait();
                self.worker.ctx.resetMemoTable();
                self.worker.board = try Board.initial();
            },
            .SetPositionInitial => {
                self.worker.isIdle.wait();
                self.worker.board = try Board.initial();
            },
            .SetPositionMoves => |info| {
                self.worker.isIdle.wait();
                self.worker.board = info.board.*;
            },
            .Go => |info| {
                self.worker.isIdle.wait();
                if (info.perft) |_| {
                    panic("TODO: impl uci perft. \n{}\n", .{cmd});
                }

                self.worker.maxDepth = info.maxDepthPly orelse 50;
                self.worker.timeLimitMs = info.maxSearchTimeMs orelse std.math.maxInt(u32);

                // TODO: deal with lichess py script giving 10s for first move (matters when my book is disabled)
                // TODO: think more about what's a good time management strategy
                // TODO: ponder (think on opponent's turn about predicted move)
                const inc = if (self.worker.board.nextPlayer == .White) info.winc else info.binc;
                const time = if (self.worker.board.nextPlayer == .White) info.wtime else info.btime;
                const hasTimeControl = inc != null or time != null;
                if (hasTimeControl) {
                    const lowTime = inc != null and time != null and inc.? > 500 and time.? < 5000;
                    const thismove = if (lowTime) inc.? * 9 / 10 else ((inc orelse 1000) + ((time orelse 0) / 100));
                    self.worker.timeLimitMs = @min(thismove, self.worker.timeLimitMs);
                } 
                
                self.worker.isIdle.reset();
                self.worker.hasWork.set();
            },
            .Stop => {
                self.worker.ctx.forceStop = true;
                self.worker.isIdle.wait();
                self.worker.ctx.forceStop = false;
            },
            .Quit => {
                self.worker.ctx.forceStop = true;
                std.os.exit(0);
            },
            else => panic("TODO: other uci commands {}", .{cmd}),
        }

        _ = self.arena.reset(.retain_capacity);
    }
};

fn engineWorker(self: *Worker) !void {
    const opts: search.StratOpts = .{ .printUci = true };
    std.time.sleep(std.time.ns_per_ms * 5);
    self.isIdle.set();
    while (true) {
        self.hasWork.wait();
        self.hasWork.reset();
        self.isIdle.reset();

        if (INCLUDE_BOOK and self.board.fullMoves <= book.FULL_MOVE_DEPTH) {
            if (openings.get(self.board.zoidberg)) |move| {
                const info: UciInfo = .{ .time = 1, .depth = 1, .pvFirstMove = writeAlgebraic(move) };
                const result: UciResult = .{ .Info = info };
                const bestmove: UciResult = .{ .BestMove = writeAlgebraic(move) };
                try result.writeTo(std.io.getStdOut().writer());
                try bestmove.writeTo(std.io.getStdOut().writer());

                self.isIdle.set();
                continue;
            }
        }

        // This knows to print uci stuff to stdout.
        _ = try search.bestMove(opts, &self.ctx, &self.board, self.maxDepth - 1, self.timeLimitMs);
        self.isIdle.set();
    }
}

fn waitForUciCommand(reader: anytype, alloc: std.mem.Allocator, lists: *ListPool) !UciCommand {
    var buf: [16384]u8 = undefined;
    var resultStream = std.io.fixedBufferStream(&buf);
    // Don't care about the max because fixedBufferStream will give a write error if it overflows.
    try reader.streamUntilDelimiter(resultStream.writer(), '\n', null);
    const msg = resultStream.getWritten();
    // std.debug.print("[uci]: {s}\n", .{msg});
    return try UciCommand.parse(msg, alloc, lists);
}

const Worker = struct {
    thread: std.Thread,
    ctx: search.SearchGlobals,
    board: Board,
    hasWork: std.Thread.ResetEvent = .{},
    isIdle: std.Thread.ResetEvent = .{},

    // These are set by the 'go' command.
    maxDepth: usize = 0,
    timeLimitMs: i128 = 0,
};

const GoCmd = struct {
    maxSearchTimeMs: ?u64 = null,
    maxDepthPly: ?u64 = null,
    perft: ?u64 = null,
    winc: ?u64 = null,
    binc: ?u64 = null,
    wtime: ?u64 = null,
    btime: ?u64 = null,
};

// TODO: do I want to use the same names as the commands?
/// A command from a gui to an engine.
pub const UciCommand = union(enum) {
    Init,
    AreYouReady,
    NewGame,
    SetPositionInitial,
    SetPositionMoves: struct { board: *Board }, // lifetime! don't save these pointers!
    Go: GoCmd,
    Stop,
    Quit,
    SetOption: struct { name: []const u8, value: []const u8 },

    pub fn writeTo(cmd: UciCommand, writer: anytype) !void {
        var buffer = std.io.bufferedWriter(writer);
        var out = buffer.writer();
        switch (cmd) {
            .Init => try out.writeAll("uci"),
            .AreYouReady => try out.writeAll("isready"),
            .NewGame => try out.writeAll("ucinewgame"),
            .Quit => try out.writeAll("ucinewgame"),
            .SetPositionInitial => try out.writeAll("position startpos"),
            .Go => |args| {
                try out.writeAll("go");
                if (args.perft) |perft| {
                    try out.print(" perft {}", .{perft});
                }
                if (args.maxSearchTimeMs) |movetime| {
                    try out.print(" movetime {}", .{movetime});
                }
                if (args.maxDepthPly) |depth| {
                    try out.print(" depth {}", .{depth});
                }
            },
            .Stop => try out.writeAll("stop"),
            .SetPositionMoves => |state| {
                try out.writeAll("position fen ");
                try writeFen(state.board, out);
            },
            .SetOption => |option| {
                try out.print("setoption name {s} value {s}", .{ option.name, option.value });
            },
        }

        try out.writeByte('\n');
        try buffer.flush();
    }

    // SetPositionMoves allocates the board pointer, caller owns it now.
    pub fn parse(str: []const u8, alloc: std.mem.Allocator, lists: *ListPool) !UciCommand {
        // TODO: this sucks. some crazy comptime perfect hash thing?
        if (std.mem.eql(u8, str, "uci")) {
            return .Init;
        } else if (std.mem.eql(u8, str, "isready")) {
            return .AreYouReady;
        } else if (std.mem.eql(u8, str, "ucinewgame")) {
            return .NewGame;
        } else if (std.mem.eql(u8, str, "stop")) {
            return .Stop;
        } else if (std.mem.eql(u8, str, "quit")) {
            return .Quit;
        } else if (std.mem.eql(u8, str, "position startpos")) {
            return .SetPositionInitial;
        } else if (std.mem.startsWith(u8, str, "position fen ")) {
            if (std.mem.indexOf(u8, str, "moves") != null){
                panic("TODO: support moves after fen starting position. currently only supports startpos.", .{});
            }

            const startingWithFen = str[13..];
            var board = try alloc.create(Board);
            board.* = try Board.fromFEN(startingWithFen);
            return .{ .SetPositionMoves = .{ .board = board } };
        } else if (std.mem.startsWith(u8, str, "position startpos moves ")) {
            var words = std.mem.splitScalar(u8, str, ' ');
            assert(std.mem.eql(u8, words.next().?, "position"));
            assert(std.mem.eql(u8, words.next().?, "startpos"));
            assert(std.mem.eql(u8, words.next().?, "moves"));
            var board = try alloc.create(Board);
            board.* = try Board.initial();
            while (words.next()) |word| {
                if (word.len <= 5) {
                    var moveStr = std.mem.zeroes([5]u8);
                    @memcpy(moveStr[0..word.len], word);
                    _ = try playAlgebraic(board, moveStr, lists);
                }
            }
            return .{ .SetPositionMoves = .{ .board = board } };
        } else if (std.mem.startsWith(u8, str, "go")) {
            var result: GoCmd = .{};
            var words = std.mem.splitScalar(u8, str, ' ');
            std.debug.assert(std.mem.eql(u8, words.next().?, "go"));
            while (words.next()) |word| {
                if (std.mem.eql(u8, word, "movetime")) {
                    result.maxSearchTimeMs = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                } else if (std.mem.eql(u8, word, "depth")) {
                    result.maxDepthPly = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                } else if (std.mem.eql(u8, word, "perft")) {
                    result.perft = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                } else if (std.mem.eql(u8, word, "winc")) {
                    result.winc = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                } else if (std.mem.eql(u8, word, "binc")) {
                    result.binc = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                } else if (std.mem.eql(u8, word, "wtime")) {
                    result.wtime = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                } else if (std.mem.eql(u8, word, "btime")) {
                    result.btime = std.fmt.parseInt(u64, words.next() orelse break, 10) catch continue;
                }
            }
            return .{ .Go = result };
        }

        // TODO: the rest
        return error.UnknownUciStr;
    }
};

pub const UciInfo = struct {
    depth: ?u64 = null,
    seldepth: ?u64 = null,
    multipv: ?u64 = null,
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

pub const PerftNode = struct { move: [5]u8, count: u64 };

// A response from an engine to a gui.
pub const UciResult = union(enum) {
    InitOk,
    ReadyOk,
    Info: UciInfo,
    BestMove: ?[5]u8,
    PerftDivide: PerftNode,
    PerftDone: struct { total: u64 },

    pub fn parse(str: []const u8) !UciResult {
        // TODO: this sucks. some crazy comptime perfect hash thing?
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
                return .{ .BestMove = move };
            }
        } else if ((str.len > 4 and str[4] == ':') or (str.len > 5 and str[5] == ':')) { // perft
            var words = std.mem.splitSequence(u8, str, ": ");
            // TODO: handle errors
            const move = words.next().?;
            var result: [5]u8 = std.mem.zeroes([5]u8);
            if (move.len <= 5) {
                @memcpy(result[0..move.len], move);
            } else {
                return error.UnknownUciStr;
            }
            const count = std.fmt.parseInt(u64, words.next() orelse return error.UnknownUciStr, 10) catch return error.UnknownUciStr;
            return .{ .PerftDivide = .{ .move = result, .count = count } };
        } else if (std.mem.startsWith(u8, str, "Nodes searched:")) {
            var words = std.mem.splitSequence(u8, str, ": ");
            _ = words.next().?;
            const count = std.fmt.parseInt(u64, words.next() orelse return error.UnknownUciStr, 10) catch return error.UnknownUciStr;
            return .{ .PerftDone = .{ .total = count } };
        }

        // std.debug.print("UnknownUciStr: {s}\n", .{str});
        return error.UnknownUciStr;
    }

    pub fn writeTo(cmd: UciResult, writer: anytype) !void {
        var buffer = std.io.bufferedWriter(writer);
        var out = buffer.writer();
        switch (cmd) {
            .InitOk => try out.writeAll("uciok"),
            .ReadyOk => try out.writeAll("readyok"),
            .BestMove => |maybeMove| {
                try out.writeAll("bestmove ");
                if (maybeMove) |move| {
                    try out.writeAll(move[0..4]);
                    if (move[4] != 0) {
                        try out.writeByte(move[4]);
                    } else {
                        try out.writeByte(' ');
                    }
                } else {
                    try out.writeAll("(none)");
                }
            },
            .Info => |info| {
                try out.writeAll("info");
                if (info.time) |time| {
                    try out.print(" time {}", .{time});
                }
                if (info.depth) |depth| {
                    try out.print(" depth {}", .{depth});
                }
                if (info.cp) |cp| {
                    try out.print(" score cp {}", .{cp});
                }
                if (info.pv) |pv| {
                    try out.writeAll(" pv ");
                    try out.writeAll(pv);
                } else {
                    // My search isnt tracking pvs rn but it can give the best move at each level.
                    if (info.pvFirstMove) |move| {
                        try out.writeAll(" pv ");
                        try out.writeAll(move[0..4]);
                        if (move[4] != 0) {
                            try out.writeByte(move[4]);
                        } else {
                            try out.writeByte(' ');
                        }
                    }
                }
                // TODO: the rest.
            },
            else => panic("TODO: writeTo() for {}\n", .{cmd}),
        }

        try out.writeByte('\n');
        try buffer.flush();
    }
};

const InvalidFenErr = error{InvalidFen};
pub fn parseFen(fen: []const u8) error{InvalidFen}!Board {
    var self = Board.blank();

    var parts = std.mem.splitScalar(u8, fen, ' ');
    if (parts.next()) |pieces| {
        var file: u8 = 0;
        var rank: u8 = 7;
        var i: usize = 0;
        for (pieces) |letter| {
            defer i += 1;
            if (letter == ' ') break;

            if (std.ascii.isDigit(letter)) {
                const count = letter - '0';
                file += count;
            } else if (letter == '/') {
                if (file != 8) return error.InvalidFen;
                file = 0;
                if (rank == 0) return error.InvalidFen; // This assumes no trailing '/'
                rank -= 1;
            } else {
                self.set(file, rank, try Piece.fromChar(letter));
                file += 1;
                if (rank > 8) return error.InvalidFen;
            }
        }
        if (file != 8) return error.InvalidFen;
    } else {
        return error.InvalidFen;
    }

    if (parts.next()) |player| {
        if (player.len != 1) return error.InvalidFen;
        switch (player[0]) {
            'w' => self.nextPlayer = .White,
            'b' => self.nextPlayer = .Black,
            else => return error.InvalidFen,
        }
    } else {
        return error.InvalidFen;
    }

    // These fields are less important so are optional.

    self.castling = @bitCast(@as(u8, 0));
    if (parts.next()) |castling| {
        if (castling.len == 1 and castling[0] == '-') {
            // Nobody can castle
        } else if (castling.len <= 4) {
            for (castling) |c| {
                switch (c) {
                    'K' => self.castling.whiteRight = true,
                    'Q' => self.castling.whiteLeft = true,
                    'k' => self.castling.blackRight = true,
                    'q' => self.castling.blackLeft = true,
                    else => return error.InvalidFen,
                }
            }
        } else {
            return error.InvalidFen;
        }
    }

    if (parts.next()) |frenchMove| {
        switch (frenchMove.len) {
            1 => if (frenchMove[0] != '-') return error.InvalidFen, // No french move is possible.
            2 => {
                // The target must be on the right rank given the player that just moved.
                switch (self.nextPlayer) {
                    .White => if (frenchMove[1] != '6') return error.InvalidFen,
                    .Black => if (frenchMove[1] != '3') return error.InvalidFen,
                }
                const file = letterToFile(frenchMove[0]) catch return error.InvalidFen;
                self.frenchMove = .{ .file = @intCast(file) };
            },
            else => return error.InvalidFen,
        }
    }

    if (parts.next()) |halfMoves| {
        self.halfMoveDraw = std.fmt.parseInt(u32, halfMoves, 10) catch return error.InvalidFen;
    }

    if (parts.next()) |fullMoves| {
        self.fullMoves = std.fmt.parseInt(u32, fullMoves, 10) catch return error.InvalidFen;
    }

    return self;
}

pub fn writeFen(self: *const Board, writer: anytype) !void {
    var buffer = std.io.bufferedWriter(writer);
    var out = buffer.writer();

    for (0..8) |rank| {
        var empty: u8 = 0;
        for (0..8) |file| {
            const p = self.get(file, 7 - rank);
            if (p.empty()) {
                empty += 1;
                continue;
            }
            if (empty > 0) {
                try out.writeByte('0' + empty);
                empty = 0;
            }
            try out.writeByte(p.toChar());
        }
        if (empty > 0) {
            try out.writeByte('0' + empty);
        }
        if (rank < 7) {
            try out.writeByte('/');
        }
    }

    const playerChar: u8 = if (self.nextPlayer == .White) 'w' else 'b';
    try out.print(" {c} ", .{playerChar});

    if (self.castling.whiteRight) try out.writeByte('K');
    if (self.castling.whiteLeft) try out.writeByte('Q');
    if (self.castling.blackRight) try out.writeByte('k');
    if (self.castling.blackLeft) try out.writeByte('q');
    if (!self.castling.any()) try out.writeByte('-');

    switch (self.frenchMove) {
        .none => try out.writeAll(" - "),
        .file => |file| {
            const fileChar = fileToLetter(@intCast(file)) catch unreachable;
            const rankChar: u8 = if (self.nextPlayer == .White) '6' else '3';
            try out.print(" {c}{c} ", .{ fileChar, rankChar });
        },
    }

    try out.print("{} {}", .{ self.halfMoveDraw, self.fullMoves });
    try buffer.flush();
}

pub fn playAlgebraic(board: *Board, moveStr: [5]u8, lists: *ListPool) !OldMove {
    const fromFile = try letterToFile(moveStr[0]);
    const fromRank = try letterToRank(moveStr[1]);
    const toFile = try letterToFile(moveStr[2]);
    const toRank = try letterToRank(moveStr[3]);
    const fromIndex = fromRank * 8 + fromFile;
    const toIndex = toRank * 8 + toFile;
    const promote = if (moveStr[4] != 0) (try Piece.fromChar(moveStr[4])).kind else null;
    return try inferPlayMove(board, fromIndex, toIndex, lists, promote);
}

pub fn writeAlgebraic(move: Move) [5]u8 {
    var moveStr: [5]u8 = std.mem.zeroes([5]u8);
    const fromRank = @divFloor(move.from, 8);
    const fromFile = @mod(move.from, 8);
    const toRank = @divFloor(move.to, 8);
    const toFile = @mod(move.to, 8);

    // These return error on bounds check but Move from/to will always be within u6.
    moveStr[0] = fileToLetter(fromFile) catch unreachable;
    moveStr[1] = rankToLetter(fromRank) catch unreachable;
    moveStr[2] = fileToLetter(toFile) catch unreachable;
    moveStr[3] = rankToLetter(toRank) catch unreachable;

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

pub fn fileToLetter(file: u6) !u8 {
    if (file >= 8) return error.UnknownUciStr;
    return @as(u8, @intCast(file)) + 'a';
}

pub fn letterToFile(letter: u8) !u6 {
    if (letter < 'a' or letter > 'h') return error.UnknownUciStr;
    return @intCast(letter - 'a');
}

pub fn rankToLetter(rank: u6) !u8 {
    if (rank >= 8) return error.UnknownUciStr;
    return @as(u8, @intCast(rank)) + '1';
}

pub fn letterToRank(letter: u8) !u6 {
    if (letter < '1' or letter > '8') return error.UnknownUciStr;
    return @intCast(letter - '1');
}
