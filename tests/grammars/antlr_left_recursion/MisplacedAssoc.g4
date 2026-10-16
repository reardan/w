// Original minimized Wave 0 fixture; repository license applies.
grammar MisplacedAssoc;
start: expr EOF;
expr: expr ('=' <assoc=right> | ':=' <assoc=right>) expr # Assign | ID # Atom;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
