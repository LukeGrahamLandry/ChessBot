//! Parse pgn files to generate an opening book.

const std = @import("std");
const Move = @import("board.zig").Move;
const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Kind = @import("board.zig").Kind;
const UCI = @import("uci.zig");
const movegen = @import("movegen.zig");
const assert = std.debug.assert;

const PGN_PATH = "zig-out/lichess_db_standard_rated_2016-04.pgn";
pub const FULL_MOVE_DEPTH = 15;
const MIN_ELO = 2000;
const MIN_OCCURANCES = 1;

// c_allocator is 8x as fast as GeneralPurposeAllocator! (raw_c_allocator is the same)
pub fn main() !void {
    const t = @import("common.zig").Timer.start();
    assert(@sizeOf(Move) == 8);
    var ctx = @import("common.zig").setup(0);
    // zig-out is just a good place to put stuff that's git ignored
    const file = std.fs.cwd().openFile(PGN_PATH, .{}) catch {
        std.debug.print("Failed to open {s} \nDownload it from https://database.lichess.org\n", .{PGN_PATH});
        return;
    };
    const buffered: Reader = .{ .unbuffered_reader = file.reader() };

    std.debug.print("\nStart building book.\n", .{});
    var pgn: PngReader = .{ .reader = buffered };
    try pgn.findNextInterestingGame();

    // TODO: context that just uses the number as the hash instead of dumbly doing generic hash to my zobrhist key
    //       but it doesnt matter because memory is the slow part. 
    var seen = std.AutoHashMap(u64, PosInfo).init(std.heap.c_allocator);

    var gameCount: usize = 0;
    while (true) {
        const move = (pgn.getMove(&ctx.lists) catch |err| {
            if (err == error.GameOver) {
                pgn.findNextInterestingGame() catch |errr| if (errr == error.EndOfStream) break;
                gameCount += 1;
                if (gameCount % 1000 == 0) std.debug.print("{}\n", .{gameCount});
                continue;
            }
            if (err == error.EndOfStream) {
                break;
            }
            return err;
        }) orelse {
            pgn.findNextInterestingGame() catch |err| if (err == error.EndOfStream) break;
            gameCount += 1;
            continue;
        };
        if (seen.getPtr(pgn.board.zoidberg)) |info| {
            if (info.moveCount.getPtr(move)) |count| {
                count.* += 1;
            } else {
                try info.moveCount.put(move, 1);
            }
        } else {
            var info: PosInfo = .{ .hash = pgn.board.zoidberg, .moveCount = std.AutoHashMap(Move, u64).init(std.heap.c_allocator) };
            try info.moveCount.put(move, 1);
            try seen.put(pgn.board.zoidberg, info);
        }
        if (pgn.moveIndex > (FULL_MOVE_DEPTH * 2)) {
            pgn.next() catch |err| if (err == error.EndOfStream) break;
            pgn.findNextInterestingGame() catch |err| if (err == error.EndOfStream) break;
            gameCount += 1;
            if (gameCount % 1000 == 0) std.debug.print("{}\n", .{gameCount});
            continue;
        }
        _ = pgn.board.play(move);
    }

    // TODO: would be interesting to compare this to what the weight tables would have done. 
    var book = std.AutoHashMap(u64, Move).init(std.heap.c_allocator);

    var positions = seen.iterator();
    while (positions.next()) |pos| {
        var count: usize = 0;
        var bestCount: usize = 0;
        var bestMove: Move = undefined;
        var moves = pos.value_ptr.moveCount.iterator();
        while (moves.next()) |move| {
            count += move.value_ptr.*;
            if (move.value_ptr.* > bestCount) {
                bestMove = move.key_ptr.*;
                bestCount = move.value_ptr.*;
            }
        }
        if (count > MIN_OCCURANCES) {
            try book.put(pos.key_ptr.*, bestMove);
        }
    }

    std.debug.print("Positions in book: {}\n", .{book.count()});
    std.debug.print("Size: {} KB\n", .{book.capacity() * @sizeOf(@TypeOf(book).KV) / 1024});
    std.debug.print("Built book in {}ms.\n", .{t.get()});

    const data = try serializeBook(book, std.heap.c_allocator);
    const bookAgain = try deserializeBook(data, std.heap.c_allocator);
    try checkBookEql(book, bookAgain);

    try writeBookToFile(book, "src/book.chess", std.heap.c_allocator);
    const bookFromFile = try loadBookFromFile("src/book.chess", std.heap.c_allocator);
    try checkBookEql(book, bookFromFile);

    std.debug.print("It worked!\n", .{});
}

