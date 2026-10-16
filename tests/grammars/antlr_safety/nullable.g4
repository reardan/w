grammar SafetyNullable;
root: A EOF;
A: 'a' Optional;
fragment Optional: Other;
fragment Other: 'b' |;
WS: [ \t\r\n]+ -> skip;
