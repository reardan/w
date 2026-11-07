// Original fixture for plan-driven left-recursion lowering; repository license applies.
// Interleaves suffix and binary alternatives (ANTLR decides binary first),
// adjacent operands (empty operator), a right-associative binary, a ternary
// with an ordinary middle operand, prefixes at two binding levels, and an
// undelimited optional ordinary owner reference in a primary.
grammar Shapes;
start: expr EOF;
expr
    : expr '.' ID                           # Member
    | expr '(' (expr (',' expr)*)? ')'      # Call
    | '-' expr                              # Negate
    | <assoc=right> expr '^' expr           # Power
    | expr ('*' | '/') expr                 # Mul
    | expr '+' expr                         # Add
    | expr expr                             # Apply
    | expr '?' expr ':' expr                # Ternary
    | 'not' expr                            # Not
    | 'return' expr?                        # Return
    | '(' expr ')'                          # Parens
    | ID                                    # Atom
    ;
ID: [a-z]+;
WS: [ \t\r\n]+ -> skip;
