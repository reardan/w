grammar EmptyLists;
root: '[' values ']' EOF;
values: values item |;
item: 'a' | '(' values ')';
WS: [ \t\r\n]+ -> skip;