fn checkBookEql(a: std.AutoHashMap(u64, Move), b: std.AutoHashMap(u64, Move)) !void {
    try std.testing.expectEqual(a.count(), b.count());
    var iter = a.iterator();
    while (iter.next()) |expected| {
        if (b.get(expected.key_ptr.*)) |found| {
            try std.testing.expectEqual(found, expected.value_ptr.*);
        } else {
            std.debug.panic("Didn't find {}\n", .{expected.key_ptr.*});
        }
    }
}

// Caller owns the returned memory
pub fn loadBookFromFile(path: []const u8, alloc: std.mem.Allocator) !std.AutoHashMap(u64, Move) {
    const size = (try std.fs.cwd().statFile(path)).size;
    var buffer = try alloc.alloc(u8, size);
    defer alloc.free(buffer);
    assert(size % 16 == 0);
    var fileBytes = try std.fs.cwd().readFile(path, buffer);
    return try deserializeBook(bytesToU64Slice(fileBytes), alloc);
}

pub fn bytesToU64Slice(bytes: []const u8) []const u64 {
    var data: []u64 = undefined;
    data.ptr = @constCast(@ptrCast(@alignCast(bytes.ptr)));
    data.len = bytes.len / 8;
    return data;
}

// Caller still owns the original book
pub fn writeBookToFile(book: std.AutoHashMap(u64, Move), path: []const u8, alloc: std.mem.Allocator) !void {
    var data = try serializeBook(book, alloc);
    defer alloc.free(data);
    var bytes: []u8 = undefined;
    bytes.len = data.len * 8;
    bytes.ptr = @as([*]u8, @constCast(@ptrCast(data.ptr))); // TODO: why does this need const cast

    const dataFile = try std.fs.cwd().createFile(path, .{});
    try dataFile.writer().writeAll(bytes);
    dataFile.close();
}

// Caller owns the returned memory and still owns the original book
fn serializeBook(book: std.AutoHashMap(u64, Move), alloc: std.mem.Allocator) ![]const u64 {
    var data = try std.ArrayList(u64).initCapacity(alloc, book.count() * 2);
    var bookIter = book.iterator();
    while (bookIter.next()) |entry| {
        try data.append(entry.key_ptr.*);
        const value: u64 = @as(*u64, @ptrCast(@alignCast(entry.value_ptr))).*;
        try data.append(value);
    }
    return try data.toOwnedSlice();
}

// Caller owns the returned memory
pub fn deserializeBook(data: []const u64, alloc: std.mem.Allocator) !std.AutoHashMap(u64, Move) {
    var book = std.AutoHashMap(u64, Move).init(alloc);
    try book.ensureTotalCapacity(@intCast(data.len / 2));
    assert(data.len % 2 == 0);
    var i: usize = 0;
    while (i < data.len) {
        const key = data[i];
        const value: Move = @as(*const Move, @ptrCast((&data[i + 1]))).*;
        try book.put(key, value);
        i += 2;
    }
    std.debug.print("Loaded book. {} words. Count={}.\n", .{ data.len, book.count() });
    return book;
}

const Reader = std.io.BufferedReader(1024 * 1024, std.fs.File.Reader);

const PngReader = struct {
    buf: [16384]u8 = undefined,
    line: []const u8 = "",
    reader: Reader,
    emptyLineCount: u64 = 0,
    moveIndex: usize = 0,
    moves: ?std.mem.SplitIterator(u8, .scalar) = null,
    nextMovePart: ?[]const u8 = null,
    board: Board = undefined,

    fn next(self: *@This()) !void {
        var resultStream = std.io.fixedBufferStream(&self.buf);
        try self.reader.reader().streamUntilDelimiter(resultStream.writer(), '\n', null);
        self.line = resultStream.getWritten();
        if (self.line.len == 0) {
            self.emptyLineCount += 1;
            try self.next();
        }
    }

    fn findNextInterestingGame(self: *@This()) !void {
        try self.next();
        while (self.lookingAtInfo()) {
            const key = try self.infoKey();
            const isElo = std.mem.eql(u8, key, "WhiteElo") or std.mem.eql(u8, key, "BlackElo");
            if (isElo) {
                const value = std.fmt.parseInt(usize, try self.infoValue(), 10) catch 0;
                if (value < MIN_ELO) {
                    try self.skipToMoves();
                    try self.next();
                    continue;
                }
            }
            try self.next();
        }
        if (std.mem.indexOfAny(u8, self.line, "[]{}%?!")) |_| {
            try self.findNextInterestingGame();
            return;
        }
        try self.skipToMoves();
    }

    fn infoKey(self: *@This()) ![]const u8 {
        assert(self.lookingAtInfo());
        var parts = std.mem.splitScalar(u8, self.line, ' ');
        return (parts.next().?)[1..];
    }

    fn infoValue(self: *@This()) ![]const u8 {
        assert(self.lookingAtInfo());
        var parts = std.mem.splitScalar(u8, self.line, '"');
        assert(parts.next() != null);
        const val = parts.next().?;
        return val[0..val.len];
    }

    fn skipToMoves(self: *@This()) !void {
        while (self.lookingAtInfo()) {
            try self.next();
        }

        if (std.mem.indexOfAny(u8, self.line, "[]{}%?!")) |_| {
            try self.next();
            try self.skipToMoves();
            return;
        }

        self.nextMovePart = null;
        self.board = try Board.initial();
        self.moveIndex = 0;
        self.moves = std.mem.splitScalar(u8, self.line, '.');
        if (!std.mem.eql(u8, self.moves.?.next().?, "1")) {
            try self.next();
            try self.skipToMoves();
        }
    }

    fn getMove(self: *@This(), lists: *movegen.ListPool) !?Move {
        assert(!self.lookingAtInfo());

        if (self.nextMovePart) |blackMove| {
            self.nextMovePart = null;
            const move = try parsePgnMove(&self.board, blackMove, lists);
            self.moveIndex += 1;
            return move;
        }

        if (self.moves.?.next()) |fullMoveText| {
            var parts = std.mem.splitScalar(u8, fullMoveText, ' ');
            assert(parts.next().?.len == 0);
            const whiteMove = parts.next().?;
            if (parts.next()) |blackMove| {
                self.nextMovePart = blackMove;
            }
            const move = try parsePgnMove(&self.board, whiteMove, lists);
            self.moveIndex += 1;
            return move;
        }

        return null;
    }

    fn lookingAtInfo(self: @This()) bool {
        return self.line[0] == '[';
    }
};

