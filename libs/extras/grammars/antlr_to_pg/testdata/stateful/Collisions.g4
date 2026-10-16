grammar Collisions;
root: expr EOF | expr_prec0_g1 EOF | expr_primary EOF;
expr: expr '+' expr | INT;
expr_prec0_g1: 'x';
expr_primary: 'p';
INT: [0-9]+;
WS: [ \t\r\n]+ -> skip;
