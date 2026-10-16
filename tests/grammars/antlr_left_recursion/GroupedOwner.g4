// Original minimized Wave 0 fixture; repository license applies.
grammar GroupedOwner;
start: expr EOF;
expr: expr '[' (expr (',' expr)*)? ']' # Index | ID # Atom;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
