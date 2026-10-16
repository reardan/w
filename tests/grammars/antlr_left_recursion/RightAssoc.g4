// Original minimized Wave 0 fixture; repository license applies.
grammar RightAssoc;
start: expr EOF;
expr: <assoc=right> expr '^' expr # Power | '-' expr # Negate | ID # Atom;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
