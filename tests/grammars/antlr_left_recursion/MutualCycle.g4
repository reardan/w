// Original minimized Wave 0 fixture; repository license applies.
grammar MutualCycle;
start: expr EOF;
expr: other | ID; other: expr;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
