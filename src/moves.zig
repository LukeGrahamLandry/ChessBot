const std = @import("std");

const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;

const MoveErr = error { GameOver, OutOfMemory };
const isWasm = @import("builtin").target.isWasm();

fn assert(val: bool) void {
    // if (val) @panic("lol nope");
    std.debug.assert(val);
    // _ = val;
}

// Today we learn this language sucks ass and gives you random garbage numbers if this is not 'packed' but only in release mode,
// you'll never guess whether that breaks it in debug mode, but padding it out to two bytes works in both.
pub const CastleMove = packed struct { rookFrom: u6, rookTo: u6, fuck: u4 = 0 };

// TODO: this seems much too big (8 bytes?). castling info is redunant cause other side can infer if king moves 2 squares, bool field is evil and redundant
pub const Move = struct {
    from: u6,
    to: u6,
    isCapture: bool,
    action: union(enum) {
        none,
        promote: Kind,
        castle: CastleMove,
    },

    // TODO: method that factors out bounds check from try methods then calls this? make sure not to do twice in slide loops.
    pub fn irf(fromIndex: usize, toFile: usize, toRank: usize, isCapture: bool) Move {
        // std.debug.assert(fromIndex < 64 and toFile < 8 and toRank < 8);
        return .{
            .from=@intCast(fromIndex),
            .to = @intCast(toRank*8 + toFile),
            .action = .none,
            .isCapture=isCapture
        };
    }

    pub fn ii(fromIndex: u6, toIndex: u6, isCapture: bool) Move {
        return .{
            .from=fromIndex,
            .to = toIndex,
            .action = .none,
            .isCapture=isCapture
        };
    }
};

pub const HashAlgo = enum {
    // These all operate on the byte array of squares.
    Wyhash, // same algo as auto
    Fnv1a_64,
    XxHash64,
    Murmur2_64,
    CityHash64,
    // Slower because it does individual struct parts?
    StdAuto,
};

pub const CheckAlgo = enum {
    Ignore, ReverseFromKing, LookAhead
};

var notTheRng = std.rand.DefaultPrng.init(0);
var rng = notTheRng.random();

const movegen = @import("movegen.zig");
pub const genCapturesOnly = movegen.MoveFilter.CapturesOnly.get();
pub const genAllMoves = movegen.MoveFilter.Any.get();

pub const StratOpts = struct {
    maxDepth: comptime_int = 3,  // TODO: should be runtime param to bestMove so wasm can change without increasing code size. 
    doPruning: bool = true, 
    beDeterministicForTest: bool = true,  // Interesting that it's much faster with this =true. Rng is slow!
    memoMapSizeMB: usize = 20,  // Zero means don't use memo map at all. 
    memoMapFillPercent: usize = 60,  // Affects usable map capacity but not memory usage. 
    hashAlgo: HashAlgo = .CityHash64,
    checkDetection: CheckAlgo = .ReverseFromKing,
    followCaptureDepth: i32 = 5,
};

