const std = @import("std");
const assert = std.debug.assert;
const Colour = @import("board.zig").Colour;
const Board = @import("board.zig").Board;
const Piece = @import("board.zig").Piece;
const search = @import("search.zig").Strategy(.{});
const genAllMoves = @import("search.zig").genAllMoves;
const Move = @import("board.zig").Move;
const print = consolePrint;

comptime {
    assert(@sizeOf(Piece) == @sizeOf(u8));
}
// TODO: want multiple games so give js opaque pointers instead.
var internalBoard: Board = Board.initial();
export var boardView: [64]u8 = undefined;
var nextColour: Colour = .White;
export var fenView: [80]u8 = undefined; // This length MUST match the one in js handleSetFromFen.
var lastMove: ?Move = null;

const alloc = std.heap.wasm_allocator;
var notTheRng = std.rand.DefaultPrng.init(0);
var rng = notTheRng.random();

extern fn jsConsoleLog(ptr: [*]const u8, len: usize) void;

// TODO: log something whenever returning an error code.
pub fn consolePrint(comptime fmt: []const u8, args: anytype) void {
    var buffer: [2048]u8 = undefined;
    var str = std.fmt.bufPrint(&buffer, fmt, args) catch "Error while printing!";
    jsConsoleLog(str.ptr, str.len);
}

/// OUT: internalBoard, boardView, nextColour
export fn restartGame() void {
    internalBoard = Board.initial();
    boardView = @bitCast(internalBoard.squares);
    nextColour = .White;
    lastMove = null;
    print("{}", .{search.config});
}

/// Returns 0->continue, 1->error, 2->black wins, 3->white wins.
/// IN: internalBoard, boardView, nextColour
/// OUT: internalBoard, boardView, nextColour
export fn playRandomMove() i32 {
    const allMoves = genAllMoves.possibleMoves(&internalBoard, nextColour, alloc) catch return 1;
    defer alloc.free(allMoves);
    if (allMoves.len == 0) {
        return if (nextColour == .White) 2 else 3;
    }

    const choice = rng.uintLessThanBiased(usize, allMoves.len);
    const move = allMoves[choice];
    _ = internalBoard.play(move);

    lastMove = move;
    boardView = @bitCast(internalBoard.squares);
    nextColour = nextColour.other();
    return 0;
}

/// Returns 0->continue, 1->error, 2->black wins, 3->white wins.
/// IN: internalBoard, boardView, nextColour
/// OUT: internalBoard, boardView, nextColour
export fn playNextMove() i32 {
    const move = search.bestMove(&internalBoard, nextColour, null) catch |err| {
        switch (err) {
            error.GameOver => return if (nextColour == .White) 2 else 3,
            else => return 1,
        }
    };

    _ = internalBoard.play(move);
    lastMove = move;
    boardView = @bitCast(internalBoard.squares);
    nextColour = nextColour.other();
    return 0;
}

/// Returns a bit board showing which squares the piece in <from> can move to.
/// IN: internalBoard, nextColour
export fn getPossibleMoves(from: i32) u64 {
    const piece = internalBoard.squares[@intCast(from)];
    if (piece.empty()) return 0;
    var result: u64 = 0;
    const file = @mod(from, 8);
    const rank = @divFloor(from, 8);

    var allMoves = std.ArrayList(Move).init(alloc);
    genAllMoves.collectOnePieceMoves(&allMoves, &internalBoard, @intCast(from), @intCast(file), @intCast(rank)) catch return 1;
    defer allMoves.deinit();
    for (allMoves.items) |move| {
        const unMove = internalBoard.play(move);
        defer internalBoard.unplay(unMove);
        if (search.inCheck(&internalBoard, piece.colour, alloc) catch return 1) continue;
        result |= @as(u64, 1) << @intCast(move.to);
    }
    return result;
}

/// IN: fenView
/// OUT: internalBoard, boardView, nextColour
export fn setFromFen(length: u32) bool {
    const fenSlice = fenView[0..@as(usize, length)];
    const temp = Board.fromFEN(fenSlice) catch return false;
    internalBoard = temp;
    boardView = @bitCast(internalBoard.squares);
    lastMove = null;
    return true;
}

/// Returns the length of the string or 0 if error.
/// IN: internalBoard
/// OUT: fenView
// TODO: unnecessary allocation just to memcpy.
export fn getFen() u32 {
    const fen = internalBoard.toFEN(alloc) catch return 0;
    defer alloc.free(fen);
    assert(fen.len <= fenView.len);
    @memcpy(fenView[0..fen.len], fen);
    return fen.len;
}

/// IN: internalBoard
export fn getMaterialEval() i32 {
    return genAllMoves.simpleEval(&internalBoard);
}

// TODO: return win/lose
/// Returns 0->continue, 1->error, 2->black wins, 3->white wins, 4->invalid move.
/// IN: internalBoard, boardView, nextColour
/// OUT: internalBoard, boardView, nextColour
export fn playHumanMove(fromIndex: u32, toIndex: u32) i32 {
    if (fromIndex >= 64 or toIndex >= 64) return 1;

    lastMove = (@import("board.zig").inferPlayMove(&internalBoard, fromIndex, toIndex, alloc) catch |err| {
        switch (err) {
            error.IllegalMove => return 4,
            else => return 1,
        }
    }).move;
    boardView = @bitCast(internalBoard.squares);
    nextColour = nextColour.other();
    return 0;
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
                    const index = @as(u6, if (nextColour == .White) 5 else 2) * 8 + targetFile;
                    return one << index;
                },
            }
        },
        else => 0,
    };
}

export fn isWhiteTurn() bool {
    return nextColour == .White;
}
