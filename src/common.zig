const std = @import("std");
pub const isWasm = @import("builtin").target.isWasm();
pub const isTest = @import("builtin").is_test;

pub const print = if (isWasm) @import("web.zig").consolePrint else std.debug.print;
pub const panic = if (isWasm) @import("web.zig").webPanic else std.debug.panic;
pub const assert = std.debug.assert;

const ListPool = @import("movegen.zig").ListPool;
const Learned = @import("learned.zig");
const SearchGlobals = @import("search.zig").SearchGlobals;

var general_i = std.heap.GeneralPurposeAllocator(.{}) {};

// TODO: I like the idea of all memory allocation happening here and nobody else ever having an allocator. 
pub fn setup(memoSizeMB: usize) SearchGlobals {
    initZoidberg();
    @import("precalc.zig").initTables(general_i.allocator()) catch panic("OOM attack tables", .{});
    return SearchGlobals.init(memoSizeMB, general_i.allocator()) catch panic("OOM memo", .{});
}

pub fn initZoidberg() void {
    var rand: std.rand.Xoshiro256 = .{ .s = Learned.ZOIDBERG_SEED };
    for (&Learned.ZOIDBERG) |*ptr| {
        ptr.* = rand.next();
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
