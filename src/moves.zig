const std = @import("std");
const assert = std.debug.assert;

const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;

// This is 4 bytes but, 
// If I was more efficient for promotion targets because you know it's on the far rank, and there's only 4 promotion options,
// this could fit in 3 bytes, [from: u6, action: u1, (to: u6) or (kind: u2, to: u3)] = u13. 
// Or even 2 bytes because if you can check if its a pawn moving from second back rank so you don't need the action flag. 
// But it's not worth dealing with yet. Might be worth it to store the opening book in half the space tho!
pub const Move = struct {
    from: u6,
    to: u6,
    action: union(enum) {
        none,
        promote: Kind,
    },

    fn irf(fromIndex: usize, toFile: usize, toRank: usize) Move {
        std.debug.assert(fromIndex < 64 and toFile < 8 and toRank < 8);
        return .{
            .from=@truncate(fromIndex),
            .to = @truncate(toRank*8 + toFile),
            .action = .none,
        };
    }

    fn irfPawn(fromIndex: usize, toFile: usize, toRank: usize, colour: Colour) Move {
        if ((colour == .Black and toRank == 0) or (colour == .White and toRank == 7)){
            // Just assume making a queen is always the right choice. 
            return .{
                .from=@truncate(fromIndex),
                .to = @truncate(toRank*8 + toFile),
                .action = .{.promote = .Queen }
            };
        } else {
            return irf(fromIndex, toFile, toRank);
        }
    }
};

fn toIndex(file: usize, rank: usize) u6  {
    return @truncate(rank*8 + file);
}

// TODO: can I make this like an iterator struct? I kinda don't want to inline it into one big super function but storing them all seems dumb
// TODO: for pruning, want to sort good moves first (like captures) so maybe that does mean need to put all in an array. 
// TODO: castling, en-passant, check
pub fn possibleMoves(board: *const Board, me: Colour, allocator: std.mem.Allocator) ![] Move {
    assert(me != .Empty);
    var moves = std.ArrayList(Move).init(allocator);
    for (board.squares, 0..) |piece, i| {
        if (piece.colour != me) continue;
        
        const file = i % 8;
        const rank = i / 8;
        switch (piece.kind) {
            .Pawn => try pawnMove(&moves, board, i, file, rank, piece),
            .Bishop => try bishopSlide(&moves, board, i, file, rank, piece),
            .Knight => try knightMove(&moves, board, i, file, rank, piece),
            .Rook => try rookSlide(&moves, board, i, file, rank, piece),
            .King => try kingMove(&moves, board, i, file, rank, piece),
            .Queen => {
                try rookSlide(&moves, board, i, file, rank, piece);
                try bishopSlide(&moves, board, i, file, rank, piece);
            },
            .Empty => unreachable,
        }
    }
    return try moves.toOwnedSlice();
}

fn rookSlide(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    // TODO: this does not spark joy. Feels like there should be some way to express it as a mask that you bit shift around. 
    if (file < 7) {
        for ((file + 1)..8) |checkFile| {
            if (try trySlide(moves, board, i, checkFile, rank, piece)) break;
        }
    }
    
    if (file > 0) {
        for (1..(file+1)) |checkFile| {
            if (try trySlide(moves, board, i, file - checkFile, rank, piece)) break;
        }
    }

    if (rank < 7) {
        for ((rank + 1)..8) |checkRank| {
            if (try trySlide(moves, board, i, file, checkRank, piece)) break;
        }
    }
    
    if (rank > 0) {
        for (1..(rank+1)) |checkRank| {
            if (try trySlide(moves, board, i, file, rank-checkRank, piece)) break;
        }
    }
}

fn pawnMove(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    const targetRank = switch (piece.colour) {
        // Asserts can't have a pawn at the end in real games because it would have promoted. 
        .White => w: {
            assert(rank < 7);  
            if (rank == 1 and board.get(file, 2).empty() and board.get(file, 3).empty()) {  // forward two
                try moves.append(Move.irf(i, file, 3));
            }
            break :w rank + 1;
        },
        .Black => b: {
            assert(rank > 0);
            if (rank == 6 and board.get(file, 5).empty() and board.get(file, 4).empty()) {  // forward two
                try moves.append(Move.irf(i, file, 4));
            }
            break :b rank - 1;
        },
        .Empty => unreachable,
    };

    if (board.get(file, targetRank).empty()) {  // forward
        try moves.append(Move.irfPawn(i, file, targetRank, piece.colour));
    }
    if (file < 7 and board.get(file + 1, targetRank).colour == piece.colour.other()) {  // right
        try moves.append(Move.irfPawn(i, file + 1, targetRank, piece.colour));
    }
    if (file > 0 and board.get(file - 1, targetRank).colour == piece.colour.other()) {  // left
        try moves.append(Move.irfPawn(i, file - 1, targetRank, piece.colour));
    }
}

// Returns true if this move was a capture or blocked by self so loop should break. 
fn trySlide(moves: *std.ArrayList(Move), board: *const Board, i: usize, checkFile: usize, checkRank: usize, piece: Piece) !bool {
    const check = board.get(checkFile, checkRank);
    if (check.colour != piece.colour) {
        try moves.append(Move.irf(i, checkFile, checkRank));
        return !check.empty();
    } else return true;
}

