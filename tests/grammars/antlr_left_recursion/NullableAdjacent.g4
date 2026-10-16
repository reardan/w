// Original minimized Wave 0 fixture; repository license applies.
grammar NullableAdjacent;
start: expr EOF;
expr: expr expr | ID?;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
