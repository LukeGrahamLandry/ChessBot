
### Profiling 

Useful to see what methods to focus on.  

Run it then get the process id from activity monitor or whatever.  

```
sample <pid> -f zig-out/temp_profile_info.sample
filtercalltree zig-out/temp_profile_info.sample
```

or  

```
zig build-exe src/bench.zig -O ReleaseFast -lprofiler -L/opt/homebrew/Cellar/gperftools/2.10/lib &&
CPUPROFILE=$PWD/prof.out DYLD_LIBRARY_PATH=/opt/homebrew/Cellar/gperftools/2.10/lib ./bench &&
pprof bench prof.out
```

Needs `brew install gperftools` and `brew install graphviz`.

## Ideas

- Know about check, mate, castling, en-passant, and draws!
- Support extra fen string info. 
- Be able to run tests in parrallel. Write custom test runner that just uses seperate processes? 
- Have the UI show lines for debugging
- Give yourself extra depth only looking at captures because it thinks hanging pieces on move n+1 is fine. 
- Opening book. Maybe order by board hash and binary search because normal hashmap wastes space to avoid collissions. Only bother with lookup in first x moves. 
- Endgame book. ^
- Partial heap sort for move ordering. Then I can have a more complex eval function? 
- Use n-1 depth for move ordering of n search. Then you can cancel at anytime and use previous results. 
- Run engine on another thread so it doesn't hang the UI and can be canceled when it goes to long. Put a flag somewhere that it checks to break out of the recursion. 

## Learning Zig 

- @truncate explicitly removes high bits but @intCast asserts that the number fits in the new type. So intCast is just better for my usize->u6 of board indexes because it means debug builds catch dumb mistakes and in release builds it becomes (i assume?) a no-op. 
- You can't always use integer literals directly, you often need an explicit type.
- @as(type, value) is for unambigous casts that can't fail. No-op at runtime, it's just to explicitly talk to the type system. Can be used to give an explicit type to other casts. 
- You can't have arrays of unnatural integers but there's a PackedIntArray struct that will do the bit magic for packing them into normal integers for you. 

### TODO

- I don't fully understand the allocator stuff. Using the allocator from std.testing gives a compile error if not in a test block but if you look at the code it's just a GeneralPurposeAllocator. Does that mean general purpose is doing bad and slow test things so shouldn't be used in the main program? or is it just future proofing if they want to change the testing allocator to something that shouldn't generally be used? Is there a reason not to use an arena whenever doing a tree structure so you can free all at once? 
- Don't fully understand pointer alignment stuff. What's the incantation to allocate a []u32 -> cast to (4x longer) []u8 -> free it? 
- Should try to get used to the auto-format. 
- Is there an IDE that can actually report errors? VS code with Zig Language seems to get very confused. Completions for enums and struct initialization seem to just give things from all your types? 

## Running perft on a bunch of threads 

more threads don't scale the time linearly. better clock time but worse NPS. 

| Cores | MNPS/C  | Time |
| ----- | ---     | ---- |
| 1     | 72      | 66s  |
| 4     | 56-62   | 22s  |
| 8     | 36-48   | 20s  |

Saw that the last task to finish was 58/126. They were all just waiting on the last guy. Verified by printing thread idle time, with 4 cores, one thread finished in 16s but the last took until 22s. Tried putting longer lasting tasks at the front of the file. Now I sort the list by number of nodes after loading it and there's <1ms idle time at the end.

| Cores | MNPS/C  | Time |
| ----- | ------- | ---- |
| 4     | 62-65   | 19s  |
| 8     | 28-32   | 19s  | 

Debug mode profiler says lots of time in __ulock_wait, I guess thats contention for the atomic task index at the end. 
So removed that shared index, instead each thread starts at thier id and increments by the number of threads. Now there's more idle time, the sort makes it unfair because the first thread gets the hardest job in each group of x. At 8 threads, the last to finish did 2x as many nodes as the first and 6/8 were idle > 5s. 

