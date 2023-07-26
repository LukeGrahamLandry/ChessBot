const std = @import("std");
const Board = @import("board.zig").Board;
const printBitBoard = @import("movegen.zig").printBitBoard;
const print = @import("common.zig").print;
const isWasm = @import("builtin").target.isWasm();
const Learned = @import("learned.zig");

pub var tables: Tables = undefined;

pub fn initTables(alloc: std.mem.Allocator) !void {
    tables = .{
        .rooks = try makeSliderAttackTable(alloc, possibleRookTargets, Learned.ROOK_SIZES, Learned.ROOK_HASH_MUL),
        .bishops = try makeSliderAttackTable(alloc, possibleBishopTargets, Learned.BISHOP_SIZES, Learned.BISHOP_HASH_MUL),
    };
}

const Tables = struct {
    rooks: AttackTable,
    bishops: AttackTable,
    // These are done at comptime because they dont need to allocate and the data is smaller than the code to generate it. 
    rookMasks: [64] u64 = makeSliderUnblockedAttackMasks(possibleRookTargets),
    knights: [64] u64 = makeKnightAttackTable(), 
    bishopMasks: [64] u64 = makeSliderUnblockedAttackMasks(possibleBishopTargets),
    kings: [64] u64 = makeKingAttackTable(), 
};

// Use the hardcoded java primes to build an attack table. 
// Doesn't need to try increasing table sizes because the correct size for no collissions given that hasher is precalculated. 
fn makeSliderAttackTable(alloc: std.mem.Allocator, comptime possibleTargets: fn (u64, u64, comptime bool) u64, sizes: [64] u7, magic: [64] u64) !AttackTable {
    var result: AttackTable = undefined;
    var totalSize: usize = 0;
    for (0..64) |i| {
        result[i] = (try fillSliderTable(i, magic[i], sizes[i], alloc, possibleTargets)).?;
        totalSize += result[i].buffer.len * @sizeOf(u64) / 1024;
    }
    print("Slider attack table size: {} KB.\n", .{ totalSize });
    return result;
}

pub fn main() !void {
    _ = try initTables(std.heap.page_allocator);
    try findBetterSliderAttackTable(std.heap.page_allocator, Learned.ROOK_SIZES, Learned.ROOK_HASH_MUL, possibleRookTargets, "ROOK");
    try findBetterSliderAttackTable(std.heap.page_allocator, Learned.BISHOP_SIZES, Learned.BISHOP_HASH_MUL, possibleBishopTargets, "BISHOP");
}

// TODO: same thing for zoidberg
// Since the attack table for each square has different sizes and different mask bits of the keys they care about (the unblocked targets), 
// it seems like maybe they would have different best numbers for the hash function avoiding collissions. 
// If it finds any improvements, it logs them so I can update the hardcoded ones going forward. 
// Started by using GOLDEN_RATIO = 11400714819323198485 for everything because I read: 
// https://probablydance.com/2018/06/16/fibonacci-hashing-the-optimization-that-the-world-forgot-or-a-better-alternative-to-integer-modulo/
fn findBetterSliderAttackTable(alloc: std.mem.Allocator, oldSizes: [64] u7, oldMagic: [64] u64, comptime possibleTargets: fn (u64, u64, comptime bool) u64, comptime name: [] const u8) !void {
    var magic = oldMagic;
    var sizes = oldSizes;
    var totalSize: usize = 0;
    _ = totalSize;
    var foundAny = false;
    
    var seed: u64 = undefined;
    try std.os.getrandom(std.mem.asBytes(&seed));
    var rng = std.rand.DefaultPrng.init(seed);

    var arena = std.heap.ArenaAllocator.init(alloc);
    for (0..10000) |_| {
        // Higher bits is exponentially more memory so always work on improving the worst table. 
        const i = maxIndex(u7, &sizes);
        const newMagic = rng.next();

        // See how good this number is. Don't care if its just equal to the old one. 
        var bits: u7 = sizes[i] - 1;
        while (bits > 1) {
            if (try fillSliderTable(i, newMagic, bits, arena.allocator(), possibleTargets)) |table| {
                _ = table;
                // Save it if its better than the old one. 
                magic[i] = newMagic;
                sizes[i] = bits;
                foundAny = true;
                // See if its actually even better than that and allows a smaller table. 
                bits -= 1;
                _ = arena.reset(.retain_capacity);
            } else {
                break;
            }
        }
    }

    arena.deinit();

    if (foundAny) {
        print("pub const " ++ name ++ "_HASH_MUL = [64] u64 {{", .{});
        for (magic, 0..) |x, i| {
            print(" {}", .{ x });
            if (i != 63) print(",", .{});
        }
        print(" }};\n", .{});
        print("pub const " ++ name ++ "_SIZES = [64] u7 {{", .{});
        for (sizes, 0..) |x, i| {
            print(" {}", .{ x });
            if (i != 63) print(",", .{});
        }
        print(" }};\n", .{});
    } else {
        print("Didn't find anything good.\n", .{});
    }
    
}

