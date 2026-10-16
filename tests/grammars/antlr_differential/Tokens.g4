grammar Tokens;
start: (IF | IDENT | NUMBER)* EOF;
IF: 'if';
IDENT: [a-z]+;
NUMBER: [0-9]+;
COMMENT: '#' ~[\r\n]* -> channel(HIDDEN);
WS: [ \t\r\n]+ -> skip;
