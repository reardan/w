grammar Unicode;
options { caseInsensitive=true; }
root: (ACCENT | SCALAR | LETTER | RAW | NEGATED | CARET | LOWER | MIXED_RANGE)* EOF;
ACCENT: '\u00e9'+;
SCALAR: [\u{1F600}-\u{1F64F}]+;
LETTER: [\p{L}]+;
RAW: 'Ω'+;
NEGATED: '~' ~[\u03b1-\u03c9]+;
CARET: [^]+;
LOWER options { caseInsensitive=false; }: 'abc'+;
MIXED_RANGE: '!' [A-z]+;
WS: [ \t\r\n]+ -> skip;
RANGE: '\u0100'..'\u0104';
NOT_LITERAL: '~' ~'\u03a9';
NOT_GROUP: '/' ~('\u03a9' | '\u03b1' | '^' | '[' | ']');
BYTE_RANGE options { caseInsensitive=false; }: '\u0000'..'\u00FF';
IRI_RANGE: '<' ~('<' | '>' | '"' | '{' | '}' | '|' | '^' | '\\' | '`' | '\u0000'..'\u0020')* '>';
