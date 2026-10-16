grammar TokenSets;
start: 'n' ~(WORD | COMMA) EOF | 'w' . EOF | 'l' ~'keyword' EOF;
WORD: 'word';
COMMA: ',';
KEYWORD: 'keyword';
NUMBER: [0-9]+;
WS: [ \t\r\n]+ -> skip;
