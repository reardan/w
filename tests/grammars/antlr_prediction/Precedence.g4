grammar Precedence;
start: e EOF;
e: '-' e
 | <assoc=right> e '^' e
 | e '!'
 | e '*' ('by')? e
 | e '+' e
 | <assoc=right> e '?' e ':' e
 | '(' e ')'
 | N;
N: [0-9]+;
WS: [ \t\r\n]+ -> skip;
