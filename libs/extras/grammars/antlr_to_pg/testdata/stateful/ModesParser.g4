parser grammar ModesParser;
options { tokenVocab = ModesLexer; }
root: IDENT OPEN TEXT_VALUE LINE TEXT_VALUE OPEN '<' IDENT EXIT EOF;
