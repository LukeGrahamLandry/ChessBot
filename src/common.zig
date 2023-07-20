const std = @import("std");
const Magic = @import("magic.zig");
pub const isWasm = @import("builtin").target.isWasm();
pub const isTest = @import("builtin").is_test;

pub const print = if (isWasm) @import("web.zig").consolePrint else std.debug.print;
pub const panic = if (isWasm) @import("web.zig").alertPrint else std.debug.panic;
pub const assert = std.debug.assert;

fn noPrint(comptime fmt: []const u8, args: anytype) void {
    _ = args;
    _ = fmt;
}

// TODO: do memo table here as well // memoTableMB: u64
pub fn setup() void {
    if (!isTest) print("Zobrist Xoshiro256 seed is {any}.\n", .{Magic.ZOIDBERG_SEED});
    var rand: std.rand.Xoshiro256 = .{ .s = Magic.ZOIDBERG_SEED };
    for (&Magic.ZOIDBERG) |*ptr| {
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
        return .{ .t = std.time.nanoTimestamp() };
    }

    pub fn get(self: Timer) i128 {
        return @divFloor((std.time.nanoTimestamp() - self.t), @as(i128, std.time.ns_per_ms));
    }
};
