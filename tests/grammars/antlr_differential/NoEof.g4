grammar NoEof;
start: item;
item: A | A B;
A: 'a';
B: 'b';
WS: [ \t\r\n]+ -> skip;
