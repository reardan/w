parser grammar MoreEndParser;
options { tokenVocab = MoreEndLexer; }
start: WORD EOF;
