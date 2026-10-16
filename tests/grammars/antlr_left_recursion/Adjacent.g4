// Original minimized Wave 0 fixture; repository license applies.
grammar Adjacent;
start: expr EOF;
expr: expr expr # Join | ID # Atom;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
