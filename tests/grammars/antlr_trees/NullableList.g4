// Original fixture: nullable primary with consuming suffix tails and an
// optional separator; repository license applies.
grammar NullableList;
start: list EOF;
list
    : list ',' item     # More
    | list ';'? item    # Join
    | list '!'          # Bang
    |                   # Empty
    ;
item: ID | '(' list ')';
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
