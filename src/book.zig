const std = @import("std");
const Move = @import("board.zig").Move;

const SmallMove = packed struct(u12) {
    from: u6,
    to: u6,

    const NULL: SmallMove = .{ .from = 0, .to = 0 };
};

const Node = packed struct(u32) {
    move: SmallMove,
    start: u12,
    count: u8,
};

const ParseErr = error{ UnsupportedDataVersion, DeserializationFailed };

// TODO: I thought this would be more efficient than [] {hash, bestMove} that you binary search later
//       because that's 10 bytes per move where this is only 4, but I'm sure there are often more than 2.2 paths
//       to the same position in the opening so actually this is probably worse.
// A tree packed into an array so it can be directly read in from a data file without any copying.
const OpeningBook = struct {
    // Node 0 is the version number (u16) and first layer node count (u16)!
    nodes: []Node,
    rootCount: u16,

    // The OpeningBook returned is backed by the same bytes as you passed in.
    fn init(bytes: []u32) ParseErr!OpeningBook {
        if (bytes.len == 0) return error.DeserializationFailed;
        const version: u32 = bytes[0] >> 16;
        if (version > VERSION or version < MIN_VERSION) return error.UnsupportedDataVersion;
        const rootCount: u32 = (bytes[0] << 16) >> 16;
        const nodes: []Node = @ptrCast(bytes);
        for (nodes[1..]) |node| {
            if (node.start >= nodes.len) return error.DeserializationFailed;
            const last = node.start + node.count - 1;
            if (last >= nodes.len) return error.DeserializationFailed;
        }
        std.debug.print("Loaded opening book version {}. {} first moves. \n", .{ version, rootCount });
        return .{ .nodes = nodes, .rootCount = @intCast(rootCount) };
    }

    fn getRoot(self: OpeningBook) []Node {
        return self.nodes[1..(self.rootCount + 1)];
    }

    fn getChildren(self: OpeningBook, parent: Node) []Node {
        const end = parent.start + parent.count;
        return self.nodes[parent.start..end];
    }

    // Must be the same allocator as used for the bytes given to init.
    fn deinit(self: OpeningBook, alloc: std.mem.Allocator) void {
        alloc.free(self.nodes);
    }
};

const MIN_VERSION: u32 = 1;
const VERSION: u32 = 1;

// A convient tree structure for building a packed opening book data file.
const BuilderNode = struct {
    move: SmallMove,
    children: std.ArrayList(BuilderNode),

    // Copies the data. The caller still owns self and also the returned slice.
    // Not returning a []u8 because dealing with alignment checks is a pain.
    fn toBytes(self: BuilderNode, alloc: std.mem.Allocator) ![]u32 {
        var data = std.ArrayList(u32).init(alloc);
        const rootCount: u32 = @intCast(self.children.items.len);
        std.debug.assert(VERSION < (1 << 16) and rootCount < (1 << 16));
        const header: u32 = (VERSION << 16) | rootCount;
        try data.append(header);
        for (self.children.items) |child| {
            try writeNode(child, &data);
        }

        return try data.toOwnedSlice();
    }

    fn writeNode(
        self: BuilderNode,
        data: *std.ArrayList(u32),
    ) !void {
        var node: Node = .{ .move = self.move, .start = @intCast(data.items.len), .count = @intCast(self.children.items.len) };
        try data.append(@as(*u32, @ptrCast(&node)).*);
        for (self.children.items) |child| {
            try writeNode(child, data);
        }
    }

    // Should probably do this in an arena allocator so you don't have to call this method.
    fn deinit(self: BuilderNode) void {
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit();
    }
};

pub fn main() !void {}

pub fn findNextMove(moves: []Move) ?SmallMove {
    _ = moves;
}

test "serialize book" {
    var tst = std.testing.allocator;
    const original: BuilderNode = .{ .move = SmallMove.NULL, .children = std.ArrayList(BuilderNode).init(tst) };
    defer original.deinit();
    const bytes = try original.toBytes(tst);
    const parsed = try OpeningBook.init(bytes);
    parsed.deinit(tst);
}
