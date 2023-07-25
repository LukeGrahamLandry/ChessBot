"use strict";

const WHITE = 0;
const BLACK = 1;
const ENGINE_OK = -1;
const ENGINE_ERROR = -2;
const ENGINE_ILLEGAL_MOVE = -3;
const STR_BUFFER_SIZE = 512;

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
let mainCanvas = document.getElementById("board").getContext("2d");

// TODO: show the right player turn instead of always white. 
const enableBot = false;
// const minMoveTimeMs = 500;  // When computer vs computer, if the engine is faster than this, it will wait before playing again. 

// TODO: select which colour is human or computer. button to switch mid game for testing. ai vs ai mode. 
// TODO: option to render black at the bottom
// TODO: forward and back buttons to move through position history, start playing from anywhere to make tree (render all branches as tiny boards?)
// TODO: run wasm in a worker so it doesn't freeze ui while searching
// TODO: render captured pieces, show engine eval, show when in check
// TODO: each file should know the git hash and report the error if something caches just one
// TODO: show the line it thinks is best 
// TODO: save game in local storage 
// TODO: slider for memo table size
// TODO: a board pointer and a canvas target could be a class instead of scattered global variables. 
// TODO: could save the fen of the current board in the url fragment. should have checkbox to not fill up history. 

let ticker = null;
let boardFenHistory = [];
let gameOverMsg = null;
function tickGame() {
    if (!enableBot) return;

    const board = mainGame;
    const start = performance.now();
    const result = Engine.playBotMove(board, msgPtr, STR_BUFFER_SIZE);
    boardFenHistory.push(getFenFromEngine(board, fenPtr, STR_BUFFER_SIZE));
    const time = Math.round(performance.now() - start);
    console.log("Found move in " + time + "ms.");
    renderBoard(mainGame, mainCanvas);;
    if (result == ENGINE_OK) { 
        // TODO: do this if computer vs computer.  
        // if (time < minMoveTimeMs) ticker = window.setTimeout(tickGame, minMoveTimeMs - time);
        // else ticker = window.setTimeout(tickGame, 1);
    } else if (result > 0) {  // Game over
        gameOverMsg = getWasmString(msgPtr, result);
        console.log(gameOverMsg);
        renderBoard(mainGame, mainCanvas);;
    } else {
        handleEngineError();
    }
};

function handleEngineError(){
    document.getElementById("controls").style.display = "none";
}

function handleAskRestart() {
    if (confirm("Reset the game to the initial position?")) handleRestart();
}

function handleRestart() {
    handlePause();
    console.log(boardFenHistory);
    Engine.restartGame(mainGame);
    boardFenHistory = [getFenFromEngine(mainGame, fenPtr, STR_BUFFER_SIZE)];
    gameOverMsg = null;
    renderBoard(mainGame, mainCanvas);
}

function handlePause(){
    window.clearTimeout(ticker);
    document.getElementById("resume").disabled = false;
    document.getElementById("pause").disabled = true;
}

function handleResume(){
    // tickGame();
    document.getElementById("resume").disabled = true;
    document.getElementById("pause").disabled = false;
}

function handleSetFromFen(){
    handlePause();
    // The length here must match the size of fenView in Zig to prevent writes overflowing when string too long. 
    const fenBuffer = new Uint8Array(Engine.memory.buffer, fenPtr, STR_BUFFER_SIZE);
    const fenString = document.getElementById("fen").value;
    const length = textEncoder.encodeInto(fenString, fenBuffer).written;
    const success = Engine.setFromFen(mainGame, fenPtr, length);
    if (!success) alert("Invalid FEN.");
    renderBoard(mainGame, mainCanvas);
    // tickGame();
}

function getFenFromEngine(board) {
    const length = Engine.getFen(board, fenPtr, STR_BUFFER_SIZE);
    if (length === 0) {
        handleEngineError();
        return;
    }
    return getWasmString(fenPtr, length);
}

function isHumanTurn() {
    // This could be done by parsing the fen but that's a lot of extra code just to be slightly slower. 
    return !enableBot || Engine.isWhiteTurn(mainGame);
}