// TODO: script that tests different variations (compare speed and run correctness tests). 
pub fn Strategy(comptime opts: StratOpts) type {
    return struct {  // Start Strategy. 

pub const config = opts;
comptime { 
    assert(@sizeOf(Piece) == @sizeOf(u8)); 
    assert(opts.memoMapFillPercent <= 100);
}

// TODO: dont store extra fields, just squares
// This is relies on empty squares having a definied colour so they bytes match! TODO: test that stays true
pub const MemoMap = std.HashMap(Board, struct {
    eval: i32,
    remaining: i32
}, struct {
    // TODO: don't include padding bytes, try Zobrist. 
    pub fn hash(ctx: @This(), key: Board) u64 {
        const data = std.mem.asBytes(&key.squares);  
        return switch (comptime opts.hashAlgo) {
            .StdAuto => (comptime std.hash_map.getAutoHashFn(Board, @This()))(ctx, key), 
            .Wyhash => std.hash.Wyhash.hash(0, data),
            .Fnv1a_64 => std.hash.Fnv1a_64.hash(data),
            .XxHash64 => std.hash.XxHash64.hash(0, data),
            .Murmur2_64 => std.hash.Murmur2_64.hash(data),
            .CityHash64 => std.hash.CityHash64.hash(data),
        };
    }
    
    pub fn eql(_: @This(), a: Board, b: Board) bool {
        return std.mem.eql(u8, std.mem.asBytes(&a.squares), std.mem.asBytes(&b.squares));
    }
}, opts.memoMapFillPercent);  

const useMemoMap = opts.memoMapSizeMB > 0 and opts.memoMapFillPercent > 0;
// TODO: this wont be exact because capacity goes to the next highest power of two. 
const MEMO_CAPACITY = if (useMemoMap) (opts.memoMapSizeMB * 1024 * 1024) / @sizeOf(MemoMap.KV) * 100 / opts.memoMapFillPercent else 0;

// This gets reset after each whole decision is done.
var upperArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
// This gets reset after checking each top level move. 
var movesArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const genKingCapturesOnly = @import("movegen.zig").MoveFilter.KingCapturesOnly.get();
const one: u64 = 1;
pub fn inCheck(game: *Board, me: Colour, alloc: std.mem.Allocator) !bool {
    switch (opts.checkDetection) {
        .Ignore => return false,
        .LookAhead => {
            const moves = try genKingCapturesOnly.possibleMoves(game, me.other(), alloc);
            defer alloc.free(moves);
            return moves.len > 0;
        },
        .ReverseFromKing => {
            return try movegen.reverseFromKingIsInCheck(game, me);
        }
    }
}

// This has its own loop because I actually need to know which move is best which walkEval doesn't return. 
// Also means I can reset the temp allocator more often. 
pub fn bestMove(game: *Board, me: Colour) !Move {
    var alloc = upperArena.allocator();
    defer assert(upperArena.reset(.retain_capacity));
    const bestMoves = try allEqualBestMoves(game, me, alloc);
    defer bestMoves.deinit();

    // assert(bestMoves.items.len > 0 and bestMoves.items.len <= moves.len);
    // You can't just pick a deterministic random because pruning might end up with a shorter list of equal moves. 
    // Always choosing the first should be fine because pruning just cuts off the search early.
    // Generating random numbers is quite slow, so don't do it if theres only 1 option anyway. 
    const choice = if (opts.beDeterministicForTest or bestMoves.items.len == 1) 0 else rng.uintLessThanBiased(usize, bestMoves.items.len);
    return bestMoves.items[choice];
}

pub fn allEqualBestMoves(game: *Board, me: Colour, alloc: std.mem.Allocator) !std.ArrayList(Move) {
    const moves = try genAllMoves.possibleMoves(game, me, alloc);
    defer alloc.free(moves);
    if (moves.len == 0) return error.GameOver;

    // No deinit because returned
    var bestMoves = try std.ArrayList(Move).initCapacity(alloc, 50);

    var memo = MemoMap.init(alloc);
    if (useMemoMap) try memo.ensureTotalCapacity(MEMO_CAPACITY);
    defer memo.deinit();
    
    // TODO: use memo at top level? once it persists longer it must be helpful
    var bestVal: i32 = -1000000;
    var count: u64 = 0;
    for (moves) |move| {
        const unMove = try game.play(move);
        defer game.unplay(unMove);
        if (try inCheck(game, me, alloc)) continue;
        const value = -try walkEval(game, me.other(), opts.maxDepth, opts.followCaptureDepth, -99999999, -99999999, movesArena.allocator(), &count, &memo, false);  // TODO: need to catch
        if (value > bestVal) {
            bestVal = value;
            bestMoves.clearRetainingCapacity();
            try bestMoves.append(move);
        } else if (value == bestVal) {
            try bestMoves.append(move);
        }
        assert(movesArena.reset(.retain_capacity));
    }

    return bestMoves;
}

// https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning
// TODO: when hit depth, keep going but only look at captures
// The alpha-beta values effect lower layers, not higher layers, so passed by value. 
// The eval of <game>, positive means <me> is winning, assuming it is <me>'s turn. 
pub fn walkEval(game: *Board, me: Colour, remaining: i32, bigRemaining: i32, bestWhiteEvalIn: i32, bestBlackEvalIn: i32, alloc: std.mem.Allocator, count: *u64, memo: *MemoMap, comptime capturesOnly: bool) MoveErr!i32 {
    // After alpha-beta, bigger starting cap, and not reallocating each move, this does make it faster. 
    // Makes Black move 4 end states go 16,000,000 -> 1,000,000
    // But now after better pruning it does almost nothing. 
    if (useMemoMap) {
        if (memo.get(game.*)) |cached| {
            if (cached.remaining >= remaining){
                return if (me == .White) cached.eval else -cached.eval;
            }
            // TODO: should save the best move from that position at the old low depth and use it as the start for the search 
        }
    }

    // Want to mutate values from parameters. 
    var bestWhiteEval = bestWhiteEvalIn;
    var bestBlackEval = bestBlackEvalIn;

    const moveGen = genAllMoves;
    const moves = try moveGen.possibleMoves(game, me, alloc);
    defer alloc.free(moves);
    if (moves.len == 0) return error.GameOver;
    
    var bestVal: i32 = -1000000;
    for (moves) |move| {
        const unMove = try game.play(move);
        defer game.unplay(unMove);
        if (try inCheck(game, me, alloc)) continue;

        const value = if (capturesOnly and !move.isCapture) v: {
            // TODO: this isnt quite what I want. That move wasn't a capture but that doesn't mean that the new board is safe. 
            // The problem I'm trying to solve is if you simpleEval on a board where captures are possible, the eval will be totally different next move. 
            break :v if (me == .White) genAllMoves.simpleEval(game) else -genAllMoves.simpleEval(game); 
        } else if (remaining <= 0) v: {
            if (!capturesOnly) {
                    const val = walkEval(game, me.other(), opts.maxDepth, bigRemaining, bestWhiteEval, bestBlackEval, alloc, count, memo, true) catch |err| {
                    switch (err) {
                        error.OutOfMemory => return err,
                        error.GameOver => break :v 1234567,
                    }
                };
                break :v -val;
            }
            break :v if (me == .White) genAllMoves.simpleEval(game) else -genAllMoves.simpleEval(game); 
        } else r: {
            const v = walkEval(game, me.other(), remaining - 1, bigRemaining, bestWhiteEval, bestBlackEval, alloc, count, memo, capturesOnly) catch |err| {
                switch (err) {
                    error.OutOfMemory => return err,
                    error.GameOver => break :r 1234567,
                }
            };
            break :r -v;
        };

        if (value > bestVal) {
            bestVal = value;
            if (opts.doPruning and checkAlphaBeta(bestVal, me, &bestWhiteEval, &bestBlackEval)) break;
        }
    }

    // TODO: I want to not reset the table between moves but then when it runs out of space it would be full of positions we don't need anymore.
    //       need to get rid of old ones somehow. maybe my own hash map that just overwrites on collissions? 
    // Don't need to check `and memo.capacity() > MEMO_CAPACITY` because we allocate the desired capacity up front.
    if (useMemoMap){
        const memoFull = memo.unmanaged.available == 0;
        if (!memoFull) {
            try memo.put(game.*, .{
                .eval = if (me == .White) bestVal else -bestVal,
                .remaining = remaining,
            });
        }
    }
    
    return bestVal;
}

// This is in it's own function because it's used in the special upper loop and the walkEval. 
/// Returns true if the move is so good we should stop considering this branch. 
fn checkAlphaBeta(bestVal: i32, me: Colour, bestWhiteEval: *i32, bestBlackEval: *i32) bool {
    switch (me) {
        .White => {
            bestWhiteEval.* = @max(bestWhiteEval.*, bestVal);
            if (bestVal >= -bestBlackEval.*) {
                return true;
            }
        },
        .Black => {
            bestBlackEval.* = @max(bestBlackEval.*, bestVal);
            if (bestVal >= -bestWhiteEval.*) {
                return true;
            }
        }
    }
    return false;
}

};} // End Strategy. 

pub const default = Strategy(.{});
