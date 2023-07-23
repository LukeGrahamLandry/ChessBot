//! C ABI functions that JavaScript can call.

const std = @import("std");
const assert = std.debug.assert;
const Colour = @import("board.zig").Colour;
const Board = @import("board.zig").Board;
const Piece = @import("board.zig").Piece;
const search = @import("search.zig");
const Move = @import("board.zig").Move;
const Magic = @import("common.zig").Magic;
const print = consolePrint;

const walloc = std.heap.wasm_allocator;

extern fn jsConsoleLog(ptr: [*]const u8, len: usize) void;
extern fn jsAlert(ptr: [*]const u8, len: usize) void; // TODO: use for assertions if enabled
extern fn jsDrawCurrentBoard(depth: i32, eval: i32, index: u32, count: u32) void;
pub extern fn jsPerformaceNow() f64;

// This lets js detect if something got cached and its using a version of the wasm blob with an API it won't understand.
export fn protocolVersion() i32 {
    return 2;
}

const JsResult = enum(i32) {
    Ok = -1,
    Error = -2,
    IllegalMove = -3,
};

// TODO: think about this more. since printing is a comptime thing, commenting these out saves ~115kb (out of ~400).
pub fn consolePrint(comptime fmt: []const u8, args: anytype) void {
    var buffer: [2048]u8 = undefined;
    var str = std.fmt.bufPrint(&buffer, fmt, args) catch "Error while printing!";
    jsConsoleLog(str.ptr, str.len);
}

pub fn alertPrint(comptime fmt: []const u8, args: anytype) void {
    var buffer: [2048]u8 = undefined;
    var str = std.fmt.bufPrint(&buffer, fmt, args) catch "Error while printing!";
    jsAlert(str.ptr, str.len);
}

export fn alloc(len: u32) ?[*]u8 {
    const mem = walloc.alloc(u8, len) catch |err| {
        logErr(err, "alloc");
        return null;
    };
    return mem.ptr;
}

export fn drop(ptr: ?[*]u8, len: u32) void {
    if (ptr) |nnptr| {
        walloc.free(nnptr[0..len]);
    }
}

export fn createBoard() ?*Board {
    var board = walloc.create(Board) catch |err| {
        logErr(err, "createBoard");
        return null;
    };
    board.* = Board.initial();
    return board;
}

export fn destroyBoard(board: *Board) void {
    walloc.destroy(board);
}

export fn setup() void {
    @import("common.zig").setup();
}

export fn restartGame(board: *Board) void {
    board.* = Board.initial();
}

comptime { assert(@sizeOf(Piece) == @sizeOf(u8)); }
export fn getBoardData(board: *Board) [*]u8 {
    return @ptrCast(&board.squares);
}

/// Returns 0 for continue or game over string length
export fn playBotMove(board: *Board, msgPtr: [*] u8, maxLen: u32) i32 {
    const move = search.bestMove(.{}, board, maxDepth, maxTimeMs) catch |err| {
        switch (err) {
            error.GameOver => {
                // Engine couldn't move.
                const len = checkGameOver(board, msgPtr, maxLen);
                return if (len > 0) len else @intFromEnum(JsResult.Error);
            },
            else => logErr(err, "playNextMove"),
        }
        return @intFromEnum(JsResult.Error);
    };

    _ = board.play(move);

    // Check if human won't be able to move next turn.
    const len = checkGameOver(board, msgPtr, maxLen);
    return if (len > 0) len else @intFromEnum(JsResult.Ok);
}

fn checkGameOver(board: *Board, msgPtr: [*] u8, maxLen: u32) i32 {
    const reason = board.gameOverReason(walloc) catch return -1;
    if (reason == .Continue) return 0;
    const str = @tagName(reason);
    print("Game over: {s}\n", .{str});
    @memcpy(msgPtr[0..@min(str.len, maxLen)], str);
    return @intCast(str.len);
}

/// Returns a bit board showing which squares the piece in <from> can move to.
export fn getPossibleMovesBB(board: *Board, from: i32) u64 {
    const piece = board.squares[@intCast(from)];
    if (piece.empty()) return 0;
    var result: u64 = 0;
    const file = @mod(from, 8);
    const rank = @divFloor(from, 8);

    var allMoves = std.ArrayList(Move).init(walloc);
    // TODO: check if in check and not moving king here because its done in genAllMoves
    search.genAllMoves.collectOnePieceMoves(&allMoves, board, @intCast(from), @intCast(file), @intCast(rank)) catch |err| {
        logErr(err, "getPossibleMoves");
        return 0;
    };
    defer allMoves.deinit();
    for (allMoves.items) |move| {
        result |= @as(u64, 1) << @intCast(move.to);
    }
    return result;
}

