# Zig/Wasm Chess "AI"

Tested with Zig version `0.11.0-dev.3937+78eb3c561`.

## Files 

- `web.zig`: Functions exported in WASM for the GUI to interact with the engine. 
- `uci.zig`: Implements the [Universal Chess Interface](https://gist.github.com/DOBRO/2592c6dad754ba67e6dcaec8c90165bf) for talking to other engines.
- `fish.zig`: Runs games between my engine and crippled versions of stockfish for testing its strength as I make changes. 
- `tests.zig`: Behaviour tests that ensure the engine is working as expected. 
- `bench.zig`: Runs games with different settings to compare performance. 
- `board.zig`, `movegen.zig`, `search.zig`: The engine.

Running in Debug is super slow. ReleaseFast shouldn't be used when running the tests because you want assertions to be checked. Use ReleaseSafe instead, then if they fail, you can switch to Debug to get a stack trace.  
