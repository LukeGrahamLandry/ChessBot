const std = @import("std");
const assert = std.debug.assert;
const Colour = @import("board.zig").Colour;
const Board = @import("board.zig").Board;
const Piece = @import("board.zig").Piece;
const moves = @import("moves.zig").Strategy(.{});
const genAllMoves = @import("moves.zig").genAllMoves;
const Move = @import("moves.zig").Move;

comptime { assert(@sizeOf(Piece) == @sizeOf(u8)); }
var internalBoard: Board = Board.initial();
export var boardView: [64] u8 = undefined;
var nextColour: Colour = .White;
export var fenView: [80] u8 = undefined;  // This length must match the one in js handleSetFromFen.
var lastMove: ?Move = null;

const alloc = std.heap.wasm_allocator;
var notTheRng = std.rand.DefaultPrng.init(0);
var rng = notTheRng.random();

/// OUT: internalBoard, boardView, nextColour
export fn restartGame() void {
   internalBoard = Board.initial();
   boardView = @bitCast(internalBoard.squares);
   nextColour = .White;
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
   _ = internalBoard.play(move) catch return 1;
   
   lastMove = move;
   boardView = @bitCast(internalBoard.squares);
   nextColour = nextColour.other();
   return 0;
}

/// Returns 0->continue, 1->error, 2->black wins, 3->white wins. 
/// IN: internalBoard, boardView, nextColour
/// OUT: internalBoard, boardView, nextColour
export fn playNextMove() i32 {
   const move = moves.bestMove(&internalBoard, nextColour) catch |err| {
      switch (err) {
         error.OutOfMemory => return 1,
         error.GameOver => return if (nextColour == .White) 2 else 3,
      }
   };

   _ = internalBoard.play(move) catch return 1;
   lastMove = move;
   boardView = @bitCast(internalBoard.squares);
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
   const allMoves = genAllMoves.possibleMoves(&internalBoard, piece.colour, alloc) catch return 1;
   defer alloc.free(allMoves);
   for (allMoves) |move| {
      if (@as(i32, move.from) == from) {
         const unMove = internalBoard.play(move) catch return 1;
         defer internalBoard.unplay(unMove);
         if (moves.inCheck(&internalBoard, piece.colour, alloc) catch return 1) continue;
         result |= @as(u64, 1) << @intCast(move.to);
      }
   }
   return result;
}

/// IN: fenView
/// OUT: internalBoard, boardView, nextColour
// TODO: this always sets next move to white but real fen contains that info. 
export fn setFromFen(length: u32) bool {
   const fenSlice = fenView[0..@as(usize, length)];
   const temp = Board.fromFEN(fenSlice) catch return false;
   internalBoard = temp;
   boardView = @bitCast(internalBoard.squares);
   nextColour = .White;  // TODO
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
   const isCapture = !internalBoard.squares[toIndex].empty() and internalBoard.squares[toIndex].colour != nextColour;
   // TODO: can't castle
   var move: Move  = .{ .from=@intCast(fromIndex), .to=@intCast(toIndex), .action=.none, .isCapture=isCapture};
   // TODO: ui should know when promoting so it can let you choose which piece to make. 
   if (internalBoard.squares[fromIndex].kind == .Pawn) {
      // TODO: factor out some canPromote function so magic numbers live in one place
      const isPromote = (nextColour == .Black and toIndex <= 7) or (nextColour == .White and toIndex > (64-8));
      if (isPromote) move.action = .{.promote = .Queen };
   } else if (internalBoard.squares[fromIndex].kind == .King) {
      var castles = std.ArrayList(Move).init(alloc);
      defer castles.deinit();
      const file: usize = @rem(fromIndex, 8);
      const rank: usize = @divFloor(fromIndex, 8);
      genAllMoves.tryCastle(&castles, &internalBoard, @intCast(fromIndex), file, rank, nextColour, true) catch return 1;
      genAllMoves.tryCastle(&castles, &internalBoard, @intCast(fromIndex), file, rank, nextColour, false) catch return 1;
      assert(castles.items.len <= 2);
      if (castles.items.len > 0 and castles.items[0].to == toIndex) {
         move = castles.items[0];
      } else if (castles.items.len > 1 and castles.items[1].to == toIndex) {
         move = castles.items[1];
      }
   }

   if (internalBoard.squares[fromIndex].colour != nextColour) return 4;

   // Check if this is a legal move by the current player. 
   const allMoves = genAllMoves.possibleMoves(&internalBoard, nextColour, alloc) catch return 1;
   defer alloc.free(allMoves);
   for (allMoves) |m| {
      if (std.meta.eql(move, m)) break;
   } else {
      return 4;
   }

   const unMove = internalBoard.play(move) catch return 1;
   if (moves.inCheck(&internalBoard, nextColour, alloc) catch return 1) {
      internalBoard.unplay(unMove);
      return 4;
   }

   lastMove = move;
   boardView = @bitCast(internalBoard.squares);
   nextColour = nextColour.other();
   return 0;
}

// TODO: one for illigal moves (because check)
const one: u64 = 1;
export fn getBitBoard(magicEngineIndex: u32, colourIndex: u32) u64 {
   const colour: Colour = if (colourIndex == 0) .White else .Black;
   return switch (magicEngineIndex) {
      0 => internalBoard.peicePositions.getFlag(colour),
      1 => if (colour == .Black) (one << internalBoard.blackKingIndex) else (one << internalBoard.whiteKingIndex),
      2 => {
         const left = internalBoard.castling.left[colourIndex];
         const right = internalBoard.castling.right[colourIndex];
         var result: u64 = 0;
         if (left) result |= one;
         if (right) result |= one << 7;
         if (colourIndex == 1) result <<= (8*7);
         return result;
      },
      3 => {
         if (lastMove) |move|{
            var result: u64 = (one << move.to) | (one << move.from);
            switch (move.action) {
               .castle => |info| {
                  result |= (one << info.rookTo) | (one << info.rookFrom);
               },
               else => {}
            }
            return result;
         } else {
            return 0;
         }
      },
      else => 0,
   };
}

export fn isWhiteTurn() bool {
   return nextColour == .White;
}
