# Exact continuation lexer fixtures

`--exact-lexer` opts into a continuation-preserving, prioritized lexer VM and
implies `--stateful`. It does not change native `.pg` choice semantics or make
unmapped predicates/actions exact. The initial supported grammar subset includes
ASCII character sets, Unicode scalar wildcard/negated ASCII sets, literal text,
sequences, alternatives, optional/repeated atoms, nongreedy decisions, and
productive lexer rule/fragment calls. Unsupported Unicode escapes/properties
remain audited until their lowering is implemented.

`Exact.g4` and `tests/antlr_exact_lexer_test.w` cover delimiter continuation,
overlapping repetition, productive nested calls, greedy/nongreedy priority,
source-order choice after nongreedy decisions, scalar input, and resource limits.
The positive endpoint assertions were checked against ANTLR 4.13.2's generated
Java lexer (jar SHA-256
`eae2dfa119a64327444672aff63e9ec35a20180dc5b8090b7a6ab85125df4d76`).

The VM follows ordered epsilon closure and retains greedy configurations after
an acceptance; lower-priority configurations that crossed a nongreedy decision
are pruned. This is stronger than selecting a fragment's longest endpoint.
A recursive call stores an interned return context, so its caller's remaining
input participates in matching. Nullable-prefix recursion remains rejected by
the translator's structural audit. Nonproductive rules are not rewritten.

The bytecode consists of immutable six-field little-endian records, independent
of target word size. Range transitions consume Unicode scalar values; reported
lengths remain byte lengths. Programs are trusted compiler output. Matchers
return positive lengths, `-2` for resource exhaustion, `-3` for invalid UTF-8,
`-4` for successful zero-width matches, and `-4 - failure_length` for a
failed match that inspected input. `0` is a no-match without inspected input. The generated stateful
provider must propagate these statuses with guarded progress enabled.

`at_lex_execute` additionally reports failure length, steps, peak configurations and interned
stack count. Limits are one million closure visits per match, 32,767 states,
16,384 interned stacks and 512 call depth. Exhaustion is an explicit error, not
a grammar rejection. The long-input fixture proves linear closure growth for a
simple regular repetition; it is not a claim that recursive/ambiguous grammars
have linear complexity. Each execution frees all temporary configurations and
contexts, with no global cache or speculative command execution.
