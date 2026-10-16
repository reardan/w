parser grammar GoModesParser;
options { tokenVocab=GoModesLexer; }
start: ID (EOS? PLUS ID)* EOS? EOF;
