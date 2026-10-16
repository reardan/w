lexer grammar GoModesLexer;
ID: [a-z]+ -> mode(NLSEMI);
PLUS: '+';
WS: [ \t\r\n]+ -> skip;
mode NLSEMI;
EOS: ('\r'? '\n' | EOF) -> mode(DEFAULT_MODE);
OTHER: -> mode(DEFAULT_MODE), channel(HIDDEN);