pub fn parsePgnMove(board: *Board, pgnText: []const u8, lists: *movegen.ListPool) !Move {
    // std.debug.print("{s}\n", .{pgnText});
    const moves = try movegen.possibleMoves(board, board.nextPlayer, lists);
    defer lists.release(moves);

    if (std.mem.startsWith(u8, pgnText, "O-O")) {
        const wantLeft = std.mem.startsWith(u8, pgnText, "O-O-O");
        for (moves.items) |move| {
            const isLeft = move.to % 8 != 6;
            switch (move.action) {
                .castle => if (isLeft == wantLeft) return move,
                else => {},
            }
        }
        return error.InvalidMove; // can't castle
    } else if (std.mem.indexOfAny(u8, pgnText, "-*")) |_| {
        return error.GameOver;
    }

    const kind = if (pgnText.len == 2) .Pawn else whichPiece(pgnText[0]) catch .Pawn;
    var start = pgnText.len - 2;
    if (pgnText[pgnText.len - 1] == '+' or pgnText[pgnText.len - 1] == '#') start -= 1;
    var promotionTarget: ?Kind = null;
    if (pgnText[start] == '=') {
        promotionTarget = try whichPiece(pgnText[start + 1]);
        start -= 2;
    }

    const targetSquare = (try UCI.letterToRank(pgnText[start + 1])) * 8 + (try UCI.letterToFile(pgnText[start]));
    var matchingMoves = try lists.get();
    defer lists.release(matchingMoves);
    for (moves.items) |move| {
        if (promotionTarget) |wantKind| {
            switch (move.action) {
                .promote => |gotKind| {
                    if (wantKind != gotKind) continue;
                },
                else => continue,
            }
        }
        assert(board.squares[move.from].colour == board.nextPlayer);
        if (move.to == targetSquare and board.squares[move.from].kind == kind) try matchingMoves.append(move);
    }
    if (matchingMoves.items.len == 0) return error.InvalidMove; // no moves match
    if (matchingMoves.items.len == 1) return matchingMoves.items[0];

    const hasKindLetter = !std.meta.isError(whichPiece(pgnText[0]));
    const infoIndex: usize = if (hasKindLetter) 1 else 0;

    if (UCI.letterToFile(pgnText[infoIndex]) catch null) |file| {
        for (matchingMoves.items) |move| {
            if (move.from % 8 == file) return move;
        }
    }
    if (UCI.letterToRank(pgnText[infoIndex]) catch null) |rank| {
        for (matchingMoves.items) |move| {
            if (move.from / 8 == rank) return move;
        }
    }

    board.debugPrint();
    std.debug.print("{s} matches multiple: ", .{pgnText});
    for (matchingMoves.items) |move| {
        std.debug.print("{s}, ", .{ try move.text() });
    }
    std.debug.print("\n", .{});
    return error.InvalidMove; // multiple moves match
}

fn whichPiece(letter: u8) !Kind {
    return switch (letter) {
        'N' => .Knight,
        'B' => .Bishop,
        'Q' => .Queen,
        'K' => .King,
        'R' => .Rook,
        'P' => .Pawn,
        else => return error.InvalidMove,
    };
}

const PosInfo = struct {
    hash: u64,
    moveCount: std.AutoHashMap(Move, u64),
};

const Book = struct {
    boards: std.AutoHashMap(u64, PosInfo),
};
