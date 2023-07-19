const WHITE = 0;
const BLACK = 1;
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
let ctx = document.getElementById("board").getContext("2d");
// const minMoveTimeMs = 500;  // When computer vs computer, if the engine is faster than this, it will wait before playing again. 

// TODO: select which colour is human or computer. button to switch mid game for testing. 
// TODO: option to render black at the bottom
// TODO: set depth/time limit, show search time
// TODO: forward and back buttons to move through position history, start playing from anywhere to make tree (render all branches as tiny boards?)
// TODO: run wasm in a worker so it doesn't freeze ui while searching
// TODO: show checkmate, render captured pieces, show engine eval
// TODO: each file should know the git hash and report the error if  something caches just one
// TODO: show the line it thinks is best 
// TODO: save game in local storage 
// TODO: checkbox for "ummmm, I push pawn!", voice lines would be cool 

let ticker = null;
let boardFenHistory = [];
function tickGame() {
    const start = performance.now();
    const result = Engine.playNextMove();
    boardFenHistory.push(getFenFromEngine());
    const time = Math.round(performance.now() - start);
    console.log("Found move in " + time + "ms.");
    renderBoard();
    switch (result) {
        case 0:
            // TODO: do this if computer vs computer.  
            // if (time < minMoveTimeMs) ticker = window.setTimeout(tickGame, minMoveTimeMs - time);
            // else ticker = window.setTimeout(tickGame, 1);
            break;
        default:
            reportEngineMsg(result);
            document.getElementById("resume").disabled = true;
            document.getElementById("pause").disabled = true;
            break;
    }
};

function handleAskRestart() {
    if (confirm("Reset the game to the initial position?")) handleRestart();
}

