grammar SafetyLists;
root: '[' values ']' postfix EOF;
values: values ',' item | item;
item: 'a' | 'b';
postfix: postfix '.' 'x' | 'p' | 'q';
WS: [ \t\r\n]+ -> skip;
