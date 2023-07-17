// TODO: auto train against the fish to find the best settings. draw avoidence, square preference, etc.
// TODO: do I want these to be runtime configurable in the ui?

// Draws are bad if you're up material but good if you're down materal. Slight preference against because that's more fun.
pub const DRAW_EVAL = -400;

// TODO: only good if there are pawns in front of you
pub const CASTLE_REWARD: i32 = 50;

// This gets optimised out if 0.
// Otherwise, super slow! Maybe because of the branch on colour for direction?
// Must be changing how it prunes cause doing bit magic for dir() is still slow.
pub const PUSH_PAWN: i8 = 0;