| Cores | MNPS/C  | Time |
| ----- | ------- | ---- |
| 4     | 57-63   | 23s  |
| 8     | 36-49   | 20s  | 

Still lots of __ulock_wait even though no atomics, so that must be the main thread in joining everyone at the end? Which the call graph confirms. Should have looked at that first! So that just doesn't matter. I put it back to the atomics because I like the fairness. 

One of my problems was using an insane amount of memory. Doing each perft in an arena where all the move lists wern't dropped until the end. Most of the time it was fast but when using lots of threads it would get to the edge of my ram and start using swap. Now using a pool of lists and it uses literally 6 orders of magnitude less memory for my current perfts. It's still about the same speed for normal play where ram wasn't a problem but this will enable higher depth if I manage to speed everything else up. Really arenas was the right answer, its just that each list needs to be its own. Absolutly insane that I didn't notice that until now. Perft NPS still doesn't scale linearly with threads but its getting closer. Seems to win a few more games against cripplefish. 

| Cores | MNPS/C  | Time |
| ----- | ------- | ---- |
| 1     | 74      | 64s  |
| 4     | 62-66   | 18s  |
| 8     | 41-47   | 13s  | 

## Switching to legal move generation 

The replay game benchmark is immediately slower but making it not do the checks prep for the finished leaf nodes makes it about the same speed as before. But now I can see more opportunities to make the move gen code better. Interesting that the bulk counting perft this enables makes that like 3x as fast. So that's really counting a different thing than when you need to play every move. Without bulk counting the old one was 4x as fast. Using playNoUpdateChecks at the bottom level but still playing the move is still ~1.5x faster than the old one and I'd expect that to be very similar to what search is doing so strange that it doesn't seem faster. 

## much better memo table 


## Methods note

"~2x as fast" means `old_time/new_time == 2`. 

- Not very scientific because I just run a few times then take one number. The improvements are so large/consistant that it feels trustworthy. Should make something that runs it multiple times and averages (throw away outliers?) eventually. 
- Was originally getting numbers by running 5 moves each playing against itself. Which means I'm measuring the beginning of the game where not a lot of captures and should probably be openings book anyway. So should revise that to more interesting position. But depth 4 from move 5 is probably like a real game state.  
- Currently benchmarking on native (m1), should do in wasm if that's what I care about. 
- I've been increasing depth as it gets faster which might bias it but at the very least means absolute ms numbers can't be compared accoss runs.
- Make sure logging doesn't become a bottle neck.  

Interesting that the first run of a new executable is often a bit slower (time does not include compile!), something caching it? 

## counting possible moves 

After banning letting your king get taken in check, need to make the test faster. Tried writing it iteritivly instead of recusivly but all the speed up was just from using an arena allocator instead of freeing everything. so went back to recusive because that seems more elegant, uses unmove instead of copyMove so if I can make check detection gradual it will help. 

Using ArenaAllocator(PageAllocator) was 9.5x as fast as TestingAllocator for depth 4 with dumb look ahead check detection.

```
// // var tempB = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // // defer tempB.deinit();
    // var me = Colour.White;
    // const maxNeeded = possibleGames[possibleGames.len - 1];
    // var thisLayer = try std.ArrayList(Board).initCapacity(tempA.allocator(), maxNeeded);
    // try thisLayer.append(Board.initial());
    // var nextLayer = try std.ArrayList(Board).initCapacity(tempA.allocator(), maxNeeded);
    // // try MoveFilter.Any.get().possibleMoves(game, me, tst)
    // for (possibleGames, 1..) |expected, i| {
    //     const start = std.time.nanoTimestamp();
    //     for (thisLayer.items) |game| {
    //         const nextMoves = try MoveFilter.Any.get().possibleMoves(&game, me, tempA.allocator());

    //         for (nextMoves) |move| {
    //             const afterMove = game.copyPlay(move);
    //             const nextCapKing = try genKingCapturesOnly.possibleMoves(&afterMove, me.other(), tempA.allocator());
    //             if (nextCapKing.len == 0) try nextLayer.append(afterMove);  // legal
    //         }
    //     }

    //     try std.testing.expectEqual(nextLayer.items.len, expected);
    //     me = me.other();

    //     thisLayer.clearRetainingCapacity();
    //     std.mem.swap(std.ArrayList(Board), &thisLayer, &nextLayer);
        
    //     // These parameters are backwards because it can't infer type from a comptime_int. This seems dumb. 
    //     // try std.testing.expectEqual(countPossibleGames(&game, .White, i), expected);
    //     print("Explored Depth {} in {}ms.\n", .{i, @divFloor((std.time.nanoTimestamp() - start), @as(i128, std.time.ns_per_ms))});
    // }
```

