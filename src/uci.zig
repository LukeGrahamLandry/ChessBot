const std = @import("std");
const Board = @import("board.zig").Board;

// https://gist.github.com/DOBRO/2592c6dad754ba67e6dcaec8c90165bf
const UciCommand = union(enum) {
    Init,
    AreYouReady,
    NewGame,
    SetPosition, // : Board,
    Go,
    Stop
};

const UciResult = union(enum) {
    InitOk,
    ReadyOk,

    pub fn parse(str: [] const u8) !UciResult {
        // TODO: this sucks
        if (std.mem.eql(u8, str, "uciok")) {
            return .InitOk;
        }
        if (std.mem.eql(u8, str, "readyok")) {
            return .ReadyOk;
        }

        return error.UnknownUciStr;
    }
};

// This needs to be two threads.
pub fn main() !void {
    var fish = try Stockfish.init();
    
    fish.send(.Init);
    fish.blockUntilRecieve(.InitOk);
    fish.send(.NewGame);
    fish.send(.AreYouReady);
    fish.blockUntilRecieve(.ReadyOk);
    fish.send(.SetPosition);
    fish.send(.Go);


    for (0..50) |_| {
        _ = fish.recieve() catch continue;
    }
    fish.send(.Stop);
    fish.send(.AreYouReady);
    fish.blockUntilRecieve(.ReadyOk);
    for (0..50) |_| {
        _ = fish.recieve() catch continue;
    }
    try fish.deinit();

    std.debug.print("[    ]: Done!\n", .{});
}

const Stockfish = struct {
    process: std.ChildProcess,

    pub fn init() !Stockfish {
        var stockFishProcess = std.ChildProcess.init(&[_] [] const u8 {"stockfish"}, std.heap.page_allocator);
        stockFishProcess.stdin_behavior = .Pipe;
        stockFishProcess.stdout_behavior = .Pipe;
        stockFishProcess.stderr_behavior = .Pipe;
        stockFishProcess.stdout = std.io.getStdIn();
        // TODO: helpful error message if stockfish isnt installed. 
        try stockFishProcess.spawn();
        return .{ .process=stockFishProcess };
    }

    pub fn deinit(self: *Stockfish) !void {
        _ = try self.process.kill();
    }

    pub fn send(self: *Stockfish, cmd: UciCommand) void {
        sendUci(self.process.stdin.?.writer(), cmd);
    }

    pub fn recieve(self: *Stockfish) !UciResult {
        return recieveUci(self.process.stdout.?.reader());
    }

    pub fn blockUntilRecieve(self: *Stockfish, expected: UciResult) void {
        blockUntilRecieveUci(self.process.stdout.?.reader(), expected);
    }
};

fn sendUci(out: anytype, cmd: UciCommand) void {
    var buf: [1000]u8 = undefined;
    _ = buf;
    const msg = switch (cmd) {
        .Init => "uci\n",
        .AreYouReady => "isready\n",
        .NewGame => "ucinewgame\n",
        .SetPosition => "position startpos\n",
        .Go => "go\n",
        .Stop => "stop\n",
    };

    std.debug.print("[luke]: {s}\n", .{msg});
    const success = out.writeAll(msg);

    // TODO: retry
    success catch |err| std.debug.panic("send {}\nfailed with {}\n", .{cmd, err});
}

fn recieveUci(in: anytype) !UciResult {
    var buf: [1000]u8 = undefined;
    var resultStream = std.io.fixedBufferStream(&buf);
    try in.streamUntilDelimiter(resultStream.writer(), '\n', null);
    const msg = resultStream.getWritten();
    std.debug.print("[fish]: {s}\n", .{msg});
    return UciResult.parse(msg);
}


fn blockUntilRecieveUci(in: anytype, expected: UciResult) void {
    // TODO: timeout detect to if it died
    while (true) {
        const msg = recieveUci(in) catch continue;
        if (std.meta.eql(msg, expected)) break;
    }
}



// Two things: a binary that implements UCI and a binary that acts as the gui between two other UCI engines? 
