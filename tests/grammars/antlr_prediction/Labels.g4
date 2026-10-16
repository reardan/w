grammar Labels;
start: expression=e (';' collected=values)? EOF;
values: entries+=N (',' entries+=N)*;
e: <assoc=right> left=e '^' right=e # Power
 | left=e '!' # Postfix
 | left=e '+' right=e # Add
 | '(' inner=e ')' # Parens
 | value=N # Number;
N: [0-9]+;
WS: [ \t\r\n]+ -> skip;
