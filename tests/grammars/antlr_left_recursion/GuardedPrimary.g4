// Original minimized Wave 0 fixture; repository license applies.
grammar GuardedPrimary;
start: expr EOF;
expr: expr '+' expr # Add | 'if' expr 'then' expr 'end' # Guard | ID # Atom;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