let clicked = null;
function handleCanvasClick(e) {
    const squareSize = mainCanvas.canvas.getBoundingClientRect().width / 8;
    const file = Math.floor(e.offsetX / squareSize);
    const rank = 7 - Math.floor(e.offsetY / squareSize);
    if (clicked === null){
        clicked = [file, rank];  // TODO: dont like this. use index or be object
        renderBoard(mainGame, mainCanvas);
    } else {
        if (!isHumanTurn()) {
            clicked = [file, rank];
            renderBoard(mainGame, mainCanvas);
            return;
        }

        const fromIndex = frToIndex(clicked[0], clicked[1]);
        const toIndex = frToIndex(file, rank);

        // TODO: make sure trying to move while the engine is thinking doesn't let you use the wrong colour. 
        const result = Engine.playHumanMove(mainGame, fromIndex, toIndex, msgPtr, STR_BUFFER_SIZE);
        if (result == ENGINE_OK) { 
            clicked = null;
            boardFenHistory.push(getFenFromEngine(mainGame, fenPtr, STR_BUFFER_SIZE));
            renderBoard(mainGame, mainCanvas);
            // TODO: only do this if other player is engine. 
            setTimeout(tickGame, 25);  // Give it a chance to render.
        } else if (result == ENGINE_ILLEGAL_MOVE) {
            console.log("Player tried illigal move.");
            clicked = [file, rank];
            renderBoard(mainGame, mainCanvas);
        } else if (result > 0) {  // Game over
            gameOverMsg = getWasmString(msgPtr, result);
            console.log(gameOverMsg);
            boardFenHistory.push(getFenFromEngine(mainGame, fenPtr, STR_BUFFER_SIZE));
            renderBoard(mainGame, mainCanvas);;
        } else {
            handleEngineError();
        }
    }
}

function drawPiece(ctx, file, rank, pieceByte) {
    if (pieceByte === 0) return;
    
    const kind = BigInt(pieceByte) >> 1n;
    const squareSize = ctx.canvas.width / 8;
    const imgSquareSize = chessImg.width / 6;
    if (kind > 6n) {
        console.log("Engine gave invalid pieceByte (" + pieceByte + ")");
    } else {
        const sX = (Number(kind) - 1) * imgSquareSize;
        const sY = (pieceByte % 2 === 0) ? 0 : imgSquareSize;  // White or Black

        ctx.drawImage(chessImg, sX, sY, imgSquareSize, imgSquareSize, file * squareSize, (7 - rank) * squareSize, squareSize, squareSize);
    }
    
    // ctx.font = "12px Arial";
    // ctx.fillStyle = "red";
    // ctx.fillText(pieceByte, (file + 0.5) * squareSize, (7 - rank + 0.5) * squareSize);
}

function frToIndex(file, rank) {
    return rank*8 + file;
}

let bitBoardInfo = "none";
function handleBitboardSelect() {
    const value = document.getElementById("bitboard").value;
    bitBoardInfo = value;
    renderBoard(mainGame, mainCanvas);;
}

function drawBitBoard(ctx, targetSquaresFlag, colour) {
    if (targetSquaresFlag == 0n) return;

    // The 'n' suffix makes it use BigInt instead of doubles so I can use it as a u64 bit flag. 
    for (let i=0n;i<64n;i++) {
        const flag = 1n << i;
        if (targetSquaresFlag & flag) {
            fillSquare(ctx, Number(i % 8n), Number(i / 8n), colour, true);
        }
    }
}

function drawBitBoardPair(ctx, w, b) {
    for (let i=0n;i<64n;i++) {
        const flag = 1n << i;
        if (w & b & flag) {
            fillSquare(ctx, Number(i % 8n), Number(i / 8n), "purple", false);
        } else if (w & flag) {
            fillSquare(ctx, Number(i % 8n), Number(i / 8n), "red", false);
        } else if (b & flag) {
            fillSquare(ctx, Number(i % 8n), Number(i / 8n), "blue", false);
        }
    }
}

