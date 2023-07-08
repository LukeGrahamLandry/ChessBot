const std = @import("std");
const Colour = @import("board.zig").Colour;
const Board = @import("board.zig").Board;
const moves = @import("moves.zig");

var internalBoard = Board.initial();
export var theBoard: [64] u8 = @bitCast(Board.initial().squares);
var nextColour: Colour = .White;

const alloc = std.heap.wasm_allocator;
var notTheRng = std.rand.DefaultPrng.init(0);
var rng = notTheRng.random();

export fn playNextMove() bool {
   const allMoves = moves.possibleMoves(&internalBoard, nextColour, alloc) catch return false;
   defer alloc.free(allMoves);
   if (allMoves.len == 0) {
      return false;
   }

   const choice = rng.uintLessThanBiased(usize, allMoves.len);
   const move = allMoves[choice];
   internalBoard.play(move);

   theBoard = @bitCast(internalBoard.squares);
   nextColour = nextColour.other();
   return true;
}
