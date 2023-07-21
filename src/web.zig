//! C ABI functions that JavaScript can call.

const std = @import("std");
const assert = std.debug.assert;
const Colour = @import("board.zig").Colour;
const Board = @import("board.zig").Board;
const Piece = @import("board.zig").Piece;
const bestMove = @import("search.zig").bestMove;
const isGameOver = @import("search.zig").isGameOver;
const genAllMoves = @import("search.zig").genAllMoves;
const Move = @import("board.zig").Move;
const Magic = @import("common.zig").Magic;
const Lines = @import("search.zig").Lines;
const print = consolePrint;

comptime {
    assert(@sizeOf(Piece) == @sizeOf(u8));
}
// TODO: want multiple games so give js opaque pointers instead.
var internalBoard: Board = Board.initial();
export var boardView: [64]u8 = undefined;
export var fenView: [80]u8 = undefined; // This length MUST match the one in js handleSetFromFen.
export var msgBuffer: [80]u8 = undefined; // This length MUST match the one in js
var lastMove: ?Move = null;

const alloc = std.heap.wasm_allocator;
var notTheRng = std.rand.DefaultPrng.init(0);
var rng = notTheRng.random();

extern fn jsConsoleLog(ptr: [*]const u8, len: usize) void;
extern fn jsAlert(ptr: [*]const u8, len: usize) void; // TODO: use for assertions if enabled
extern fn jsDrawCurrentBoard(depth: i32, eval: i32, index: u32, count: u32) void;
pub extern fn jsPerformaceNow() f64;

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

export fn setup() void {
    @import("common.zig").setup();
}

/// OUT: internalBoard, boardView, lastMove
export fn restartGame() void {
    internalBoard = Board.initial();
    boardView = @bitCast(internalBoard.squares);
    lastMove = null;
}

/// Returns 0->continue, 1->error, >1 -> game over string length
/// IN: internalBoard, boardView
/// OUT: internalBoard, boardView, msgBuffer, lastMove
export fn playNextMove() i32 {
    const move = bestMove(.{}, &internalBoard, maxDepth, maxTimeMs) catch |err| {
        switch (err) {
            error.GameOver => {
                // Engine couldn't move.
                const len = checkGameOver();
                return if (len > 0) len else 1;
            },
            else => logErr(err, "playNextMove"),
        }
        return 1;
    };

    _ = internalBoard.play(move);
    lastMove = move;
    boardView = @bitCast(internalBoard.squares);

    return checkGameOver(); // Check if human won't be able to move.
}

fn checkGameOver() i32 {
    const reason = isGameOver(&internalBoard, alloc) catch return -1;
    if (reason == .Continue) return 0;
    const str = @tagName(reason);
    print("Game over: {s}", .{str});
    // TODO: cringe global string buffer.
    @memcpy(msgBuffer[0..str.len], str);
    return @intCast(str.len);
}

/// Returns a bit board showing which squares the piece in <from> can move to.
/// IN: internalBoard
export fn getPossibleMoves(from: i32) u64 {
    const piece = internalBoard.squares[@intCast(from)];
    if (piece.empty()) return 0;
    var result: u64 = 0;
    const file = @mod(from, 8);
    const rank = @divFloor(from, 8);

    var allMoves = std.ArrayList(Move).init(alloc);
    genAllMoves.collectOnePieceMoves(&allMoves, &internalBoard, @intCast(from), @intCast(file), @intCast(rank)) catch |err| {
        logErr(err, "getPossibleMoves");
        return 1;
    };
    defer allMoves.deinit();
    for (allMoves.items) |move| {
        const unMove = internalBoard.play(move);
        defer internalBoard.unplay(unMove);
        if (internalBoard.inCheck(piece.colour)) continue;
        result |= @as(u64, 1) << @intCast(move.to);
    }
    return result;
}

/// IN: fenView
/// OUT: internalBoard, boardView
export fn setFromFen(length: u32) bool {
    const fenSlice = fenView[0..@as(usize, length)];
    const temp = Board.fromFEN(fenSlice) catch |err| {
        logErr(err, "setFromFen");
        return false;
    };
    internalBoard = temp;
    boardView = @bitCast(internalBoard.squares);
    lastMove = null;
    return true;
}

/// Returns the length of the string or 0 if error.
/// IN: internalBoard
/// OUT: fenView
export fn getFen() u32 {
    var buffer = std.heap.FixedBufferAllocator.init(&fenView);
    const fen = internalBoard.toFEN(buffer.allocator()) catch |err| {
        logErr(err, "getFen");
        return 0;
    };
    return fen.len;
}

/// IN: internalBoard
export fn getMaterialEval() i32 {
    return internalBoard.simpleEval;
}

/// Returns 0->continue, 1->error, 4->invalid move.
/// IN: internalBoard, boardView
/// OUT: internalBoard, boardView, msgBuffer
export fn playHumanMove(fromIndex: u32, toIndex: u32) i32 {
    if (fromIndex >= 64 or toIndex >= 64) return 1;

    lastMove = (@import("board.zig").inferPlayMove(&internalBoard, fromIndex, toIndex, alloc) catch |err| {
        switch (err) {
            error.IllegalMove => return 4,
            else => logErr(err, "playHumanMove"),
        }
        return 1;
    }).move;
    boardView = @bitCast(internalBoard.squares);
    return 0;
}

fn logErr(err: anyerror, func: []const u8) void {
    print("Error at {s}: {}", .{ func, err });
}

// TODO: one for illigal moves (because check)
// TODO: seperate functions probably better than magic nubers
/// IN: internalBoard
const one: u64 = 1;
export fn getBitBoard(magicEngineIndex: u32, colourIndex: u32) u64 {
    const colour: Colour = if (colourIndex == 0) .White else .Black;
    return switch (magicEngineIndex) {
        0 => internalBoard.peicePositions.getFlag(colour),
        1 => if (colour == .Black) (one << internalBoard.blackKingIndex) else (one << internalBoard.whiteKingIndex),
        2 => {
            const left = internalBoard.castling.get(colour, true);
            const right = internalBoard.castling.get(colour, false);
            var result: u64 = 0;
            if (left) result |= one;
            if (right) result |= one << 7;
            if (colourIndex == 1) result <<= (8 * 7);
            return result;
        },
        3 => {
            if (lastMove) |move| {
                var result: u64 = (one << move.to) | (one << move.from);
                switch (move.action) {
                    .castle => |info| {
                        result |= (one << info.rookTo) | (one << info.rookFrom);
                    },
                    else => {},
                }
                return result;
            } else {
                return 0;
            }
        },
        4 => { // en-passant
            switch (internalBoard.frenchMove) {
                .none => return 0,
                .file => |targetFile| {
                    const index = @as(u6, if (internalBoard.nextPlayer == .White) 5 else 2) * 8 + targetFile;
                    return one << index;
                },
            }
        },
        else => 0,
    };
}

export fn isWhiteTurn() bool {
    return internalBoard.nextPlayer == .White;
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
