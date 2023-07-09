const std = @import("std");
const assert = std.debug.assert;
const Colour = @import("board.zig").Colour;
const Board = @import("board.zig").Board;
const moves = @import("moves.zig");

var internalBoard = Board.initial();
export var theBoard: [64] u8 = @bitCast(Board.initial().squares);
var nextColour: Colour = .White;
export var fenString: [80] u8 = undefined;

const alloc = std.heap.wasm_allocator;
var notTheRng = std.rand.DefaultPrng.init(0);
var rng = notTheRng.random();

/// OUT: internalBoard, theBoard, nextColour
export fn restartGame() void {
   internalBoard = Board.initial();
   theBoard = @bitCast(internalBoard.squares);
   nextColour = .White;
}

/// Returns 0->continue, 1->error, 2->black wins, 3->white wins. 
/// IN: internalBoard, theBoard, nextColour
/// OUT: internalBoard, theBoard, nextColour
export fn playNextMove() i32 {
   const allMoves = moves.possibleMoves(&internalBoard, nextColour, alloc) catch return 1;
   defer alloc.free(allMoves);
   if (allMoves.len == 0) {
      return if (nextColour == .White) 2 else 3;
   }

   const choice = rng.uintLessThanBiased(usize, allMoves.len);
   const move = allMoves[choice];
   internalBoard.play(move);

   theBoard = @bitCast(internalBoard.squares);
   nextColour = nextColour.other();
   return 0;
}

// TODO: this is a really slow way of doing this. dont need to collect the moves and dont need to check every starting piece 
/// Returns a bit board showing which squares the piece in <from> can move to. 
/// IN: internalBoard, nextColour
export fn getPossibleMoves(from: i32) u64 {
   const piece = internalBoard.squares[@intCast(from)];
   if (piece.empty()) return 0;
   var result: u64 = 0;
   const allMoves = moves.possibleMoves(&internalBoard, piece.colour, alloc) catch return 1;
   defer alloc.free(allMoves);
   for (allMoves) |move| {
      if (@as(i32, move.from) == from) {
         result |= @as(u64, 1) << @intCast(move.to);
      }
   }
   return result;
}

/// IN: fenString
/// OUT: internalBoard, theBoard, nextColour
// TODO: this always sets next move to white but real fen contains that info. 
export fn setFromFen(length: u32) bool {
   const fenSlice = fenString[0..@as(usize, length)];
   internalBoard = Board.fromFEN(fenSlice) catch return false;
   theBoard = @bitCast(internalBoard.squares);
   nextColour = .White;
   return true;
}

// Returns the length of the string or 0 if error. 
/// IN: internalBoard
/// OUT: fenString
// TODO: unnecessary allocation just to memcpy. 
export fn getFen() u32 {
   const fen = internalBoard.toFEN(alloc) catch return 0;
   defer alloc.free(fen);
   assert(fen.len <= fenString.len);
   @memcpy(fenString[0..fen.len], fen);
   return fen.len;
}
