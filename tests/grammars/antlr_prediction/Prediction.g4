grammar Prediction;
start: ('s' choice | 'f' followed 'b' | 'o' optional | 'r' repeated
       | 'p' positive | 'n' nullable | 'i' indirect | 'd' statement
       | 'u' ambiguous) EOF;
choice: 'a' | 'a' 'b';
followed: 'a' 'b' | 'a';
optional: 'a'? 'a';
repeated: 'a'* 'a';
positive: 'a'+ 'a';
nullable: empty 'a' | 'a';
empty: ;
indirect: short | long;
short: 'a';
long: 'a' 'b';
statement: 'x' statement | 'x' statement 'e' statement | 'a';
ambiguous: short | short;
WS: [ \t\r\n]+ -> skip;
