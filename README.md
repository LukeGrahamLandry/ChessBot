# Chess Bot

- A zero dependency chess engine.
- A simple website that loads a wasm version of the engine that you can play against. [Try it now!](https://lukegrahamlandry.ca/chess/).

> This is my first project learning Zig! 
> Tested with Zig version `0.11.0-dev.3937+78eb3c561`. 

## Entry Points 

Running in Debug is super slow. ReleaseFast shouldn't be used when running the tests because you want assertions to be checked. Use ReleaseSafe instead, then if they fail, you can switch to Debug to get a stack trace.  

These (other than `web`) can each be run with a zig build step (`zig build -Doptimize=ReleaseFast <NAME>`). To build everything use `zig build -Doptimize=ReleaseFast install`, the executables will be in `zig-out/bin`.

**web**

Functions, with wasm compatible signatures, exported for the GUI to interact with the engine. 

> zig build-lib src/web.zig -target wasm32-freestanding -dynamic -rdynamic -O ReleaseFast && mv web.wasm web/main.wasm

**uci**

Native executable implementing the [Universal Chess Interface](https://gist.github.com/DOBRO/2592c6dad754ba67e6dcaec8c90165bf) for talking to other engines or guis. Communicates via stdin and stdout. 

I use this to play against other bots with [lichess-bot-devs/lichess-bot](https://github.com/lichess-bot-devs/lichess-bot). 

**book**

Parses pgn files from [Lichess](https://database.lichess.org/) and creates an opening book. Stores the most popular move for a given board by zobrist hash. The file format it generates is just a list of (64-bit hash, 64-bit move struct) pairs.

This is unused in the web version since square weights makes it play reasonably without inflating the binary. There's a comptime flag in uci.zig to enable it for local use. 

**precalc**

Search for better numbers to use in move gen hash tables for sliding pieces. Since the data is known ahead of time, it can just try random numbers until it finds something that allows using less memory and still has no collisions. Different starting squares have different hash function numbers because there are different significant bits for blockers. 

**perft**

Count all possible moves to a given depth from some starting position. This is used to test movegen. There's a file with a couple hundred positions and correct answers that a bunch of threads run through. If my code gets any wrong, it asks stockfish about the same position and narrows down exactly which legal move is missing or illegal move is added. Requires an exising stockfish installation. 

**bestmoves**

Goes through a file of test positions from [CPW](https://www.chessprogramming.org/Test-Positions) and see if my search finds the correct best move. I only get ~70% correct now, but it should easily catch dumb pruning bugs. 

**fish**

Runs games between my engine and crippled versions of stockfish for testing its strength as I make changes. Requires a pre-existing stockfish installation. Alternatively, can run games between any UCI engines. 

## How It Works

- [Alpha Beta Pruning](https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning)
- [Iterative Deepening](https://en.wikipedia.org/wiki/Iterative_deepening_depth-first_search)
- [Transposition Table ](https://en.wikipedia.org/wiki/Transposition_table)
- [Zobrist Hashing](https://en.wikipedia.org/wiki/Zobrist_hashing)
- [Magic Bitboards](https://www.chessprogramming.org/Magic_Bitboards)
- Opening Book: popular first moves in games from [Lichess](https://database.lichess.org/)

## Things to fix

- The web version should use Web Workers, so it doesn't freeze the ui if you give it more time to think.
- The opening book format represents moves inefficiently (and it's fragile since it's a bit cast of my struct).
- My quiescence search doesn't seem to work well. Probably have to handle differently when in check. Also reduce code duplication. 
- Try to train square weights. Also include material in those tables to remove a switch. 
- Make sure all the bestmoves tests are reasonable for the amount of time I give it and get it to a point where they all pass. 
- Revisit move ordering. My current strategy of just preferring captures is so dramatically helpful, it seems like something smarter would be even better. 
- Try to update checks/pins info incrementally instead of recalculating on every board. 
- PV line tracking with less copying (currently it's noticeably slower when enabled). Show it in UI. 
- Implement the rest of UCI
- Make the UI prettier and see if I can clean up the JS a bit 
- Do my own lichess api interaction instead of using the script 
- Consider pawn structure / passed pawns in eval
- Do king weights table and have it stop hiding in the endgame when the king becomes a useful piece. 
- Get rid of the CollectMoves vs GetAttackSquares struct methods since I'm just using the fields anyway. But I like the filter can be comptime known and the output can be on the same struct. 
- Make sure I'm not checking the time too often. 
- Try different memo replacement strategies. 
- Build script needs to do the wasm target too. 

## Art

The same textures every other low effort chess game in the universe found by googling for free chess icons. 

- https://commons.wikimedia.org/wiki/File:Chess_Pieces_Sprite.svg jurgenwesterhof (adapted from work of Cburnett), CC BY-SA 3.0 <https://creativecommons.org/licenses/by-sa/3.0>, via Wikimedia Commons
- https://commons.wikimedia.org/wiki/File:Chessboard480.svg החבלן, CC0, via Wikimedia Commons
