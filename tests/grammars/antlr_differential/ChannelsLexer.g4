lexer grammar ChannelsLexer;
channels { COMMENTS, EXTRA }
A: 'a';
COMMENT: '#' [a-z]+ -> channel(COMMENTS);
NOTE: '!' -> channel(EXTRA);
WS: [ \t\r\n]+ -> skip;
