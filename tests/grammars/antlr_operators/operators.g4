grammar Operators;
root: expr EOF;
expr
    : unary expr
    | <assoc=right> expr power expr
    | expr product expr
    | expr sum expr
    | '(' expr ')'
    | NUMBER
    ;
unary: ADD;
power: powerAlias;
powerAlias: '^';
product: (MUL | '%');
sum: addAlias;
addAlias: ADD;
ADD: '+' | '-';
MUL: TIMES | DIVIDE;
fragment TIMES: '*';
fragment DIVIDE: '/' | '//';
NUMBER: [0-9]+;
WS: [ \t\r\n]+ -> skip;
