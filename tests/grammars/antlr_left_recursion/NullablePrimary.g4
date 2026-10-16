// Original minimized Wave 0 fixture; repository license applies.
grammar NullablePrimary;
start: expr EOF;
expr: expr ',' ID # More | ID? # Base;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
