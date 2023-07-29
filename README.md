# Chess Bot

- A zero dependency chess engine.
- A simple website that loads a wasm version of the engine that you can play against. [Try it now!](https://lukegrahamlandry.ca/chess/).

> This is my first project learning Zig, forgive me if I make some terrible mistake!  
> Tested with Zig version `0.11.0-dev.3937+78eb3c561`. 

## Entry Points 

- `web.zig`: Functions, with wasm compatible signitures, exported for the GUI to interact with the engine. 
- `uci.zig`: Native executable implementing the [Universal Chess Interface](https://gist.github.com/DOBRO/2592c6dad754ba67e6dcaec8c90165bf) for talking to other engines or guis. Communicates via stdin and stdout. 
- `fish.zig`: Runs games between my engine and crippled versions of stockfish for testing its strength as I make changes. Requires a pre-existing stockfish installation and doesn't support wasm. 
- `tests.zig`: Behaviour tests that ensure the engine is working as expected. 
- `bench.zig`: Runs games with different settings to compare performance. 

Running in Debug is super slow. ReleaseFast shouldn't be used when running the tests because you want assertions to be checked. Use ReleaseSafe instead, then if they fail, you can switch to Debug to get a stack trace.  

## How It Works

### Alpha Beta Pruning

- https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning

### Iterative Deepening

- https://en.wikipedia.org/wiki/Iterative_deepening_depth-first_search

### Transposition Table 

- https://en.wikipedia.org/wiki/Transposition_table

### Zobrist Hashing

- https://en.wikipedia.org/wiki/Zobrist_hashing

### Opening Book

Games from https://database.lichess.org/

## Art

The same textures every other low effort chess game in the universe found by googling for free chess icons. 

- https://commons.wikimedia.org/wiki/File:Chess_Pieces_Sprite.svg jurgenwesterhof (adapted from work of Cburnett), CC BY-SA 3.0 <https://creativecommons.org/licenses/by-sa/3.0>, via Wikimedia Commons
- https://commons.wikimedia.org/wiki/File:Chessboard480.svg החבלן, CC0, via Wikimedia Commons
