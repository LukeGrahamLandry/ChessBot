const std = @import("std");

const Board = @import("board.zig").Board;
const Colour = @import("board.zig").Colour;
const Piece = @import("board.zig").Piece;
const Kind = @import("board.zig").Kind;
const Move = @import("board.zig").Move;
const GameOver = @import("board.zig").GameOver;

// TODO: carefully audit any use of usize because wasm is 32 bit!
const isWasm = @import("builtin").target.isWasm();

inline fn assert(val: bool) void {
    // if (val) @panic("lol nope");
    std.debug.assert(val);
    // _ = val;
}

pub const HashAlgo = enum {
    // These all operate on the byte array of squares.
    Wyhash, // same algo as auto
    Fnv1a_64,
    XxHash64,
    Murmur2_64,
    CityHash64,
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
    beDeterministicForTest: bool = true,
    memoMapSizeMB: u64 = 100,  // Zero means don't use memo map at all. 
    hashAlgo: HashAlgo = .CityHash64,
    checkDetection: CheckAlgo = .ReverseFromKing,
    followCaptureDepth: i32 = 5,
};

pub const MoveErr = error { GameOver, OutOfMemory, ForceStop };

// TODO: script that tests different variations (compare speed and run correctness tests). 
pub fn Strategy(comptime opts: StratOpts) type {
    return struct {  // Start Strategy. 

pub const config = opts;
const useMemoMap = opts.memoMapSizeMB > 0;

// None of this is thread safe!
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

    // You can't just pick a deterministic random because pruning might end up with a shorter list of equal moves. 
    // Always choosing the first should be fine because pruning just cuts off the search early.
    // Generating random numbers is quite slow, so don't do it if theres only 1 option anyway. 
    const choice = if (opts.beDeterministicForTest or bestMoves.items.len == 1) 0 else rng.uintLessThanBiased(usize, bestMoves.items.len);
    return bestMoves.items[choice];
}

var memoMap: ?MemoTable = null;
pub var forceStop = false;

// TODO: why am I returning an array list here but a slice from possibleMoves? 
pub fn allEqualBestMoves(game: *Board, me: Colour, alloc: std.mem.Allocator) MoveErr!std.ArrayList(Move) {
    const moves = try genAllMoves.possibleMoves(game, me, alloc);
    defer alloc.free(moves);
    if (moves.len == 0) return error.GameOver;

    // No deinit because returned
    var bestMoves = try std.ArrayList(Move).initCapacity(alloc, 50);

    // TODO: I don't like that I can't init this outside. 
    // Not using the arena alloc because this persists after the move is played so work can be reused.  
    if (memoMap == null) memoMap = try MemoTable.initWithCapacity(opts.memoMapSizeMB, std.heap.page_allocator);
    var memo = &memoMap.?;
    defer memo.deinit(alloc);
    
    // TODO: use memo at top level? once it persists longer it must be helpful
    var bestVal: i32 = -1000000;
    var count: u64 = 0;
    for (moves) |move| {
        const unMove = game.play(move);
        defer game.unplay(unMove);
        if (try inCheck(game, me, alloc)) continue;
        const value = -try walkEval(game, me.other(), opts.maxDepth, opts.followCaptureDepth, -99999999, -99999999, movesArena.allocator(), &count, memo, false);  // TODO: need to catch
        if (value > bestVal) {
            bestVal = value;
            bestMoves.clearRetainingCapacity();
            try bestMoves.append(move);
        } else if (value == bestVal) {
            try bestMoves.append(move);
        }
        _ = movesArena.reset(.retain_capacity);
    }

    if (bestMoves.items.len == 0) return error.GameOver;
    return bestMoves;
}

// https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning
// The alpha-beta values effect lower layers, not higher layers, so passed by value. 
// The eval of <game>, positive means <me> is winning, assuming it is <me>'s turn. 
// Returns error.GameOver if there were no possible moves. 
pub fn walkEval(game: *Board, me: Colour, remaining: i32, bigRemaining: i32, bestWhiteEvalIn: i32, bestBlackEvalIn: i32, alloc: std.mem.Allocator, count: *u64, memo: *MemoTable, comptime capturesOnly: bool) MoveErr!i32 {
    if (forceStop) return error.ForceStop;

    // After alpha-beta, bigger starting cap, and not reallocating each move, this does make it faster. 
    // Makes Black move 4 end states go 16,000,000 -> 1,000,000
    // But now after better pruning it does almost nothing. 
    if (useMemoMap) {
        if (memo.get(game)) |cached| {
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
        const unMove = game.play(move);
        defer game.unplay(unMove);
        if (try inCheck(game, me, alloc)) continue;

        const value = if (capturesOnly and !(move.isCapture)) v: {
            // TODO: this isnt quite what I want. That move wasn't a capture but that doesn't mean that the new board is safe. 
            // The problem I'm trying to solve is if you simpleEval on a board where captures are possible, the eval will be totally different next move. 
            break :v if (me == .White) genAllMoves.simpleEval(game) else -genAllMoves.simpleEval(game); 
        } else if (remaining <= 0) v: {
            if (!capturesOnly) {
                    const val = walkEval(game, me.other(), opts.maxDepth, bigRemaining, bestWhiteEval, bestBlackEval, alloc, count, memo, true) catch |err| {
                    switch (err) {
                        error.OutOfMemory => return err,
                        error.GameOver => break :v 1234567,  // TODO: return mate in x score for the right side. just do it as like 1000000 + x. draw counts as good for the loosing side so like -301 for either so it auto perfers that if loosing by more than a piece?
                        error.ForceStop => return error.ForceStop,
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
                    error.ForceStop => return error.ForceStop,
                }
            };
            break :r -v;
        };

        if (value > bestVal) {
            bestVal = value;
            if (opts.doPruning and checkAlphaBeta(bestVal, me, &bestWhiteEval, &bestBlackEval)) break;
        }
    }

    if (useMemoMap){
        // Can never get here if forceStop=true. 
        memo.setAndOverwriteBucket(game, .{
            .eval = if (me == .White) bestVal else -bestVal,
            .remaining = remaining,
        });
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

// TODO: this could be faster if it didn't generate every possible move first
pub fn hasAnyLegalMoves(game: *Board, alloc: std.mem.Allocator) !bool {
    const moves = try genAllMoves.possibleMoves(game, game.nextPlayer, alloc);
    defer alloc.free(moves);
    if (moves.len == 0) return false;
    
    for (moves) |move| {
        const unMove = game.play(move);
        defer game.unplay(unMove);
        if (try inCheck(game, game.nextPlayer, alloc)) continue;
        break;
    } else {
        return true;
    }
    return false;
}

pub fn isGameOver(game: *Board, alloc: std.mem.Allocator) !GameOver {
    if (try hasAnyLegalMoves(game, alloc)) return .Continue;
    if (!(try inCheck(game, game.nextPlayer, alloc))) return .Stalemate;
    return if (game.nextPlayer == .White) .BlackWins else .WhiteWins;
}

pub const MemoEntry = struct {
    squares: [64] Piece,
    hash: u64,
    value: MemoValue,
};

// TODO: can I store some sort of alpha beta info here as well? try just putting the number in once I have skill testing
pub const MemoValue = struct { 
    eval: i32,
    remaining: i32
};

// Sets overwrite if their buckets collide so never have to worry about it filling up with old boards.
// That also means there's no chain of bucket collissions to follow when reading a value. 
// Allocates the full capacity up front so never needs to resize. 
pub const MemoTable = struct {
    buffer: [] MemoEntry,
    bucketMask: u64,

    pub fn initWithCapacity(comptime sizeMB: u64, alloc: std.mem.Allocator) !MemoTable {
        if (sizeMB == 0) @panic("MemoTable.initWithCapacity(0)");
        const targetCapacity: u64 = (sizeMB * 1024 * 1024) / @sizeOf(MemoEntry);
        const bits: u6 = @intCast(std.math.log2(targetCapacity));
        // WASM is 32 bit, make sure not to overflow a usize (4 GB). 
        const realCapacity = @as(usize, 1) << @min(31, bits);
        if (!std.math.isPowerOfTwo(realCapacity)) std.debug.panic("MemoTable calculated size is {}, not a power of two!", .{realCapacity});
        var self = MemoTable { .buffer = try alloc.alloc(MemoEntry, realCapacity), .bucketMask = (realCapacity-1)};
        for (0..realCapacity) |i| {
            self.buffer[i] = std.mem.zeroes(MemoEntry);
        }
        return self;
    }

    pub fn deinit(self: *MemoTable, alloc: std.mem.Allocator) void {
        alloc.free(self.buffer);
    }

    // This is relies on empty squares having a definied colour so they bytes match! TODO: test that stays true
    pub fn hash(key: *const Board) u64 {
        const data = std.mem.asBytes(&key.squares);  
        const hashcode = switch (comptime opts.hashAlgo) {
            .Wyhash => std.hash.Wyhash.hash(0, data),
            .Fnv1a_64 => std.hash.Fnv1a_64.hash(data),
            .XxHash64 => std.hash.XxHash64.hash(0, data),
            .Murmur2_64 => std.hash.Murmur2_64.hash(data),
            .CityHash64 => std.hash.CityHash64.hash(data),
        };
        assert(hashcode != 0);  // collission with my empty bucket indicator
        return hashcode;
    }

    pub fn eql(key: *const Board, entry: *MemoEntry) bool {
        return std.mem.eql(u8, std.mem.asBytes(&key.squares), std.mem.asBytes(&entry.squares));
    }

    // TODO: some heuristic for when you get to overwrite bucket? age (epoch counter) vs remaining
    pub fn setAndOverwriteBucket(self: *MemoTable, key: *const Board, value: MemoValue) void {
        const hashcode = hash(key);
        const bucket: usize = @intCast(hashcode & self.bucketMask);
        self.buffer[bucket] = .{
            .squares = key.squares,
            .hash = hashcode,
            .value = value,
        };
    }

    pub fn get(self: *MemoTable, key: *const Board) ?MemoValue {
        const hashcode = hash(key);
        const bucket: usize = @intCast(hashcode & self.bucketMask);
        if (self.buffer[bucket].hash == hashcode) {
            if (!eql(key, &self.buffer[bucket])) {
                if (!isWasm) @panic("hash collission (not a problem, just debugging)");  // TODO: does this every happen? how confident am I?
                return null;
            }
            return self.buffer[bucket].value;
        } else {
            return null;
        }
    }
};


};} // End Strategy. 

pub const default = Strategy(.{});
