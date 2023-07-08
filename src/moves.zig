const std = @import("std");

const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;

pub const Move = packed struct {
    from: u6,
    to: u6,
};

pub fn pickMove(board: *const Board) Move {
    _ = board;
}

fn toIndex(file: usize, rank: usize) u6  {
    return @truncate(rank*8 + file);
}

// TODO: can I make this like an iterator struct? I kinda don't want to inline it into one big super function but storing them all seems dumb
// TODO: for pruning, want to sort good moves first (like captures) so maybe that does mean need to put all in an array. 
pub fn slowPossibleMoves(board: *const Board, me: Colour, allocator: std.mem.Allocator) ![] Move {
    var moves = std.ArrayList(Move).init(allocator);
    for (board.squares, 0..) |piece, i| {
        if (piece.colour != me) continue;
        
        const file = i % 8;
        const rank = i / 8;
        switch (piece.kind) {
            .Pawn => continue,
            .Bishop => continue,
            .Knight => continue,
            .Rook => {
                for ((file + 1)..8) |checkFile| {
                    const check = board.get(checkFile, rank);
                    std.debug.print("ckeck {} {} {} \n", .{checkFile, rank, check});
                    if (check.colour != piece.colour) {  // includes check.empty()
                        try moves.append(.{ .from=@truncate(i), .to=@truncate(rank*8 + checkFile)});
                        std.debug.print("take {} \n", .{check});
                        if (!check.empty()) {
                            // We took a piece, can't keep moving.
                            break;
                        }
                    } else {
                        std.debug.assert(!check.empty());  // Since empty is a colour.
                        break;
                    }
                }
            },
            .King => continue,
            .Queen => continue,
            .Empty => continue,
        }
    }
    return try moves.toOwnedSlice();
}
