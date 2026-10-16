parser grammar FragmentTokenParser;
options { tokenVocab=FragmentTokenLexer; }
start: ID EOF;
