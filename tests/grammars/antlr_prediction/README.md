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

`antlr_to_pg_prediction_precedence_test` additionally checks binding-power loops
for previously refused direct-recursive shapes: compound operators with optional
clauses, right-associative ternaries, and postfix operations interleaved with
binary levels. Its 17 accepted/rejected expression examples were evaluated
against the live reference. `Labels.g4` checks source-alternative provenance,
labeled left/right operands, and list labels against the reference's labeled
contexts. `Lists.g4` checks nullable lists whose named statement rule guards
nested recursion with `begin`/`end`; it does not guess arbitrary keyword pairs.
All unsafe rewrites remain atomic, and the final nullable-prefix audit still runs.
The old normalizer runs first to preserve existing supported grammar AST layouts.

Prediction output adds `node_meta` and `term_meta` directives after rule
emission. These directives are available only in `mode antlr` and validate the
referenced rule/alternative/term and unique metadata key before generation.
Metadata is replayed onto the selected tree:

- `antlr_rule:<original-name>` stores the original one-based alternative index.
- `antlr_alt:<label>` identifies an ANTLR alternative label.
- `antlr_source_line` and `antlr_source_column` locate the original alternative.
- `antlr_label:<name>=` marks a labeled matched child; `<name>+=` marks each
  list-labeled child, preserving encounter order rather than overwriting a list.
- `antlr_lhs_label:<name>=` on a normalized suffix identifies the prior
  accumulated expression/list value as the original labeled left operand.

Group alternatives retain their original owner and source coordinates. Helper
nodes expose provenance rather than pretending to be original ANTLR contexts.
Clients folding the normalized AST must interpret `antlr_lhs_label` as the
previous accumulated value. Unsupported host actions/predicates remain refused.
EOF-producing lexer references are treated as consuming tokens in the new
parser-level nullability proofs, independently of their byte-level lexer width.

The default ordered-choice audit can prove greedy continuation absorption for
regular fragments: for each concrete caller suffix `C` and greedy atom `A`, it
checks the language inclusion `A^-1 C <= C`. This includes nested token runs and
delimiter-terminated lines without treating every nullable suffix as safe. Inner
alternatives and repetitions are still audited independently. A mandatory boundary
whose FIRST set is disjoint from every token in `A` permits a fresh sentinel for
the remaining suffix. Unknown recursion and exhausted proof limits retain the
unproven diagnostic. Limits are 24 expansion levels, 512 NFA states, 4,096 product
states per inclusion job, and 65,536 shared caller/context/product work steps per
decision. Optional absorption expansion is attempted only for grammars with at
most 128 parser rules, 4,096 parser atoms, and 24 nested group levels; larger inputs
retain the ordinary FIRST/FOLLOW findings. A separate **750,000,000-operation
budget is shared by the entire grammar audit**, charging NFA construction, closure
and transition state/edge visits, subset keys, and caller-context traversal.
Exhaustion is sticky and preserves an unproven finding, including when a partial
state set would otherwise appear empty. The limit provides roughly 29% headroom
above the measured 582,950,818 operations for pinned Geekcode. On the pinned Geekcode grammar this proof takes approximately six seconds
and 400 MB in the 32-bit translator; SwiftFin completes in under a tenth of a second.

With the structural gate, pinned Cobol85 default translation completes in about
two seconds instead of exhausting the 90-second corpus-stage timeout.