const letters = ["A", "B", "C", "D", "E", "F", "G", "H"];
function renderBoard(board, ctx) {
    const fen = getFenFromEngine(board);
    document.getElementById("fen").value = fen;
    document.getElementById("player").innerText = gameOverMsg != null ? gameOverMsg : (Engine.isWhiteTurn(board) ? "White" : "Black") + "'s Turn";
    document.getElementById("mEval").innerText = Engine.getMaterialEval(board);

    // TODO: If I really cared I could just render the diff instead of clearing the board
    ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);

    // TODO: Either put the magic numbers in the option value or have explicitly named functions (second one probably better!). 
    //       Could make the option value be the function name to call on the engine... but that feels weird. 
    switch (bitBoardInfo) {
        case "none":
            break;
        case "all": 
            drawBitBoardPair(ctx, Engine.getPositionsBB(board, WHITE), Engine.getPositionsBB(board, BLACK));
            break;
        case "king": 
            drawBitBoardPair(ctx, Engine.getKingsBB(board, WHITE), Engine.getKingsBB(board, BLACK));
            break;
        case "castle": 
            drawBitBoardPair(ctx, Engine.getCastlingBB(board, WHITE), Engine.getCastlingBB(board, BLACK));
            break;
        case "prev": {
            drawBitBoard(ctx, Engine.getLastMoveBB(board), "green");
            break;
        }
        case "french": {
            drawBitBoard(ctx, Engine.getFrenchMoveBB(board), "black");
            break;
        }
        case "attacks": {
            drawBitBoardPair(ctx, Engine.getAttackBB(board, WHITE), Engine.getAttackBB(board, BLACK));
            break;
        }
        case "single_sliding_check": {
            drawBitBoardPair(ctx, Engine.slidingChecksBB(board, WHITE), Engine.slidingChecksBB(board, BLACK));
            break;
        }
        case "bishop_pins": {
            drawBitBoardPair(ctx, Engine.pinsByBishopBB(board, WHITE), Engine.pinsByBishopBB(board, BLACK));
            break;
        }
        case "rook_pins": {
            drawBitBoardPair(ctx, Engine.pinsByRookBB(board, WHITE), Engine.pinsByRookBB(board, BLACK));
            break;
        }
        case "french_bishop_pins": {
            drawBitBoardPair(ctx, Engine.pinsFrenchByBishopBB(board, WHITE), Engine.pinsFrenchByBishopBB(board, BLACK));
            break;
        }
        case "french_rook_pins": {
            drawBitBoardPair(ctx, Engine.pinsFrenchByRookBB(board, WHITE), Engine.pinsFrenchByRookBB(board, BLACK));
            break;
        }
        
        default: 
            console.log("Invalid bitBoardInfo string.");
    }

    if (clicked != null) {
        const whitePieces = BigInt(Engine.getPositionsBB(board, WHITE));
        const blackPieces = BigInt(Engine.getPositionsBB(board, BLACK));
        const allPieces = whitePieces | blackPieces;
        const clickedIndex = frToIndex(clicked[0], clicked[1]);
        const targetSquaresFlag = Engine.getPossibleMovesBB(board, Number(clickedIndex));
        const clickedFlag = 1n << BigInt(clickedIndex);
        if ((allPieces & clickedFlag) != 0) fillSquare(ctx, clicked[0], clicked[1], "yellow", true);
        drawBitBoard(ctx, targetSquaresFlag, (whitePieces & clickedFlag) ? "lightblue" : "red");
    }
    
    const pieces = new Uint8Array(Engine.memory.buffer, Engine.getBoardData(board));
    for (let rank=0;rank<8;rank++){
        for (let file=0;file<8;file++){
            const p = pieces[rank*8 + file];
            drawPiece(ctx, file, rank, p);

            if (document.getElementById("showlabels").checked) {
                const squareSize = ctx.canvas.width / 8;
                ctx.font = "15px Arial";
                ctx.fillStyle = "blue";
                ctx.fillText(letters[file] + "" + (rank+1), (file) * squareSize, (7 - rank + 0.2) * squareSize);
            }
        }
    }
}

