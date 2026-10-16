grammar UnicodeRanges;
root: (BYTE_RANGE | IRI_RANGE) EOF;
BYTE_RANGE options { caseInsensitive=false; }: '\u0000'..'\u00FF';
IRI_RANGE: '<' ~('<' | '>' | '"' | '{' | '}' | '|' | '^' | '\\' | '`' | '\u0000'..'\u0020')* '>';
