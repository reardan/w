grammar Expressions;
root: expr EOF;
expr
    : PLUS expr
    | <assoc=right> expr POW expr
    | expr STAR expr
    | MINUS expr
    | expr PLUS expr
    | BANG expr
    | LPAREN expr RPAREN
    | NUMBER (COLON NUMBER)?
    | LBRACKET NUMBER COMMA NUMBER RBRACKET
    ;
PLUS: '+';
MINUS: '-';
STAR: '*';
POW: '^';
BANG: '!';
LPAREN: '(';
RPAREN: ')';
COLON: ':';
LBRACKET: '[';
COMMA: ',';
RBRACKET: ']';
NUMBER: [0-9]+;
WS: [ \t\r\n]+ -> skip;
