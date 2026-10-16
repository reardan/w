grammar Continuation;
start: WORD EOF;
WORD: [a-z]+ 'x';
WS: [ \t\r\n]+ -> skip;