function handleRestart() {
    handlePause();
    console.log(boardFenHistory);
    Engine.restartGame();
    boardFenHistory = [getFenFromEngine()];
    renderBoard();
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

const FEN_BUFFER_SIZE = 80;

function handleSetFromFen(){
    handlePause();
    // The length here must match the size of fenView in Zig to prevent writes overflowing when string too long. 
    const fenBuffer = new Uint8Array(Engine.memory.buffer, Engine.fenView, FEN_BUFFER_SIZE);
    const fenString = document.getElementById("fen").value;
    const length = textEncoder.encodeInto(fenString, fenBuffer).written;
    const success = Engine.setFromFen(length);
    if (!success) alert("Invalid FEN.");
    renderBoard();
    // tickGame();
}

function getFenFromEngine() {
    const length = Engine.getFen();
    if (length === 0) {
        reportEngineMsg(1);
        return;
    }
    const fenBuffer = new Uint8Array(Engine.memory.buffer, Engine.fenView, length);
    const fenString = textDecoder.decode(fenBuffer);
    return fenString;
}

function isHumanTurn() {
    // This could be done by parsing the fen but that's a lot of extra code just to be slightly slower. 
    return Engine.isWhiteTurn();
}

let clicked = null;
function handleCanvasClick(e) {
    const squareSize = ctx.canvas.getBoundingClientRect().width / 8;
    const file = Math.floor(e.offsetX / squareSize);
    const rank = 7 - Math.floor(e.offsetY / squareSize);
    if (clicked === null){
        clicked = [file, rank];  // TODO: dont like this. use index or be object
        renderBoard();
    } else {
        if (!isHumanTurn()) {
            clicked = [file, rank];
            return;
        }

        const fromIndex = frToIndex(clicked[0], clicked[1]);
        const toIndex = frToIndex(file, rank);

        // TODO: make sure trying to move while the engine is thinking doesn't let you use the wrong colour. 
        const result = Engine.playHumanMove(fromIndex, toIndex);
        switch (result) {
            case 0:
                clicked = null;
                boardFenHistory.push(getFenFromEngine());
                renderBoard();
                // TODO: only do this if other player is engine. 
                setTimeout(tickGame, 25);  // Give it a chance to render.
                break;
            case 4: // Invalid move. 
                console.log("Player tried illigal move.");
                clicked = [file, rank];
                renderBoard();
                break;
            default:
                reportEngineMsg(result);
                break;
        }
    }
}

function reportEngineMsg(result) {
    switch (result) {
        case 0:
            msg = "Ok (???)";
            break;
        case 1:
            // TODO: give zig a way to return the type of error. 
            msg = "Engine error.";
            clearInterval(ticker);
            document.getElementById("controls").style.display = "none";
            break;
        case 2:
            msg = "White cannot move.";
            break;
        case 3:
            msg = "Black cannot move.";
            break;
        case 4: 
            msg = "Invalid move (???)";
            break;
        default:
            msg = "Invalid engine response: " + result;
            break;
    }
    document.getElementById("letters").innerText += "\n" + msg;
}

function drawPiece(file, rank, pieceByte) {
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
    renderBoard();
}

function drawBitBoard(targetSquaresFlag, colour) {
    // The 'n' suffix makes it use BigInt instead of doubles so I can use it as a u64 bit flag. 
    for (let i=0n;i<64n;i++) {
        const flag = 1n << i;
        if (targetSquaresFlag & flag) {
            fillSquare(Number(i % 8n), Number(i / 8n), colour, true);
        }
    }
}

function drawBitBoardPair(magicEngineIndex) {
    const w = Engine.getBitBoard(magicEngineIndex, WHITE);
    const b = Engine.getBitBoard(magicEngineIndex, BLACK);
    for (let i=0n;i<64n;i++) {
        const flag = 1n << i;
        if (w & b & flag) {
            fillSquare(Number(i % 8n), Number(i / 8n), "purple", false);
        } else if (w & flag) {
            fillSquare(Number(i % 8n), Number(i / 8n), "red", false);
        } else if (b & flag) {
            fillSquare(Number(i % 8n), Number(i / 8n), "blue", false);
        }
    }
}

function renderBoard() {
    const fen = getFenFromEngine();
    document.getElementById("fen").value = fen;
    document.getElementById("player").innerText = (Engine.isWhiteTurn() ? "White" : "Black") + "'s Turn";  // TODO: this is where winner/draw info will go
    document.getElementById("mEval").innerText = Engine.getMaterialEval();

    // TODO: If I really cared I could just render the diff instead of clearing the board
    ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);

    // TODO: Either put the magic numbers in the option value or have explicitly named functions (second one probably better!). 
    //       Could make the option value be the function name to call on the engine... but that feels weird. 
    switch (bitBoardInfo) {
        case "none":
            break;
        case "all": 
            drawBitBoardPair(0);
            break;
        case "king": 
            drawBitBoardPair(1);
            break;
        case "castle": 
            drawBitBoardPair(2);
            break;
        case "prev": {
            drawBitBoard(Engine.getBitBoard(3, 0), "green");
            break;
        }
        case "french": {
            drawBitBoard(Engine.getBitBoard(4, 0), "black");
            break;
        }
        default: 
            console.log("Invalid bitBoardInfo string.");
    }

    if (clicked != null) {
        const whitePieces = BigInt(Engine.getBitBoard(0, WHITE));
        const blackPieces = BigInt(Engine.getBitBoard(0, BLACK));
        const allPieces = whitePieces | blackPieces;
        const clickedIndex = frToIndex(clicked[0], clicked[1]);
        const targetSquaresFlag = Engine.getPossibleMoves(Number(clickedIndex));
        const clickedFlag = 1n << BigInt(clickedIndex);
        if ((allPieces & clickedFlag) != 0)fillSquare(clicked[0], clicked[1], "yellow", true);
        drawBitBoard(targetSquaresFlag, (whitePieces & clickedFlag) ? "lightblue" : "red");
    }
    
    // TODO: why do I need to remake this slice every time?
    const board = new Uint8Array(Engine.memory.buffer, Engine.boardView);
    for (let rank=0;rank<8;rank++){
        for (let file=0;file<8;file++){
            const p = board[rank*8 + file];
            drawPiece(file, rank, p);

            if (document.getElementById("showlabels").checked) {
                const squareSize = ctx.canvas.width / 8;
                ctx.font = "15px Arial";
                ctx.fillStyle = "blue";
                const letter = ["A", "B", "C", "D", "E", "F", "G", "H"][file];
                ctx.fillText(letter + "" + (rank+1), (file) * squareSize, (7 - rank + 0.2) * squareSize);
            }
        }
    }
}

