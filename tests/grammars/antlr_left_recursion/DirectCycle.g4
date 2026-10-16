// Original minimized Wave 0 fixture; repository license applies.
grammar DirectCycle;
start: expr EOF;
expr: expr | ID;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
