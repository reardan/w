// Original minimized Wave 0 fixture; repository license applies.
grammar ComplexSuffix;
start: expr EOF;
expr: expr '(' expr ')' # Call | expr '+' expr # Add | ID # Atom;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
