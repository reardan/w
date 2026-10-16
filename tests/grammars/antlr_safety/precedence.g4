grammar SafetyPrecedence;
root: expr EOF;
expr
    : ('+' | '-') expr
    | <assoc=right> expr '^' expr
    | expr ('*' | '/') expr
    | expr ('+' | '-') expr
    | '(' expr ')'
    | NUMBER
    ;
NUMBER: [0-9]+;
WS: [ \t\r\n]+ -> skip;
