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

export fn restartGame() void {
   internalBoard = Board.initial();
   theBoard = @bitCast(internalBoard.squares);
   nextColour = .White;
}

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
