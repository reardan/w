grammar Optional;
start: A? A EOF;
A: 'a';
WS: [ \t\r\n]+ -> skip;
