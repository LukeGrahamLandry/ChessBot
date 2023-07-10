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

- 5 moves each: ~2900ms -> ~1850ms (~1.5x).  
    - At first I forgot to change the .Empty from being unreachable, and that was 1.5x as well. Then .Empty => {} was ~1.3x and using else since its 0 anyway was back to ~1.5x so that's probably what the optimised was doing anyway.
- I'm assuming it just really confused the branch prediction.  
- Sadly I found this by accident when factoring out the piece value into its own function to use for ordering moves. 
    - (ordering moves by value of captured piece instead of just capture or not didn't help but I only tried it on the first 10 halfmoves so should revisit). 