function fillSquare(ctx, file, rank, colour, isSmall) {
    const squareSize = ctx.canvas.width / 8;
    ctx.fillStyle = colour;
    const edge = squareSize * (isSmall ? 0.25 : 0.05);
    ctx.fillRect(file*squareSize + edge, (7-rank)*squareSize + edge, squareSize - edge*2, squareSize - edge*2);
}

function handleResize(){
    const size = Math.min(Math.min(window.innerWidth, window.innerHeight) * 0.9, 600);
    mainCanvas.canvas.style.width = "";
    mainCanvas.canvas.style.height = "";
    mainCanvas.canvas.width = size;
    mainCanvas.canvas.height = size; 
    renderBoard(mainGame, mainCanvas);
}

let maxTimeMs = 0;
let maxDepth = 0;
function handleSettingsChange() {
    maxTimeMs = document.getElementById("time").value;
    document.getElementById("showtime").innerText = maxTimeMs;
    maxDepth = document.getElementById("depth").value;
    document.getElementById("showdepth").innerText = maxDepth;
    Engine.changeSettings(maxTimeMs, maxDepth);
}

function getWasmString(ptr, len) {
    const buffer = new Uint8Array(Engine.memory.buffer, ptr, len);
    return textDecoder.decode(buffer);
}

let mainGame;
let fenPtr;
let msgPtr;
function startChess() {
    document.getElementById("loading").style.display = "none";
    if (Engine.protocolVersion() != 3) {
        const msg = "Unrecognised engine protocol version (" + Engine.protocolVersion()  + "). Try force reloading the page and hope cloudflare doesn't cache everything!";
        alert(msg);
        document.getElementById("controls").innerText = msg;
        // window.location.reload(true);
        return;
    }

    Engine.setup();
    mainGame = Engine.createBoard();
    fenPtr = Engine.alloc(STR_BUFFER_SIZE);
    msgPtr = Engine.alloc(STR_BUFFER_SIZE);
    handleResize();
    document.getElementById("board").addEventListener("click", handleCanvasClick);
    addEventListener("resize", handleResize);
    handleRestart();
    handleBitboardSelect();
    document.getElementById("depth").addEventListener("input", handleSettingsChange);
    document.getElementById("time").addEventListener("input", handleSettingsChange);
    handleSettingsChange();
    document.getElementById("showlabels").addEventListener("input", () => renderBoard(mainGame, mainCanvas));
    renderBoard(mainGame, mainCanvas);
}

window.chessJsReady = true;
if (window.startChessIfReady !== undefined) window.startChessIfReady();

//////////
// The Zen of HashMap Lang;
// - (() => () => ({ this is cringe }))()();
// - var hoisting is deranged;
// - Lexical object shapes are good; 
//   Mono is struct, Poly is virtual, Mega is recompile;
//   Why we insist on making the JIT guess everything's class is beyond me;
// - Bitwise operate only with the 'n' suffix; 
//   Bit shifting a double casts to an i32 first;
//   The price of 'n' is now every number is a Vec<usize>, of length 1, 
//   and we hope the JIT doesn't allocate and GC a new copy for every intermediary calculation;
// - 2 spaces is 2 cramped dispite what VS Code wants you to believe;
// - Throwing things at me is a poor excuse for control flow; 
//   WASM grants all the ergonomics of C style global 'errno', 
//   because God help you if you want to manually unpack a tagged union from a byte array;
// - 'const' affects the binding not the object;
// - One new Array saves 64 pushes; 
// - Anything the tempts an object literal could be better written in try @keyWord(comptime Lang);
// - '==' takes 70% more lines of spec to describe than '===';
// - Explicitly prefixing global variables with 'window' makes them almost as ugly to read as they are to think about; 
//   Global variables being in a hashmap shared between scripts also means some minifiers assume names can't be changed; 
// - Typed arrays are real arrays;
// - Why minify when you can maxify with sarcastic comments;
//////////
