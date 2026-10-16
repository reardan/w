grammar DanglingElse;
start: statement EOF;
statement: IF statement | IF statement ELSE statement | A;
IF: 'if';
ELSE: 'else';
A: 'a';
WS: [ \t\r\n]+ -> skip;