export fn setFromFen(board: *Board, ptr: [*] const u8, len: u32) bool {
    const fenSlice = ptr[0..@as(usize, len)];
    const temp = Board.fromFEN(fenSlice) catch |err| {
        logErr(err, "setFromFen");
        return false;
    };
    board.* = temp;
    return true;
}

/// Returns the length of the string or 0 if error.
export fn getFen(board: *const Board, out_ptr: [*] u8, maxLen: u32) u32 {
    var buffer = std.heap.FixedBufferAllocator.init(out_ptr[0..maxLen]);
    const fen = board.toFEN(buffer.allocator()) catch |err| {
        logErr(err, "getFen");
        return 0;
    };
    return fen.len;
}

export fn getMaterialEval(board: *Board) i32 {
    return board.simpleEval;
}

/// Returns 0->continue, 1->error, 4->invalid move.
export fn playHumanMove(board: *Board, fromIndex: u32, toIndex: u32) JsResult {
    if (fromIndex >= 64 or toIndex >= 64) return .Error;

    _ = @import("board.zig").inferPlayMove(board, fromIndex, toIndex, walloc) catch |err| {
        switch (err) {
            error.IllegalMove => return .IllegalMove,
            else => logErr(err, "playHumanMove"),
        }
        return .Error;
    };
    return .Ok;
}

fn logErr(err: anyerror, func: []const u8) void {
    print("Error at {s}: {}\n", .{ func, err });
}

export fn getPositionsBB(board: *Board, colourI: u32) u64 {
    const colour: Colour = if (colourI == 0) .White else .Black;
    return board.peicePositions.getFlag(colour);
}

export fn getKingsBB(board: *Board, colourI: u32) u64 {
    const colour: Colour = if (colourI == 0) .White else .Black;
    return if (colour == .Black) (@as(u64, 1) << board.blackKingIndex) else (@as(u64, 1) << board.whiteKingIndex);
}

export fn getCastlingBB(board: *Board, colourI: u32) u64 {
    const colour: Colour = if (colourI == 0) .White else .Black;
    const left = board.castling.get(colour, true);
    const right = board.castling.get(colour, false);
    var result: u64 = 0;
    if (left) result |= @as(u64, 1);
    if (right) result |= @as(u64, 1) << 7;
    if (colour == .Black) result <<= (8 * 7);
    return result;
}

export fn getLastMoveBB(board: *Board) u64 {
    if (board.lastMove) |move| {
        var result: u64 = (@as(u64, 1) << move.to) | (@as(u64, 1) << move.from);
        switch (move.action) {
            .castle => |info| {
                result |= (@as(u64, 1) << info.rookTo) | (@as(u64, 1) << info.rookFrom);
            },
            else => {},
        }
        return result;
    } else {
        return 0;
    }
}

export fn getFrenchMoveBB(board: *Board) u64 {
    switch (board.frenchMove) {
        .none => return 0,
        .file => |targetFile| {
            const index = @as(u6, if (board.nextPlayer == .White) 5 else 2) * 8 + targetFile;
            return @as(u64, 1) << index;
        },
    }
}

export fn getAttackBB(board: *Board, colourI: u32) u64 {
    const colour: Colour = if (colourI == 0) .White else .Black;
    var out: @import("movegen.zig").GetAttackSquares = .{};
    try @import("movegen.zig").genPossibleMoves(&out, board,colour,  std.testing.failing_allocator);
    return out.bb;
}

export fn slidingChecksBB(board: *Board, colourI: u32) u64 {
    const colour: Colour = if (colourI == 0) .White else .Black;
    return @import("movegen.zig").getChecksInfo(board, colour).blockSingleCheck;
}

export fn pinsByBishopBB(board: *Board, colourI: u32) u64 {
    const colour: Colour = if (colourI == 0) .White else .Black;
    return @import("movegen.zig").getChecksInfo(board, colour).pinsByBishop;
}

export fn pinsByRookBB(board: *Board, colourI: u32) u64 {
    const colour: Colour = if (colourI == 0) .White else .Black;
    return @import("movegen.zig").getChecksInfo(board, colour).pinsByRook;
}

export fn isWhiteTurn(board: *Board) bool {
    return board.nextPlayer == .White;
}

export fn loadOpeningBook(ptr: [*]u32, len: usize) bool {
    _ = len;
    _ = ptr;
    alertPrint("TODO: implement loadOpeningBook", .{});
    return false;
}

var maxDepth: u32 = 0;
var maxTimeMs: u32 = 0;
// This will always be called at the beginning
export fn changeSettings(_maxTimeMs: u32, _maxDepth: u32) void {
    maxDepth = _maxDepth;
    maxTimeMs = _maxTimeMs;
}
