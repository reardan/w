grammar Priority;
root: 'if' IDENT IDENT PREFIX_FREE EOF;
IDENT: [a-z]+;
KW: 'else';
PREFIX_FREE: ('1' | '22')+;
WS: [ \t\r\n]+ -> skip;