fn maxIndex(comptime T: type, items: [] T) usize {
    var max: usize = 0;
    for (1..items.len) |i| {
        if (items[i] > items[max]) max = i;
    }
    return max;
}

fn fillSliderTable(sqI: usize, magic: u64, bits: u7, alloc: std.mem.Allocator, comptime possibleTargets: fn (u64, u64, comptime bool) u64) !?OneTable {
    if (bits > 20) @panic("bits too big");

    var result = try OneTable.init(alloc, bits, magic);
    const baseTargets = possibleTargets(sqI, 0, true);
    var blockerConfigurations = VisitBitPermutations.of(baseTargets);
    while (blockerConfigurations.next()) |flag| {
        const targets = possibleTargets(sqI, flag, false);
        const success = result.set(flag, targets);
        if (!success) {
            alloc.free(result.buffer);
            return null;
        }
    }
    return result;
}

fn makeKnightAttackTable() [64] u64 {
    @setEvalBranchQuota(10000);
    var result: [64] u64 = undefined;
    for (0..64) |i| {
        result[i] = possibleKnightTargets(i);
    }
    return result;
}

fn makeSliderUnblockedAttackMasks(comptime possibleTargets: fn (u64, u64, comptime bool) u64) [64] u64 {
    @setEvalBranchQuota(10000);
    var result: [64] u64 = undefined;
    for (0..64) |i| {
        result[i] = possibleTargets(i, 0, true);
    }
    return result;
}

fn makeKingAttackTable() [64] u64 {
    @setEvalBranchQuota(10000);
    var result: [64] u64 = undefined;
    for (0..64) |i| {
        result[i] = possibleKingTargets(i);
    }
    return result;
}

pub fn ff(r: usize, f: usize) u64 {
    return @as(u64, 1) << (@as(u6, @intCast(r * 8)) + @as(u6, @intCast(f)));
}

// TODO: can i do this with bit ops?
fn possibleKingTargets(i: usize) u64 {
    var result: u64 = 0;
    const rank = i / 8;
    const file = i % 8;

    // forward
    if (file < 7) {
        result |= ff(rank, file + 1);
        if (rank < 7) result |= ff(rank + 1, file + 1);
        if (rank > 0) result |= ff(rank - 1, file + 1);
    }
    // back
    if (file > 0) {
        result |= ff(rank, file - 1);
        if (rank < 7) result |= ff(rank + 1, file - 1);
        if (rank > 0 ) result |= ff(rank - 1, file - 1);
    }
    // horizontal
    if (rank < 7) result |= ff(rank + 1, file);
    if (rank > 0) result |= ff(rank - 1, file);

    return result;
}

/// Yield once for each 1 bit in n passing an int with only that bit set. 
/// ie. n=(all ones) would yield with each power of 2 (64 times total).
const VisitEachSetBit = struct {
    remaining: u64,
    offset: u7,

    pub const NONE: @This() = .{ .remaining=0, .offset=64 };

    pub fn of(n: u64) @This() {
        return .{ .remaining=n, .offset=@ctz(n) };
    }

    pub fn next(self: *@This()) ?u64 {
        if (self.offset < 64) {
            var flag = @as(u64, 1) << @intCast(self.offset);
            self.remaining = self.remaining ^ flag;
            self.offset = @ctz(self.remaining);
            return flag;
        } else {
            return null;
        }
    }
};

