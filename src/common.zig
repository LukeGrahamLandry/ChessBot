const std = @import("std");
pub const isWasm = @import("builtin").target.isWasm();
pub const isTest = @import("builtin").is_test;

pub const print = if (isWasm) @import("web.zig").consolePrint else std.debug.print;
pub const panic = if (isWasm) @import("web.zig").webPanic else std.debug.panic;
pub const assert = std.debug.assert;

const ListPool = @import("movegen.zig").ListPool;
const Learned = @import("learned.zig");

// TODO: Having the magic global variable is awkward. Could pass around a magic search context struct that includes the memo map as well. 
//       I can't decide if I like the simplicity of global variables when there's only one instance anyway or if explicitly passing it to people is more clear. 
//       Return it from setup so you can't forget to call. 
var general_i = std.heap.GeneralPurposeAllocator(.{}) {};
pub var lists: ListPool = undefined;

pub fn setup(memoSizeMB: usize) void {
    // var t = Timer.start();
    if (!isTest) print("Zobrist Xoshiro256 seed is {any}.\n", .{Learned.ZOIDBERG_SEED});
    var rand: std.rand.Xoshiro256 = .{ .s = Learned.ZOIDBERG_SEED };
    for (&Learned.ZOIDBERG) |*ptr| {
        ptr.* = rand.next();
    }

    lists = ListPool.init(general_i.allocator()) catch panic("OOM list pool", .{});
    @import("search.zig").initMemoTable(memoSizeMB) catch panic("OOM memo", .{});
    @import("precalc.zig").initTables(general_i.allocator()) catch panic("OOM attack tables", .{});
    // print("Setup finished in {} ms.\n", .{t.get()});
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
        return .{ .t = std.time.nanoTimestamp() };
    }

    pub fn get(self: Timer) i128 {
        return @divFloor((std.time.nanoTimestamp() - self.t), @as(i128, std.time.ns_per_ms));
    }
};
