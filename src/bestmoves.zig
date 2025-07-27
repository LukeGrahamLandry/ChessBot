//! Test the search against the positions in bestmoves.txt
//! It's only passing ~70% rn but will catch dumb mistakes.

const std = @import("std");
const Board = @import("board.zig").Board;
const Move = @import("board.zig").Move;
const Colour = @import("board.zig").Colour;
const search = @import("search.zig");
const Timer = @import("common.zig").Timer;
const GameOver = @import("board.zig").GameOver;
const Learned = @import("learned.zig");
const assert = @import("common.zig").assert;
const print = @import("common.zig").print;
const panic = @import("common.zig").panic;
const UCI = @import("uci.zig");
const Stockfish = @import("fish.zig").Stockfish;
const movegen = @import("movegen.zig");
const PerftResult = @import("tests.zig").PerftResult;
const ListPool = @import("movegen.zig").ListPool;
const parsePgnMove = @import("book.zig").parsePgnMove;

const MAX_DEPTH = 10;
const TIME_LIMIT = 2000;
const CORES = 5; // Threads work on different tests so more cores makes it finish faster but doesn't make it play better.
const positionData = @embedFile("bestmoves.txt");

// For things I don't care about freeing.
var foreverArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var forever = foreverArena.allocator();

const Shared = std.atomic.Value(usize);

pub fn main() !void {
    _ = @import("common.zig").setup(0);
    var lists = try ListPool.init(forever);
    const tasks = (try parsePositions(&lists)).items;
    var taskIndex = Shared.init(0);
    var workers = try forever.alloc(Worker, CORES);
    for (0..CORES) |i| {
        workers[i] = .{
            .id = i,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .ctx = @import("common.zig").setup(100),
            .thread = try std.Thread.spawn(.{}, workerFn, .{&workers[i]}),
            .nextTask = &taskIndex,
            .tasks = tasks,
        };
    }

    for (workers) |worker| {
        worker.thread.join();
    }

    const endTime = std.time.nanoTimestamp();
    var failed: u64 = 0;
    for (workers) |worker| {
        print("{}ms, ", .{@divFloor(endTime - worker.endTime, std.time.ns_per_ms)});
        failed += worker.failedCount;
    }
    print("; idle thread time.\n", .{});

    if (failed == 0) {
        print("Passed All {}.\n", .{tasks.len});
    } else {
        print("Failed {}/{} (Passed {}%).\n", .{ failed, tasks.len, (tasks.len - failed) * 100 / tasks.len });
    }
}

pub const Position = struct {
    fen: []const u8,
    bestMoves: std.ArrayList(Move),
    worstMoves: std.ArrayList(Move),
    line: []const u8,
};

const Worker = struct {
    id: usize,
    thread: std.Thread,
    arena: std.heap.ArenaAllocator,
    ctx: search.SearchGlobals,
    nextTask: *Shared,
    tasks: []Position,
    failedCount: u64 = 0,
    passedCount: u64 = 0,
    endTime: i128 = 0,
};

// TODO: if i fail, ask stockfish because if it fails the test is probably dumb.
fn workerFn(self: *Worker) !void {
    std.time.sleep(50); // Just make absolutly sure the other thread finishes setting the array.
    const startTime = std.time.nanoTimestamp();
    while (true) {
        const nextTask = self.nextTask.fetchAdd(1, .seq_cst);
        if (nextTask >= self.tasks.len) break;

        const position = self.tasks[nextTask];
        var game = try Board.fromFEN(position.fen);

        const bestMove = try search.bestMove(.{}, &self.ctx, &game, MAX_DEPTH, TIME_LIMIT);
        var failed = false;
        if (position.bestMoves.items.len > 0) {
            for (position.bestMoves.items) |expected| {
                if (std.meta.eql(bestMove, expected)) break;
            } else {
                print("[{}/{}] Failed: {s}\n    Found {s} which is not a best move.\n", .{ nextTask + 1, self.tasks.len, position.line, try bestMove.text() });
                failed = true;
            }
        }

        for (position.worstMoves.items) |expected| {
            if (std.meta.eql(bestMove, expected)) {
                print("[{}/{}] Failed {s}\n    Found {s} which is a worst move.\n", .{ nextTask + 1, self.tasks.len, position.line, try bestMove.text() });
                failed = true;
            }
        }

        if (failed) {
            self.failedCount += 1;
        } else {
            self.passedCount += 1;
        }
    }

    self.endTime = std.time.nanoTimestamp();
    if (self.failedCount == 0) {
        const ms = @divFloor((self.endTime - startTime), std.time.ns_per_ms);
        print("Thread {} finished {} positions in {}ms.\n", .{ self.id, self.passedCount, ms });
    }
}

fn parsePositions(lists: *ListPool) !std.ArrayList(Position) {
    var tasks = std.ArrayList(Position).init(forever);

    var lines = std.mem.splitScalar(u8, positionData, '\n');

    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        var parts = std.mem.splitScalar(u8, line, ';');
        const fen = parts.next() orelse unreachable;
        var game = Board.fromFEN(fen) catch |err| std.debug.panic("{}. Failed to parse fen: {s}", .{ err, fen });
        var pos: Position = .{ .fen = fen, .line = line, .bestMoves = std.ArrayList(Move).init(forever), .worstMoves = std.ArrayList(Move).init(forever) };
        while (parts.next()) |info| {
            var words = std.mem.splitScalar(u8, info, ' ');
            assert(words.next().?.len == 0);
            const key = words.next() orelse continue;
            if (std.mem.eql(u8, key, "bm")) {
                while (words.next()) |moveStr| {
                    try pos.bestMoves.append(try parsePgnMove(&game, moveStr, lists));
                }
            } else if (std.mem.eql(u8, key, "am")) {
                while (words.next()) |moveStr| {
                    try pos.worstMoves.append(try parsePgnMove(&game, moveStr, lists));
                }
            }
        }
        try tasks.append(pos);
    }

    return tasks;
}
