const std = @import("std");
const Board = @import("board.zig").Board;
const printBitBoard = @import("movegen.zig").printBitBoard;
const print = @import("common.zig").print;

pub fn main() !void {
    const t = @import("common.zig").Timer.start();
    var general = std.heap.GeneralPurposeAllocator(.{}) {};
    _ = try makeRookAttackTable(general.allocator());
    print("Finished in {}ms\n", .{ t.get() });
}

const OneTable = std.hash_map.AutoHashMap(u64, u64);
pub const AttackTable = [64] OneTable;

pub fn makeRookAttackTable(alloc: std.mem.Allocator) !AttackTable {
    var result: AttackTable = undefined;
    var totalSize: usize = 0;
    for (0..64) |i| {
        result[i] = OneTable.init(alloc);
        const baseRookTargets = possibleRookTargets(i, 0, true);
        var blockerConfigurations = VisitBitPermutations.of(baseRookTargets);
        while (blockerConfigurations.next()) |flag| {
            const targets = possibleRookTargets(i, flag, false);
            try result[i].put(flag, targets);
        }
        const size = result[i].capacity() * @sizeOf(OneTable.KV) / 1024;
        print("{}. Capacity={}. Assumed Size={} KB\n", .{ i, result[i].capacity(), size });
        totalSize += size;
    }
    print("Total assumed size: {} KB.\n", .{ totalSize });
    return result;
}


// TODO: dont do this at comptime? min bin size goal
pub const ROOK_MASKS = makeRookUnblockedAttackMasks();

pub fn makeRookUnblockedAttackMasks() [64] u64 {
    @setEvalBranchQuota(10000);
    var result: [64] u64 = undefined;
    for (0..64) |i| {
        result[i] = possibleRookTargets(i, 0, true);
    }
    return result;
}

// TODO: make sure it doesn't help to mark all the next functions as inline. 
// TODO: use the same sort of generators for my move gen instead of collecting all moves in a list. 

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
    // If I try to include it in the struct
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

// The edge squares dont matter for the pieces mask because there's nothing more to block. 
fn possibleRookTargets(rookIndex: u64, blockerFlag: u64, comptime skipEdgeSquares: bool) u64 {
    // TODO: if (blockerFlag == 0) use bit ops to build the plus sign

    var result: u64 = 0;
    inline for (directions[0..4], 0..) |offset, dir| {
        var checkFile = @as(isize, @intCast(rookIndex % 8));
        var checkRank = @as(isize, @intCast(rookIndex / 8));
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

const directions = [8] [2] isize {
    [2] isize { 1, 0 },
    [2] isize { -1, 0 },
    [2] isize { 0, 1 },
    [2] isize { 0, -1 },
    [2] isize { 1, 1 },
    [2] isize { 1, -1 },
    [2] isize { -1, 1 },
    [2] isize { -1, -1 },
};
