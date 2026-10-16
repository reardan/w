grammar Caller;
start: item B EOF;
item: A B | A;
A: 'a';
B: 'b';
WS: [ \t\r\n]+ -> skip;
