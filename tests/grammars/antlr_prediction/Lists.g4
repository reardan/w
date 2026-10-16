grammar Lists;
start: items EOF;
items: head=items statement=stmt # Append
     | # Empty;
stmt: 'a' | 'begin' items 'end';
WS: [ \t\r\n]+ -> skip;
