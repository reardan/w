grammar Plain;
root: A EOF;
A: 'a';
WS: [ \t\r\n]+ -> skip;
