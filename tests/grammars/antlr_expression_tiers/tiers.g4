grammar ExpressionTiers;
root: expr EOF;
expr
    : '!' expr
    | expr '[' expr ']'
    | expr '.' NAME
    | expr '(' expr ')'
    | <assoc=right> expr '^' expr
    | '-' expr
    | expr '*' expr
    | expr '+' expr
    | 'forall' NAME ':' expr
    | NUMBER
    | '(' expr ')'
    | '[' expr ',' expr ']'
    | functionbase
    ;
functionbase: 'fn' body;
body: expr 'end';
NAME: 'a' | 'b';
NUMBER: [0-9]+;
WS: [ \t\r\n]+ -> skip;