// TODO: This is suck!
fn bishopSlide(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    {
        var checkFile = file;
        var checkRank = rank;
        while (checkFile < 7 and checkRank < 7) {
            checkFile += 1;
            checkRank += 1;
            if (try trySlide(moves, board, i, checkFile, checkRank, piece)) break;
        }
    }

    {
        var checkFile = file;
        var checkRank = rank;
        while (checkFile > 0 and checkRank < 7) {
            checkFile -= 1;
            checkRank += 1;
            if (try trySlide(moves, board, i, checkFile, checkRank, piece)) break;
        }
    }

    {
        var checkFile = file;
        var checkRank = rank;
        while (checkFile < 7 and checkRank > 0) {
            checkFile += 1;
            checkRank -= 1;
            if (try trySlide(moves, board, i, checkFile, checkRank, piece)) break;
        }
    }

    {
        var checkFile = file;
        var checkRank = rank;
        while (checkFile > 0 and checkRank > 0) {
            checkFile -= 1;
            checkRank -= 1;
            if (try trySlide(moves, board, i, checkFile, checkRank, piece)) break;
        }
    }
}

fn kingMove(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    // forward
    if (file < 7) {
        _ = try trySlide(moves, board, i, file + 1, rank, piece);
        if (rank < 7) _ = try trySlide(moves, board, i, file + 1, rank + 1, piece);
        if (rank > 0) _ = try trySlide(moves, board, i, file + 1, rank - 1, piece);
    }
    // back
    if (file > 0) {
        _ = try trySlide(moves, board, i, file - 1, rank, piece);
        if (rank < 7) _ = try trySlide(moves, board, i, file - 1, rank + 1, piece);
        if (rank > 0) _ = try trySlide(moves, board, i, file - 1, rank - 1, piece);
    }
    // horizontal
    if (rank < 7) _ = try trySlide(moves, board, i, file, rank + 1, piece);
    if (rank > 0) _ = try trySlide(moves, board, i, file, rank - 1, piece);
}

fn tryHop(moves: *std.ArrayList(Move), board: *const Board, i: usize, checkFile: usize, checkRank: usize, piece: Piece) !void {
    const check = board.get(checkFile, checkRank);
    if (check.colour != piece.colour) {
        try moves.append(Move.irf(i, checkFile, checkRank));
    } 
}

fn knightMove(moves: *std.ArrayList(Move), board: *const Board, i: usize, file: usize, rank: usize, piece: Piece) !void {
    if (rank < 6){
        if (file < 7) try tryHop(moves, board, i, file + 1, rank + 2, piece);
        if (file > 0) try tryHop(moves, board, i, file - 1, rank + 2, piece);
    }
    if (rank > 1){
        if (file < 7) try tryHop(moves, board, i, file + 1, rank - 2, piece);
        if (file > 0) try tryHop(moves, board, i, file - 1, rank - 2, piece);
    }

    if (file < 6){
        if (rank < 7) try tryHop(moves, board, i, file + 2, rank + 1, piece);
        if (rank > 0) try tryHop(moves, board, i, file + 2, rank - 1, piece);
    }
    if (file > 1){
        if (rank < 7) try tryHop(moves, board, i, file - 2, rank + 1, piece);
        if (rank > 0) try tryHop(moves, board, i, file - 2, rank - 1, piece);
    }
}

// TODO: test that reads move data base and makes sure every move seems valid to me. 
var tst = std.testing.allocator;

test "count starting moves" {
    var game = Board.initial();
    const allMoves = try possibleMoves(&game, .White, tst);
    defer tst.free(allMoves);
    // These parameters are backwards because it can't infer type from a comptime_int. This seems dumb. 
    try std.testing.expectEqual(allMoves.len, 20);
}

// https://www.chess.com/forum/view/fun-with-chess/what-chess-position-has-the-most-number-of-possible-moves?page=2

// test "many moves some promotions" {
//     var game = try Board.fromFEN("R6R/3Q4/1Q4Q1/4Q3/2Q4Q/Q4Q2/pp1Q4/kBNNK1B1");
//     const allMoves = try possibleMoves(&game, .White, tst);
//     defer tst.free(allMoves);
//     try std.testing.expectEqual(allMoves.len, 218);
// }

// test "many moves many promotions" {
//     var game = try Board.fromFEN("1nnrrbbq/PPPPPPPP/1R6/6K1/Q7/2BNNB2/7R/6k1");
//     const allMoves = try possibleMoves(&game, .White, tst);
//     defer tst.free(allMoves);
//     try std.testing.expectEqual(allMoves.len, 139);
// }

// test "many moves" {
//     var game = try Board.fromFEN("r6R/2pbpBk1/1P1B1N2/6q1/4Q3/2nn1p2/1PK1NbP1/R6r");
//     const allMoves = try possibleMoves(&game, .White, tst);
//     defer tst.free(allMoves);
//     try std.testing.expectEqual(allMoves.len, 181);
// }
