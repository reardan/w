grammar Choice;
start: item EOF;
item: A | A B;
A: 'a';
B: 'b';
WS: [ \t\r\n]+ -> skip;
