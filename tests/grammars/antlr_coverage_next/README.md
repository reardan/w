# Pinned grammar runtime coverage

`tinyc.g4`, `microc.g4`, and `arithmetic.g4` are unmodified inputs from the
grammars-v4 revision used by the 291-case sweep. `UPSTREAM.json` records their
upstream paths, commit, and SHA-256 hashes. Each grammar retains its BSD notice.

Run `./wbuild antlr_to_pg_coverage_next_test`. The target translates these files,
generates W parsers, and executes them using the same permissive translation
mode as the compile sweep. It checks nested arithmetic and control-flow bodies,
left-associative list ASTs, token-named arithmetic operators and parentheses,
precedence, repeated unary signs, scientific literals, malformed syntax, and
complete input consumption. Arithmetic's upstream `POW` alternative has no
`assoc=right` annotation, so `2^3^2` evaluates as `(2^3)^2`.

These are focused runtime regressions, not claims of complete ANTLR equivalence.
The existing ordered-choice parser commits to a successful shorter alternative:
tinyc/microc's `expr: test | id_ '=' expr` therefore rejects valid assignments,
and `test: sum_ | sum_ '<' sum_` cannot reach its comparison continuation.
tinyc's earlier `if` alternative similarly prevents a later `else` continuation.
The fixtures exercise nested expression statements and expression-only control
flow without changing upstream rule order. Known valid programs affected by
these limitations are not treated as negative examples.

Strict-mode warnings remain separate: tinyc/microc's heuristic `INT` matcher and
arithmetic's literal priority require reviewed adaptations. The permissive
matcher emitter also produces existing W0083 warnings for boolean bitwise
operators; the hand-authored runtime test introduces no compiler warnings.
