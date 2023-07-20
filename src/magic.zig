// TODO: auto train against the fish to find the best settings. draw avoidence, square preference, etc.
// TODO: do I want these to be runtime configurable in the ui?

// Draws are bad if you're up material but good if you're down materal. Should probably have slight preference against because that's more fun.
// TODO: Changing this to not be zero will not work! Meed to multiply by the right dir() when using.
pub const DRAW_EVAL = 0;

// TODO: only good if there are pawns in front of you
pub const CASTLE_REWARD: i32 = 50;

// This gets optimised out if 0.
// Otherwise, super slow! Maybe because of the branch on colour for direction?
// Must be changing how it prunes cause doing bit magic for dir() is still slow.
// Tried turning off capture extend, still slower
// TODO: make sure it looses the extra points when the pawn dies
pub const PUSH_PAWN: i8 = 0;

// TODO: are there better numbers? experimentally run a bunch of games until I find the ones with least collissions?
/// Magic numbers for Zobrist hashing. I think I'm so funny.
/// https://en.wikipedia.org/wiki/Zobrist_hashing
pub var ZOIDBERG: [781]u64 = undefined;
pub const ZOIDBERG_SEED: [4]u64 = [4]u64{ 11196532868861123662, 6132230720027805519, 14166148882366595784, 2320488099995370816 };

// These indicate which segment of the Zobrist list is used for each feature of the board.
pub const ZOID_TURN_INDEX: usize = 0;
pub const ZOID_FRENCH_START: usize = 1;
pub const ZOID_CASTLE_START: usize = 9;
pub const ZOID_PIECE_START: usize = 13;

test "do you are have random" {
    @import("common.zig").setup();
    for (ZOIDBERG) |number| {
        var count: usize = 0;
        for (ZOIDBERG) |check| {
            if (check == number) count += 1;
        }
        try @import("std").testing.expectEqual(count, 1);
    }
}
