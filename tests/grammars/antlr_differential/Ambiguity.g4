grammar Ambiguity;
start: choice EOF;
choice: first | second;
first: A;
second: A;
A: 'a';
WS: [ \t\r\n]+ -> skip;
