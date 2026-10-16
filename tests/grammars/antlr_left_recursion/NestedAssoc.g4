// Original minimized Wave 0 fixture; repository license applies.
grammar NestedAssoc;
start: expr EOF;
expr: expr (<assoc=right> op='=' | <assoc=right> op=':=') expr # Assign | ID # Atom;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
