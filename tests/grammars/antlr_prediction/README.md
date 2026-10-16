# Complete-input prediction witnesses

`Prediction.g4` exercises shared prefixes, caller continuations, optional and
repeated terms, nullable alternatives, indirect choices, ambiguity, and nested
`else` grouping. These inputs were checked against ANTLR 4.13.2, jar SHA-256
`eae2dfa119a64327444672aff63e9ec35a20180dc5b8090b7a6ab85125df4d76`.
The executable W fixture checks zero diagnostics, complete consumption, selected
alternatives, and source reconstruction; its nested-else choice agrees with the
reference tree `(statement x (statement x (statement a) e (statement a)))` for
`dxxaea`. The same generated native parser still rejects `sab`, establishing
that ordinary `.pg` ordered-choice behavior did not change.

Run `./wbuild antlr_to_pg_prediction_test parser_prediction_test`.
`parser_prediction_test` also checks implicit EOF for roots that omit EOF,
rollback without speculative AST allocation, bounded failure on an exponential
shared-prefix case, and linear instruction counts for 300 nested calls.

`--prediction` emits `mode antlr`, an opt-in **pure, complete-input recognizer**.
It is a prioritized continuation graph interpreter, not an ALL(*) implementation
or a claim of complete ANTLR compatibility. Every public `parse_<rule>` entry
requires EOF; partial-rule parsing remains an ordinary/native parser feature.
The engine retains the complete caller stack, tries alternatives in source order,
and tries greedy repetition before its exit continuation. AST construction only
replays the selected complete derivation. `pg_alternative` metadata records the
one-based **normalized PG** alternative, not the original ANTLR alternative after
normalization. Native AST layout is otherwise retained.

Parser actions/predicates, lexical goals, recovery, and lexer host callbacks
are refused. Parser left recursion and nullable repetitions still pass through
the existing safety checks and are refused unless safely normalized first.
Tokenization must be independent of parser speculation; stateful lexer modes and
commands are supported because they depend only on the token stream.

The production default is one million graph steps. `pg_prediction_parse_limit`
accepts an explicit caller budget; exhaustion produces a sticky resource error,
never a syntax rejection. A program records steps, peak pending branches,
allocated frames and retained events for measurement. Time and temporary space
are bounded by the budget, but unresolved ambiguity can require exponential
work. This implementation deliberately has no DFA cache or unbounded fallback.
It is appropriate for the demonstrated subset; broader promotion requires the
independent differential corpus and resource measurements.