function fillSquare(file, rank, colour, isSmall) {
    const squareSize = ctx.canvas.width / 8;
    ctx.fillStyle = colour;
    if (isSmall) {
        const edge = squareSize * 0.25;
        ctx.fillRect(file*squareSize + edge, (7-rank)*squareSize + edge, squareSize - edge*2, squareSize - edge*2);
    } else {
        ctx.fillRect(file*squareSize, (7-rank)*squareSize, squareSize, squareSize);
    }
}

function handleResize(){
    const size = Math.min(Math.min(window.innerWidth, window.innerHeight) * 0.9, 600);
    const board = document.getElementById("board");
    board.style.width = "";
    board.style.height = "";
    board.width = size;
    board.height = size; 
    renderBoard();
}

function jsDrawCurrentBoard(depth, eval, index, count) {
    const mainCtx = ctx;  // TODO: regreting having global variables right about now. 
    const littleCanvas = document.createElement('canvas');
    littleCanvas.style.background = "url(assets/board.svg)";
    littleCanvas.style.border = "2px solid black"
    littleCanvas.style.margin = "2px"
    const size = 70;
    littleCanvas.width = size;
    littleCanvas.height = size; 
    ctx = littleCanvas.getContext("2d");
    document.body.appendChild(littleCanvas);
    renderBoard();
    ctx = mainCtx;
}

function handleDrawTree() {
    // Engine.walkPossibleMoves();
    engineRequestLine([]);
}

function engineRequestLine(indices) {
    // TODO: hate this. just need some wasm accessable memory. 
    if (indices.length*4 > FEN_BUFFER_SIZE) {
        alert("overflow");
        return;
    }
    const buffer = new Uint32Array(Engine.memory.buffer, Engine.fenView, FEN_BUFFER_SIZE / 4);
    for (let i=0;i<indices.length;i++){
        buffer[i] = indices[i];
    }
    Engine.getNextLineMoves(Engine.fenView, indices.length);
    document.body.appendChild(document.createElement('hr'));
    renderBoard();
}

let currentLinePath = [];
let currentLineWords = [];
function jsDrawLineMove(ptr, len, evall, depth, index, alpha, beta) {
    const msgBuffer = new Uint8Array(Engine.memory.buffer, ptr, len);
    const msgStr = textDecoder.decode(msgBuffer);
    const btn = document.createElement('button');
    btn.innerText = msgStr + " (E=" + evall + ", A=" + alpha + ", B=" + beta + ")";
    btn.style.borderWidth = "2px";
    if (evall > 0) {
        btn.style.borderColor = "red";
    } else if (evall < 0) {
        btn.style.borderColor = "blue";
    } else {
        btn.style.borderColor = "purple";
    }
    btn.style.margin = "5px";
    const previousPath = [...currentLinePath];
    const previousPathWords = [...currentLineWords];
    btn.onclick = () => {
        currentLinePath = [...previousPath];
        currentLinePath.push(index);
        currentLineWords = [...previousPathWords];
        currentLineWords.push(msgStr);
        const info = document.createElement('button');
        info.style.fontWeight = "bold";
        info.innerText = currentLineWords + ". Eval: " + evall + ". Remaining: " + depth;

        const freezePath = [...currentLinePath];
        const freezeWords = [...currentLineWords];
        info.onclick = () => {
            currentLinePath = [...freezePath];
            currentLineWords = [...freezeWords];
            engineRequestLine(currentLinePath);
            renderBoard();
        }
        document.body.appendChild(info);
        document.body.appendChild(document.createElement('br'));
        engineRequestLine(currentLinePath);
    };
    document.body.appendChild(btn);
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
