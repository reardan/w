lexer grammar MoreEndLexer;
tokens { WORD }
OPEN: '"' -> more, pushMode(QUOTED);
mode QUOTED;
CHARS: ~["]+ -> more;
CLOSE: '"' -> type(WORD), popMode;
END: EOF -> type(WORD), popMode;