/// Yield once for each combination of set bits in n.
/// ie. n=(all ones) would yield each possible 64 bit number. 
// fn permute(n: u64) void {
//     if (n == 0) return 0;
//     var bits = VisitEachSetBit.of(n);
//     while (bits.next()) |flag| {
//         const others = permute(n & ~flag);  // permute the numbers without this bit set
//         for (others) |part| {
//             return part | flag;  // every option with the bit
//             return part;  // every option without the bit
//         }
//     }
// }
const VisitBitPermutations = struct {
    // This needs to live in the caller's stack space. 
    others: [65] Inner = undefined,
    ready: bool = false,
    expected: u64,
    count: u64 = 0,

    pub fn getPinned() [65] Inner {
        return undefined;
    }

    pub fn of(n: u64) @This() {
        var self: @This() =  .{ .expected=(std.math.powi(usize, 2, @popCount(n)) catch unreachable), };
        for (&self.others) |*o| {
            o.end = .{};
            o.bits = VisitEachSetBit.NONE;
        }
        Inner.init(n, &self.others, 0);
        return self;
    }

    pub fn next(self: *@This()) ?u64 {
        if (!self.ready) {
            self.others[0].others = &self.others;  // The adress will have changed when of() returned. 
            self.ready = true;
        }

        // TODO: why doesnt it know when to stop!!!!!
        if (self.count == self.expected) return null;
        self.count += 1;

        return self.others[0].next();
    }

    const ZeroOnce = struct {
        done: bool = false,
        pub fn next(self: *@This()) ?u64 {
            if (self.done) return null;
            self.done = true;
            return 0;
        }
    };

    const Inner = struct {
        n: u64,
        bits: VisitEachSetBit,
        others: [] Inner,
        depth: usize,
        yielded: u2,
        part: u64 = undefined,
        flag: u64 = undefined,
        end: ZeroOnce = .{},

        pub fn init(n: u64, others: [] Inner, depth: usize) void {
            if (depth > 64) @panic("depth>64");
            others[depth] = .{
                .n=n,
                .bits=VisitEachSetBit.of(n),
                .others=others,
                .depth=depth,
                .yielded = 3,
                .end = others[depth].end,
            };
            // D
        }

        pub fn next(self: *@This()) ?u64 {
            if (self.n == 0) return self.end.next();

            switch (self.yielded) {
                0 => {  // A
                    // print("A: {}\n", .{ self.depth });
                    self.yielded = 1;
                    return self.part | self.flag;
                },
                1 => {  // B
                    // print("B: {}\n", .{ self.depth });
                    self.yielded = 2;
                    return self.part;
                },
                2 => {
                    // print("C: {}\n", .{ self.depth });
                    if (self.others[self.depth + 1].next()) |nextPart| { // C
                        self.yielded = 0;
                        self.part = nextPart;
                        return self.next(); // A
                    } else {  
                        self.yielded = 3;
                        return self.next(); // D
                    }
                },
                3 => {  // D
                    // print("D: {}\n", .{ self.depth });
                    if (self.bits.next()) |nextFlag| { 
                        self.flag = nextFlag;
                        Inner.init(self.n & ~nextFlag, self.others, self.depth + 1);
                        self.yielded = 2;
                        return self.next(); // C
                    }
                    return null;
                },
            }
        }
    };
};

test "permutations generate unique numbers" {
    for (0..64) |i| {
        const b = possibleRookTargets(i, 0, true);
        var permute = VisitBitPermutations.of(b);
        var last: u64 = b + 1;
        const illegal = ~b;
        while (permute.next()) |flag| {
            // Make sure all the bits are within the original input. 
            try std.testing.expect((flag & illegal) == 0);

            // This relies on VisitBitPermutations generating in decending order.
            // If the new one is always strictly less than the last one then they must be unique. 
            try std.testing.expect(flag < last);
            last = flag;
        }
    }
}

fn possibleRookTargets(rookIndex: u64, blockerFlag: u64, comptime skipEdgeSquares: bool) u64 {
    // TODO: if (blockerFlag == 0) use bit ops to build the plus sign
    return possibleSlideTargets(rookIndex, blockerFlag, skipEdgeSquares, allDirections[0..4]);
}

fn possibleBishopTargets(rookIndex: u64, blockerFlag: u64, comptime skipEdgeSquares: bool) u64 {
    return possibleSlideTargets(rookIndex, blockerFlag, skipEdgeSquares, allDirections[4..8]);
}

