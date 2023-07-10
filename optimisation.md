## Methods note

"~2x as fast" means `old_time/new_time == 2`. 

- Not very scientific because I just run a few times then take one number. The improvements are so large/consistant that it feels trustworthy. Should make something that runs it multiple times and averages (throw away outliers?) eventually. 
- Getting numbers by running 5 moves each playing against itself. Which means I'm measuring the beginning of the game where not a lot of captures and should probably be openings book anyway. So should revise that to more interesting position. But depth 4 from move 5 is probably like a real game state. 
- Currently benchmarking on native (m1), should do in wasm if that's what I care about. 
- I've been increasing depth as it gets faster which might bias it but at the very least means absolute ms numbers can't be compared accoss runs.
- Make sure logging doesn't become a bottle neck.  

Interesting that the first run of a new executable is often a bit slower (time does not include compile!), something caching it?  

### Profiling 

Useful to see what methods to focus on.  

Run it then get the process id from activity monitor or whatever.  

```
sample <pid> -f zig-out/temp_profile_info.sample
filtercalltree zig-out/temp_profile_info.sample
```

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