## rng is slow

It's 1.5x faster to not carefully pick a random move to make when there is only one possible move. Fair enough, that was a skill issue on my part. 

## Incremental eval

For leaf nodes, need to calculate the board's material eval. Instead of doing that again each time, incrementally update it each time you play or unplay a move. That's ~1.5x as fast. Which is enough that the memo table doesn't help anymore unless you increase the number of rounds played. So farther in to the game, the more the memo helps, which makes sense (1.6x for 50 moves but 1x for 10 moves). And that's resetting it after each full search, so farther in game is about getting more interesting positions not about precomputing stuff.  

And after that, the bitboards seem slightly faster instead of slightly slower. I think the bitboard punishes the hash table (I checked that hash funcs aren't using the whole struct, just squares array so more data isnt hurting it directly). 

Thought that might make the full sort good now that simpleEval is faster but no. 

## Bitboard tracking where each colour peieces are

Just tracking made it a bit slower. I assume because of jump in set/unset bit switching over colour. 
Using that in the move gen `for` loop to pick which squares have my pieces is slower than before. 

Made Colour be a u1 instead of u2 and now empty is only stored in the Kind. That might let me update both black & white and just muliply by the colour bit so no jump. I thought it was much faster but I just messed it up and it was looking at fewer moves, its actaully the same speed.

Tried writing it as bit ops, 

```
pub fn setBit(self: *Board, index: u6, colour: Colour) void {
    const whiteBit: u64 = ~@intFromEnum(colour);
    const blackBit: u64 = @intFromEnum(colour);
    comptime assert(@intFromEnum(Colour.White) == 0 and @bitSizeOf(Colour) == 1);
    self.whitePeicePositions |= (whiteBit << index);
    self.blackPeicePositions |= (blackBit << index);
}
```

```
pub fn setBit(self: *Board, index: u6, colour: Colour) void {
    switch (colour) {
        .White => self.whitePeicePositions |= (one << index),
        .Black => self.blackPeicePositions |= (one << index),
    }
}
```

Both work but the simple one is faster. I guess the optimiser knows best. 

Tried using the bitboards for eval.

```
pub fn simpleEval(game: *const Board) i32 {
    var result: i32 = 0;
    var flag: u6 = 1;
    for (0..64) |i| {
        defer flag <<= 1;
        const isEmpty = ((game.whitePeicePositions & flag) | (game.blackPeicePositions & flag)) == 0;   
        if (isEmpty) continue;
        const piece = game.squares[i];
        switch (piece.colour) {
            .White => result += piece.kind.material(),
            .Black => result -= piece.kind.material(),
        }
    }
    return result;
}
```

But as expected that was slower because branching is really bad.  
Maybe this whole thing was pointless because my 64 byte board fits in a cache line anyway so looping over it doing reads is really cheap. 

## Sorting moves. 


Captures first: 

```
for (moves.items, 0..) |move, index| {
    moves.items[index] = toPush;
    toPush = move;
    if (board.squares[toPush.to].empty()) {
        break;
    }
} 
```

Higher material captures first: 
```
for (moves.items, 0..) |move, index| {
    const holding = board.squares[toPush.to].kind.material();
    const lookingAt = board.squares[moves.items[index].to].kind.material();
    if (holding == 0) break;
    if (holding > lookingAt){
        moves.items[index] = toPush;
        toPush = move;
    }
}
```

When adding moves, ordering by value of piece captured instead of just capture or not is ~1.4x as fast for depth=4, moves=15 (but for slower for moves=5).

Not doing that and insertion sorting the whole list by board eval at the end is massivly slower. 

## Always alpha-beta

The upper layer of the tree in bestMove has a custom loop because I need to actually hold on to which move was best (it also resets an arena allocator each iteraction so less memory usage). However, I forgot to make that update alpha-beta numbers so was missing out on the most important pruning. Fixing made it ~1.9x as fast. 

Wasn't adding to memo map when remaining == 0, just always doing it is 1.25x as fast. 

Had a `remaining > 0 and` check before checking alpha-beta but removing that makes it 2.6x as fast. 
I had the check because Wikipedia's version has an early exit for the simpleEval case. 
I think the mistake was thier remaining=0 means simpleEval this board but my remaining=0 means simpleEval each possible move from this board. 

## Hashing

Same speed, I assume both become no-op cast. 
```
// &@as([64] u8, @bitCast(a.squares))
// std.mem.asBytes(&a.squares)
```

Custom eql method that's just std.mem.eql on the byte array is same speed as auto but feels more elegant. 

Equivalent of using the AutoHashMap: 

```
// const func = comptime std.hash_map.getAutoHashFn(Board, @This());  
// return func(ctx, key);  // 1x
```

Different algorithims: 

```
const data = std.mem.asBytes(&key.squares);
// return std.hash.Fnv1a_64.hash(data);  // ~2.11x
// return std.hash.XxHash64.hash(0, data);  // ~2.28x
// return std.hash.Murmur2_64.hash(data);  // ~2.44x
return std.hash.CityHash64.hash(data);  // ~2.48x
```

Interesting that simpler implementation doesn't mean faster because avoiding collissions is worth a lot.  

Next steps:
- Should try 32 bit versions as well. 
- The byte arrays are 25% zero padding so pieces can be passed to javascript as bytes. Might be worth re-encoding on the boundary to hash less data. 
- Script that compares them automatically to make sure my choice is still best as I change the rest of the program. 
- Try a specialized hash for chess positions like https://www.chessprogramming.org/Zobrist_Hashing (can be done incrementaly as moves are made)

```
return std.hash.Wyhash.hash(0, data);
```

Tried later with Wyhash which is same algorithim as auto hash but on the byte array instead of the comptime struct walk. 
Which was also much faster than auto. But by then I'd made other things faster so the multipliers of everything changed. 

## Material eval

**Slow**

```
pub fn simpleEval(game: *const Board) i32 {
    var result: i32 = 0;
    for (game.squares) |piece| {
        const value: i32 = switch (piece.kind) {
            .Pawn => 100,
            .Bishop => 300,
            .Knight => 300,
            .Rook => 500,
            .King => 100000,
            .Queen => 900,
            .Empty => continue,
        };
        switch (piece.colour) {
            .White => result += value,
            .Black => result -= value,
            .Empty => unreachable,
        }
    }
    return result;
}
```

**Fast**

```
pub fn simpleEval(game: *const Board) i32 {
    var result: i32 = 0;
    for (game.squares) |piece| {
        const value: i32 = switch (piece.kind) {
            .Pawn => 100,
            .Bishop => 300,
            .Knight => 300,
            .Rook => 500,
            .King => 100000,
            .Queen => 900,
            .Empty => 0,
        };
        switch (piece.colour) {
            .White => result += value,
            else => result -= value,
        }
    }
    return result;
}
```

- This made it ~1.5x as fast. 
    - At first I forgot to change the .Empty from being unreachable, and that was 1.5x as well. Then .Empty => {} was ~1.3x and using else since its 0 anyway was back to ~1.5x so that's probably what the optimised was doing anyway. Else branch being + or - didn't make a differece. 
- I'm assuming it just really confused the branch prediction.  
- Sadly I found this by accident when factoring out the piece value into its own function to use for ordering moves. 
    - (ordering moves by value of captured piece instead of just capture or not didn't help but I only tried it on the first 10 halfmoves so should revisit). 
