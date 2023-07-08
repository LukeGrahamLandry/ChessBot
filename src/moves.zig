const std = @import("std");

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

    fn irf(from: usize, toFile: usize, toRank: usize) Move {
        std.debug.assert(from < 64 and toFile < 8 and toRank < 8);
        return .{
            .from=@truncate(from),
            .target = .{.to = @truncate(toRank*8 + toFile)}
        };
    }

    fn irfPawn(from: usize, toFile: usize, toRank: usize, colour: Colour) Move {
        if ((colour == .Black and toRank == 0) or (colour == .White and toRank == 7)){
            return .{
                .from=@truncate(from),
                .target = .{.promote = .Queen }
            };
        } else {
            return irf(from, toFile, toRank);
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
                switch (me) {
                    .White => {
                        if (rank < 7) {
                            if (board.get(file, rank + 1).empty()) {  // forward
                                try moves.append(Move.irfPawn(i, file, rank + 1, me));
                            }
                            if (file < 7 and board.get(file + 1, rank + 1).colour == me.other()) {  // right
                                try moves.append(Move.irfPawn(i, file + 1, rank + 1, me));
                            }
                            if (file > 0 and board.get(file - 1, rank + 1).colour == me.other()) {  // left
                                try moves.append(Move.irfPawn(i, file - 1, rank + 1, me));
                            }
                        }
                        if (rank == 1 and board.get(file, 2).empty() and board.get(file, 3).empty()) {  // forward two
                            try moves.append(Move.irf(i, file, 3));
                        }
                    },
                    .Black => {
                        if (rank > 0) {
                            if (board.get(file, rank - 1).empty()) {  // forward
                                try moves.append(Move.irfPawn(i, file, rank - 1, me));
                            }
                            if (file < 7 and board.get(file + 1, rank - 1).colour == me.other()) {  // right
                                try moves.append(Move.irfPawn(i, file + 1, rank - 1, me));
                            }
                            if (file > 0 and board.get(file - 1, rank - 1).colour == me.other()) {  // left
                                try moves.append(Move.irfPawn(i, file - 1, rank - 1, me));
                            }
                        }
                        
                        if (rank == 6 and board.get(file, 5).empty() and board.get(file, 4).empty()) {  // forward two
                            try moves.append(Move.irf(i, file, 4));
                        }

                    },
                    .Empty => unreachable,
                }
            },
            .Bishop => continue,
            .Knight => continue,
            .Rook => {
                // try rookSlide(&moves, board, i, file, rank, piece);
            },
            .King => continue,
            .Queen => {
                // try rookSlide(&moves, board, i, file, rank, piece);
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
            const check = board.get(checkFile, rank);
            if (check.colour != piece.colour) {
                try moves.append(Move.irf(i, checkFile, rank));
                if (!check.empty()) break;
            } else break;
        }
    }
    
    if (file > 0) {
        for (1..file) |checkFile| {
            const check = board.get((file-checkFile), rank);
            if (check.colour != piece.colour) {
                try moves.append(Move.irf(i, file-checkFile, rank));
                if (!check.empty()) break;
            } else break;
        }
    }

    if (rank < 7) {
        for ((rank + 1)..8) |checkRank| {
            const check = board.get(file, checkRank);
            if (check.colour != piece.colour) {
                try moves.append(Move.irf(i, file, checkRank));
                if (!check.empty()) break;
            } else break;
        }
    }
    
    if (rank > 0) {
        for (1..rank) |checkRank| {
                const check = board.get(file, (rank-checkRank));
            if (check.colour != piece.colour) {
                try moves.append(Move.irf(i, file, (rank-checkRank)));
                if (!check.empty()) break;
            } else break;
        }
    }
}

// TODO: test that reads move data base and makes sure every move seems valid to me. 
