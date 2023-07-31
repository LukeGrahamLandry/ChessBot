const std = @import("std");
pub const isWasm = @import("builtin").target.isWasm();
pub const isTest = @import("builtin").is_test;

pub const print = if (isWasm) @import("web.zig").consolePrint else std.debug.print;
pub const panic = if (isWasm) @import("web.zig").webPanic else std.debug.panic;
pub const assert = std.debug.assert;

const ListPool = @import("movegen.zig").ListPool;
const Learned = @import("learned.zig");
const SearchGlobals = @import("search.zig").SearchGlobals;

var alloc = if (isWasm) std.heap.wasm_allocator else std.heap.c_allocator;

// TODO: I like the idea of all memory allocation happening here and nobody else ever having an allocator.
pub fn setup(memoSizeMB: usize) SearchGlobals {
    initZoidberg();
    @import("precalc.zig").initTables(alloc) catch panic("OOM attack tables", .{});
    return SearchGlobals.init(memoSizeMB, alloc) catch panic("OOM memo", .{});
}

const getRawIndex = @import("board.zig").getRawIndex;

fn initZoidberg() void {
    var rand: std.rand.Xoshiro256 = .{ .s = Learned.ZOIDBERG_SEED };
    for (&Learned.ZOIDBERG) |*ptr| {
        ptr.* = rand.next();
    }

    // I want empty squares to be 0 because I don't trust that I rigorously track adds/removes of them.
    // Don't need this because I never call it with empty anyway because that would mess up the bitboards but doesn't hurt.
    for (0..64) |i| {
        Learned.ZOIDBERG[Learned.ZOID_PIECE_START + getRawIndex(.{ .kind = .Empty, .colour = .White }, @intCast(i))] = 0;
        Learned.ZOIDBERG[Learned.ZOID_PIECE_START + getRawIndex(.{ .kind = .Empty, .colour = .Black }, @intCast(i))] = 0;
    }
}


pub fn nanoTimestamp() i128 {
    if (comptime isWasm) {
        return @as(i128, @intFromFloat(@import("web.zig").jsPerformaceNow())) * std.time.ns_per_ms;
    } else {
        return std.time.nanoTimestamp();
    }
}

pub const Timer = struct {
    t: i128,

    pub fn start() Timer {
        return .{ .t = nanoTimestamp() };
    }

    pub fn get(self: Timer) i128 {
        return @divFloor((nanoTimestamp() - self.t), @as(i128, std.time.ns_per_ms));
    }
};
