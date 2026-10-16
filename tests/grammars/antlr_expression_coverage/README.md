# Pinned Lua and TNT expression runtime coverage

The grammars are byte-for-byte copies from grammars-v4 at the commit
used by the 291-case compile sweep. `UPSTREAM.json` records their paths and
SHA-256 hashes. The Lua parser retains its upstream MIT license notice and TNT
retains its BSD notice.

Run `./wbuild antlr_to_pg_expression_coverage_test`. This separate target
translates the unmodified sources through the sweep's permissive path,
generates and compiles a W parser, then executes valid and malformed inputs.

Numeric AST evaluation verifies multiplication/addition precedence, left
association, right-associative exponentiation, unary minus below exponentiation,
and parenthesized overrides. Further cases exercise indirect expression bases
through tables, function bodies, parentheses and indexing, plus assignments,
loops and conditional statements. TNT verifies compound quantifier prefixes,
their complete prefix ASTs and full-precedence operands, and the grammar's
unusual source-order precedence (`+` before `*`). Every negative example is
malformed in its source language, and EOF anchors check complete consumption.

This is focused coverage of the newly supported expression normalization, not
complete Lua or ANTLR equivalence. Upstream lexer/parser base classes, the
`IsFunctionCall` predicate, comment handling actions, Unicode matching, and
general lexer backtracking still produce semantic warnings. Ordered-choice
parsing can also commit to an earlier successful alternative when a later one
would be needed by its caller. These limitations are not hidden by modifying
the pinned grammars or treating known valid programs as negative examples.
