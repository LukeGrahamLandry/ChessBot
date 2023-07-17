# Zig/Wasm Chess "AI"

Zero dependency chess engine targeting Web Assembly.  

## Files 

- `web.zig`: Functions, with wasm compatible signitures, exported for the GUI to interact with the engine. 
- `uci.zig`: Native executable implementing the [Universal Chess Interface](https://gist.github.com/DOBRO/2592c6dad754ba67e6dcaec8c90165bf) for talking to other engines. Communicates via stdin and stdout. 
- `fish.zig`: Runs games between my engine and crippled versions of stockfish for testing its strength as I make changes. Requires a pre-existing stockfish installation and doesn't support wasm. 
- `tests.zig`: Behaviour tests that ensure the engine is working as expected. 
- `bench.zig`: Runs games with different settings to compare performance. 
- `board.zig`, `movegen.zig`, `search.zig`: The engine.

Running in Debug is super slow. ReleaseFast shouldn't be used when running the tests because you want assertions to be checked. Use ReleaseSafe instead, then if they fail, you can switch to Debug to get a stack trace.  

> Tested with Zig version `0.11.0-dev.3937+78eb3c561`.

### Web UI

A simple website that loads a wasm version of the engine that you can play against. [Try it now!](https://lukegrahamlandry.ca/chess/).
