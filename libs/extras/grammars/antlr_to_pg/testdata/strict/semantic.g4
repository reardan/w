grammar Semantic;
options { tokenVocab = Missing; superClass = Host; }
root: <assoc=right> A {guard()}? B;
A: 'a';
mode TEMPLATE;
B: 'b' {action();} -> type(A), popMode;