// The edge squares dont matter for the pieces mask because there's nothing more to block. 
fn possibleSlideTargets(startIndex: u64, blockerFlag: u64, comptime skipEdgeSquares: bool, comptime directions: [] const [2] isize) u64 {
    var result: u64 = 0;
    inline for (directions, 0..) |offset, dir| {
        var checkFile = @as(isize, @intCast(startIndex % 8));
        var checkRank = @as(isize, @intCast(startIndex / 8));
        while (true) {
            checkFile += offset[0];
            checkRank += offset[1];
            if (skipEdgeSquares) {
                if (dir >= 2 and (checkRank > 6 or checkRank < 1)) break;
                if (dir < 2 and (checkFile > 6 or checkFile < 1)) break;
            } 
            if (checkFile > 7 or checkRank > 7 or checkFile < 0 or checkRank < 0) break;

            const toFlag = @as(u64, 1) << @intCast(checkRank*8 + checkFile);
            result |= toFlag;
            if ((toFlag & blockerFlag) != 0) break;
        }
    }
    return result;
}

test "unblocked rooks can move 14 squares" {
    for (0..64) |i| {
        const b = possibleRookTargets(i, 0, false);
        try std.testing.expectEqual(@popCount(b), 14);
    }

    for (0..64) |i| {
        const file = i % 8;
        const rank = i / 8;
        var edgeCount: u7 = 4;
        if (file == 0 or file == 7) edgeCount -= 1;
        if (rank == 0 or rank == 7) edgeCount -= 1;
        var expect = 14 - edgeCount;

        const b = possibleRookTargets(i, 0, true);
        try std.testing.expectEqual(expect, @popCount(b));
    }
}

const allDirections = [8] [2] isize {
    [2] isize { 1, 0 },
    [2] isize { -1, 0 },
    [2] isize { 0, 1 },
    [2] isize { 0, -1 },
    [2] isize { 1, 1 },
    [2] isize { 1, -1 },
    [2] isize { -1, 1 },
    [2] isize { -1, -1 },
};

fn possibleKnightTargets(i: u64) u64 {
    const knightOffsets = [4] isize { 1, -1, 2, -2 };

    var result: u64 = 0;
    inline for (knightOffsets) |x| {
        inline for (knightOffsets) |y| {
            if (x != y and x != -y) {
                var checkFile = @as(isize, @intCast(i % 8)) + x;
                var checkRank = @as(isize, @intCast(i / 8)) + y;
                const invalid = checkFile > 7 or checkRank > 7 or checkFile < 0 or checkRank < 0;
                if (!invalid) result |= @as(u64, 1) << @intCast(checkRank*8 + checkFile);
            }
        }
    }

    return result;
}

test "have less than 9 moves" {
    for (0..64) |i| {
        const b = possibleKnightTargets(i);
        try std.testing.expect(@popCount(b) <= 8);
    }
}

pub const AttackTable = [64] OneTable;

pub const OneTable = struct {
    buffer: []u64,
    bitsInv: u7,
    magic: u64,
    const EMPTY: u64 = ~@as(u64, 0);

    pub fn init(alloc: std.mem.Allocator, bits: u7, magic: u64) !@This() {
        return .{ .bitsInv=64-bits, .buffer = try allocOnes(alloc, bits), .magic=magic};
    }

    fn allocOnes(alloc: std.mem.Allocator, bits: u7) ![]u64 {
        var buffer = try alloc.alloc(u64, try std.math.powi(usize, 2, bits));
        for (buffer) |*e| {
            e.* = EMPTY;
        }
        return buffer;
    }

    // Returns false on collission. 
    fn set(self: *@This(), key: u64, value: u64) bool {
        const prevVal = self.get(key);
        if (prevVal != EMPTY and prevVal != value) return false;
        self.buffer[self.indexOf(key)] = value;
        return true;
    }

    fn indexOf(self: *const @This(), key: u64) usize {
        var hash: u128 = key;
        hash ^= hash >> self.bitsInv;
        const all: u64 = @truncate(self.magic * hash);
        const index = all >> @intCast(self.bitsInv);
        // print("{b} -> {b} -> {b}\n", .{key, all, index});
        return @intCast(index);
    }
    
    pub fn get(self: *const @This(), key: u64) u64 {
        return self.buffer[self.indexOf(key)];
    }
};
