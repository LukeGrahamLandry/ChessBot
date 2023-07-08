const std = @import("std");
const assert = std.debug.assert;

const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;

pub const Move = struct {
    from: u6,
    target: union(enum) {
        to: u6,
        promote: Kind,
    },

    fn irf(fromIndex: usize, toFile: usize, toRank: usize) Move {
        std.debug.assert(fromIndex < 64 and toFile < 8 and toRank < 8);
        return .{
            .from=@truncate(fromIndex),
            .target = .{.to = @truncate(toRank*8 + toFile)}
        };
    }

    fn irfPawn(fromIndex: usize, toFile: usize, toRank: usize, colour: Colour) Move {
        if ((colour == .Black and toRank == 0) or (colour == .White and toRank == 7)){
            // Just assume making a queen is always the right choice. 
            return .{
                .from=@truncate(fromIndex),
                .target = .{.promote = .Queen }
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
pub fn possibleMoves(board: *const Board, me: Colour, allocator: std.mem.Allocator) ![] Move {
    var moves = std.ArrayList(Move).init(allocator);
    for (board.squares, 0..) |piece, i| {
        if (piece.colour != me) continue;
        
        const file = i % 8;
        const rank = i / 8;
        switch (piece.kind) {
            .Pawn => {
                try pawnMove(&moves, board, i, file, rank, piece);
            },
            .Bishop => {
                try bishopSlide(&moves, board, i, file, rank, piece);
            },
            .Knight => continue,
            .Rook => {
                try rookSlide(&moves, board, i, file, rank, piece);
            },
            .King => continue,
            .Queen => {
                try rookSlide(&moves, board, i, file, rank, piece);
                try bishopSlide(&moves, board, i, file, rank, piece);
            },
            .Empty => continue,
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
        for (1..file) |checkFile| {
            if (try trySlide(moves, board, i, file - checkFile, rank, piece)) break;
        }
    }

    if (rank < 7) {
        for ((rank + 1)..8) |checkRank| {
            if (try trySlide(moves, board, i, file, checkRank, piece)) break;
        }
    }
    
    if (rank > 0) {
        for (1..rank) |checkRank| {
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

// TODO: test that reads move data base and makes sure every move seems valid to me. 


var tst = std.testing.allocator;

test "count starting moves" {
    var game = Board.initial();
    const allMoves = try possibleMoves(&game, .White, tst);
    defer tst.free(allMoves);
    // These parameters are backwards because it can't infer type from a comptime_int. This seems dumb. 
    // TODO: I don't have knight moves yet!
    try std.testing.expectEqual(allMoves.len, 16);
}
