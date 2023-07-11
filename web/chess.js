const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
const minMoveTimeMs = 500;  // If the engine is faster than this, it will wait before playing again. 

function tickGame() {
    const start = performance.now();
    const result = Engine.playNextMove();
    const time = Math.round(performance.now() - start);
    console.log("Found move in " + time + "ms.");
    renderBoard();
    let msg;
    switch (result) {
        case 0:
            if (time < minMoveTimeMs) ticker = window.setTimeout(tickGame, minMoveTimeMs - time);
            else ticker = window.setTimeout(tickGame, 1);
            return;
        case 1:
            // TODO: give zig a way to return the type of error and don't resuming the game in a broken state. 
            msg = "Engine reported error.";
            break;
        case 2:
            msg = "White cannot move.";
            break;
        case 3:
            msg = "Black cannot move.";
            break;
        default:
            msg = "Invalid engine response: " + result;
            break;
    }
    document.getElementById("resume").disabled = true;
    document.getElementById("pause").disabled = true;
    document.getElementById("letters").innerText += "\n" + msg;
};

function handleRestart() {
    handlePause();
    Engine.restartGame();
    renderBoard();
}

function handlePause(){
    window.clearTimeout(ticker);
    document.getElementById("resume").disabled = false;
    document.getElementById("pause").disabled = true;
}

function handleResume(){
    tickGame();
    document.getElementById("resume").disabled = true;
    document.getElementById("pause").disabled = false;
}

function handleSetFromFen(){
    handlePause();
    // The length here must match the size of fenView in Zig to prevent writes overflowing when string too long. 
    const fenBuffer = new Uint8Array(Engine.memory.buffer, Engine.fenView, 80);
    const fenString = document.getElementById("fen").value;
    const length = textEncoder.encodeInto(fenString, fenBuffer).written;
    const success = Engine.setFromFen(length);
    if (!success) alert("Invalid FEN.");
    renderBoard();
}

function getFenFromEngine() {
    const length = Engine.getFen();
    if (length === 0) {
        alert("Engine Error.");
        return;
    }
    const fenBuffer = new Uint8Array(Engine.memory.buffer, Engine.fenView, length);
    const fenString = textDecoder.decode(fenBuffer);
    return fenString;
}

function handleCanvasClick(e) {
    let squareSize = ctx.canvas.getBoundingClientRect().width / 8;
    let file = Math.floor(e.offsetX / squareSize);
    let rank = 7 - Math.floor(e.offsetY / squareSize);
    clicked = [file, rank];  // TODO: dont like this. use index
    renderBoard();
}

function drawPiece(file, rank, pieceByte) {
    if (pieceByte === 0) return;

    let squareSize = document.getElementById("board").width / 8;
    let imgSquareSize = chessImg.width / 6;
    let offset = pieces[pieceByte];
    if (offset === undefined) {
        console.log("Engine gave invalid pieceByte (" + pieceByte + ")");
        return;
    }
    let sX = offset * imgSquareSize;
    let sY = 0;
    if (pieceByte % 2 === 1){
        sY = imgSquareSize;
    }
    ctx.drawImage(chessImg, sX, sY, imgSquareSize, imgSquareSize, file * squareSize, (7 - rank) * squareSize, squareSize, squareSize);
}

function renderBoard() {
    // TODO: doing this all the time is unnessary because you don't care most of the time and it makes typing one in annoying. 
    let fen = getFenFromEngine();
    document.getElementById("fen").value = fen;
    document.getElementById("mEval").innerText = Engine.getMaterialEval();
    // TODO: If you go back to a previous state and then resume, it makes different moves because the rng state changed. idk if that's good or bad 
    let history = document.getElementById("history");
    history.value += "\n" + fen;
    history.scrollTop = history.scrollHeight;

    // TODO: If I really cared I could just render the diff instead of clearing the board
    ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
    if (clicked != null) {
        fillSquare(clicked[0], clicked[1], "yellow");
        // The 'n' suffix makes it use BigInt instead of doubles so I can use it as a u64 bit flag. 
        let targetSquaresFlag = Engine.getPossibleMoves(clicked[1]*8 + clicked[0]);
        for (let i=0n;i<64n;i++) {
            let flag = 1n << i;
            if (targetSquaresFlag & flag) {
                fillSquare(Number(i % 8n), Number(i / 8n), "lightblue");
            }
        }
    }

    // TODO: why do I need to remake this slice every time?
    let board = new Uint8Array(Engine.memory.buffer, Engine.boardView);
    for (let rank=0;rank<8;rank++){
        for (let file=0;file<8;file++){
            const p = board[rank*8 + file];
            drawPiece(file, rank, p);
        }
    }
}

function fillSquare(file, rank, colour) {
    let squareSize = document.getElementById("board").width / 8;
    ctx.fillStyle = colour;
    ctx.fillRect(file*squareSize, (7-rank)*squareSize, squareSize, squareSize);
}

// TODO: these should be done in drawPiece with (b & flag)
const pieces = pieceArray();
function pieceArray() {
    // These are the indexes of each type of piece in the pieces.svg image.
    const piecesMap = {
        5: 5,
        6: 5,
        9: 2,
        10: 2,
        13: 3,
        14: 3,
        17: 4,
        18: 4,
        21: 1,
        22: 1,
        25: 0,
        26: 0,
    };
    const pieces = new Array(26);  // TODO: Why does making this a Uint8Array hide the kings? that's offset zero
    for (let i = 0; i<27;i++) {
        let c = piecesMap[i];
        if (c !== undefined) {
            pieces[i] = c;
        }
    }
    return pieces
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
// - Typed arrays are real arrays;
//////////
