export var theBoard: [64] u8 = undefined;

export fn setBoardOne(x: u8) *u8 {
   theBoard[0] = x;
   return &theBoard[0];
}