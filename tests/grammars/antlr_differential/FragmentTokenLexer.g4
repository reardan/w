lexer grammar FragmentTokenLexer;
tokens { ID }
ITEM: ID -> type(ID);
fragment ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
