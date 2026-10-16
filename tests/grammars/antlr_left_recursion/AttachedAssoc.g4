// Original minimized Wave 0 fixture; repository license applies.
grammar AttachedAssoc;
start: expr EOF;
expr: expr<assoc=right> '+' expr | ID;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
